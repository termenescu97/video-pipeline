import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../database/daos/job_dao.dart';
import '../database/daos/job_file_dao.dart';
import '../database/tables.dart';
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

  /// Stop processing after the current job completes.
  void stopProcessing() {
    _isProcessing = false;
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
        await _jobFileDao.markFileCompleted(file.id, verified: true);
        completedCount++;
        await _jobDao.updateJobProgress(job.id, completedFiles: completedCount);
      } else {
        await _jobFileDao.markFileFailed(file.id, 'Transfer failed');
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

    await _jobDao.markJobCompleted(job.id);
    await _slackService.notifyTransferCompleted(
      job: job,
      completedFiles: completedCount,
    );
  }

  Future<void> _processCompression(Job job) async {
    await _slackService.notifyCompressionStarted(job: job);

    final files = await _jobFileDao.getFilesForJob(job.id);
    var completedCount = 0;

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
        // Skip failed file, continue with next.
        await _jobFileDao.markFileFailed(file.id, 'Compression failed');
      }
    }

    await _jobDao.markJobCompleted(job.id);
    await _slackService.notifyCompressionCompleted(
      job: job,
      completedFiles: completedCount,
      totalFiles: files.length,
    );
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
        .where((f) => f.status == FileStatus.completed)
        .map(
          (f) => JobFilesCompanion.insert(
            jobId: jobId,
            sourceFilePath: f.destinationFilePath,
            destinationFilePath:
                '$outputPath/${f.fileName}', // TODO: proper path join
            fileName: f.fileName,
            fileSize: f.fileSize,
            status: FileStatus.pending,
          ),
        )
        .toList();

    await _jobFileDao.insertFiles(compressionFiles);
  }
}
