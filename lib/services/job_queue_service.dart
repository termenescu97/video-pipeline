import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart';
import '../database/daos/job_dao.dart';
import '../database/daos/job_file_dao.dart';
import '../database/tables.dart';
import '../utils/constants.dart';
import 'slack_service.dart';
import 'transfer_service.dart';
import 'compression_service.dart';

/// Manages the job queue — processes jobs sequentially, handles auto-chain,
/// and triggers Slack notifications at phase transitions.
class JobQueueService {
  final JobDao _jobDao;
  final JobFileDao _jobFileDao;
  final SlackService _slackService;
  final TransferService _transferService;
  final CompressionService _compressionService;

  bool _isProcessing = false;
  int? _currentJobId;

  JobQueueService({
    required JobDao jobDao,
    required JobFileDao jobFileDao,
    required SlackService slackService,
    required TransferService transferService,
    required CompressionService compressionService,
  })  : _jobDao = jobDao,
        _jobFileDao = jobFileDao,
        _slackService = slackService,
        _transferService = transferService,
        _compressionService = compressionService;

  bool get isProcessing => _isProcessing;
  int? get currentJobId => _currentJobId;

  /// Start processing the queue. Processes one job at a time.
  Future<void> startProcessing() async {
    if (_isProcessing) return;
    _isProcessing = true;

    while (_isProcessing) {
      final job = await _jobDao.getNextQueuedJob();
      if (job == null) {
        _isProcessing = false;
        break;
      }

      _currentJobId = job.id;
      await _processJob(job);
      _currentJobId = null;
    }
  }

  /// Stop processing and kill the running subprocess immediately.
  void stopProcessing() {
    _isProcessing = false;
    _transferService.cancel();
    _compressionService.cancel();
  }

  Future<void> _processJob(Job job) async {
    await _jobDao.markJobStarted(job.id);

    try {
      // Validate source exists before processing.
      final sourceDir = Directory(job.sourcePath);
      if (!await sourceDir.exists()) {
        await _jobDao.markJobFailed(job.id, 'Source path not found: ${job.sourcePath}');
        await _slackService.notifyJobFailed(
          jobId: job.id,
          phase: 'Pre-check',
          error: 'Source path not found: ${job.sourcePath}',
        );
        return;
      }
      switch (job.type) {
        case JobType.transfer:
          await _processTransfer(job);
          break;
        case JobType.compression:
          await _processCompression(job);
          break;
        case JobType.transferAndCompress:
          await _processTransfer(job);
          // If transfer succeeded, auto-chain compression.
          final updatedJob = await _jobDao.getJob(job.id);
          if (updatedJob?.status == JobStatus.completed) {
            await _createChainedCompressionJob(job);
          }
          break;
      }
    } catch (e) {
      await _jobDao.markJobFailed(job.id, e.toString());
      await _slackService.notifyJobFailed(
        jobId: job.id,
        phase: job.type == JobType.compression ? 'Compression' : 'Transfer',
        error: e.toString(),
      );
    }
  }

  Future<void> _processTransfer(Job job) async {
    await _slackService.notifyTransferStarted(job: job);

    final files = await _jobFileDao.getFilesForJob(job.id);
    var completedCount = 0;
    var failedCount = 0;

    for (final file in files) {
      if (!_isProcessing) break;
      if (file.status == FileStatus.completed) {
        completedCount++;
        continue;
      }

      await _jobFileDao.markFileStarted(file.id);

      final success = await _transferService.transferFile(
        sourceFile: file.sourceFilePath,
        destinationFile: file.destinationFilePath,
      );

      if (success) {
        // Verify transfer by comparing file sizes.
        final verified = await _transferService.verifyTransfer(
          sourceFile: file.sourceFilePath,
          destinationFile: file.destinationFilePath,
        );
        await _jobFileDao.markFileCompleted(file.id, verified: verified);
        if (!verified) {
          await _jobFileDao.markFileFailed(
            file.id,
            'Verification failed: size mismatch',
          );
          failedCount++;
        } else {
          completedCount++;
        }
        await _jobDao.updateJobProgress(job.id, completedFiles: completedCount);
      } else {
        await _jobFileDao.markFileFailed(file.id, 'Transfer failed');
        failedCount++;
        await _jobDao.markJobFailed(job.id, 'File transfer failed: ${file.fileName}');
        await _slackService.notifyTransferFailed(
          job: job,
          fileName: file.fileName,
          error: 'Transfer failed',
          completedFiles: completedCount,
        );
        return;
      }
    }

    // Check if interrupted by stop.
    if (!_isProcessing) {
      await _jobDao.updateJobStatus(job.id, JobStatus.paused);
      return;
    }

    final allVerified = failedCount == 0;
    if (failedCount > 0) {
      await _jobDao.markJobFailed(
        job.id,
        '$completedCount/${completedCount + failedCount} files transferred, $failedCount failed verification',
      );
    } else {
      await _jobDao.markJobCompleted(job.id);
    }
    await _slackService.notifyTransferCompleted(
      job: job,
      completedFiles: completedCount,
      allVerified: allVerified,
    );
  }

  Future<void> _processCompression(Job job) async {
    await _slackService.notifyCompressionStarted(job: job);

    final files = await _jobFileDao.getFilesForJob(job.id);
    var completedCount = 0;
    var failedCount = 0;

    for (final file in files) {
      if (!_isProcessing) break;
      if (file.status == FileStatus.completed) {
        completedCount++;
        continue;
      }

      await _jobFileDao.markFileStarted(file.id);

      final success = await _compressionService.compressFile(
        inputFile: file.sourceFilePath,
        outputFile: file.destinationFilePath,
        presetName: job.presetName ?? '',
      );

      if (success) {
        await _jobFileDao.markFileCompleted(file.id, verified: true);
        completedCount++;
        await _jobDao.updateJobProgress(job.id, completedFiles: completedCount);
      } else {
        await _jobFileDao.markFileFailed(file.id, 'Compression failed');
        failedCount++;
      }
    }

    // Check if interrupted by stop.
    if (!_isProcessing) {
      await _jobDao.updateJobStatus(job.id, JobStatus.paused);
      return;
    }

    if (failedCount > 0) {
      await _jobDao.markJobFailed(
        job.id,
        '$completedCount/${files.length} files compressed, $failedCount failed',
      );
    } else {
      await _jobDao.markJobCompleted(job.id);
    }
    await _slackService.notifyCompressionCompleted(
      job: job,
      completedFiles: completedCount,
      totalFiles: files.length,
    );
  }

  /// Create transfer jobs for multiple drives in batch.
  /// Returns the number of jobs created (skips drives with no video files).
  Future<({int created, int skipped})> createBatchTransferJobs(
    List<dynamic> drives,
    String destination,
  ) async {
    var created = 0;
    var skipped = 0;

    for (final drive in drives) {
      final drivePath = drive.path as String;
      final files = await Directory(drivePath)
          .list(recursive: true)
          .where((e) => e is File)
          .where((e) {
            final ext = p.extension(e.path).toLowerCase();
            return videoExtensions.contains(ext);
          })
          .toList();

      if (files.isEmpty) {
        skipped++;
        continue;
      }

      final newJobId = await _jobDao.insertJob(
        JobsCompanion.insert(
          type: JobType.transfer,
          status: JobStatus.queued,
          sourcePath: drivePath,
          destinationPath: destination,
          createdAt: DateTime.now(),
        ),
      );

      var totalBytes = 0;
      final fileEntries = <JobFilesCompanion>[];
      for (final entity in files) {
        final file = File(entity.path);
        final size = await file.length();
        final fileName = p.basename(entity.path);
        totalBytes += size;
        fileEntries.add(
          JobFilesCompanion.insert(
            jobId: newJobId,
            sourceFilePath: entity.path,
            destinationFilePath: p.join(destination, fileName),
            fileName: fileName,
            fileSize: size,
            status: FileStatus.pending,
          ),
        );
      }

      await _jobFileDao.insertFiles(fileEntries);
      await _jobDao.updateJobTotals(newJobId, fileEntries.length, totalBytes);
      created++;
    }

    return (created: created, skipped: skipped);
  }

  /// Create a chained compression job after a successful transfer.
  Future<void> _createChainedCompressionJob(Job transferJob) async {
    final outputPath = transferJob.compressionOutputPath;
    if (outputPath == null) return;

    final jobId = await _jobDao.insertJob(
      JobsCompanion.insert(
        type: JobType.compression,
        status: JobStatus.queued,
        sourcePath: transferJob.destinationPath,
        destinationPath: outputPath,
        presetName: Value(transferJob.presetName),
        createdAt: DateTime.now(),
      ),
    );

    // Copy file list from transfer job, pointing to transferred files.
    final transferFiles = await _jobFileDao.getFilesForJob(transferJob.id);
    final compressionFiles = transferFiles
        .where((f) => f.status == FileStatus.completed && f.verified)
        .map(
          (f) => JobFilesCompanion.insert(
            jobId: jobId,
            sourceFilePath: f.destinationFilePath,
            destinationFilePath: p.join(outputPath, f.fileName),
            fileName: f.fileName,
            fileSize: f.fileSize,
            status: FileStatus.pending,
          ),
        )
        .toList();

    await _jobFileDao.insertFiles(compressionFiles);
  }
}
