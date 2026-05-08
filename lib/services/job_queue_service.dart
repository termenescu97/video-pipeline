import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart';
import '../database/daos/job_dao.dart';
import '../database/daos/job_file_dao.dart';
import '../database/tables.dart';
import '../utils/constants.dart';
import 'drive_service.dart';
import 'log_service.dart';
import 'queue_state_notifier.dart';
import 'slack_service.dart';
import 'transfer_service.dart';
import 'compression_service.dart';

/// Real-time progress data for a running job.
class ProgressData {
  final String? currentFileName;
  final double? speedBytesPerSec;
  final Duration? eta;
  final Duration? elapsed;
  final double? fps;

  ProgressData({
    this.currentFileName,
    this.speedBytesPerSec,
    this.eta,
    this.elapsed,
    this.fps,
  });
}

/// Manages the job queue — processes jobs sequentially, handles auto-chain,
/// and triggers Slack notifications at phase transitions.
class JobQueueService {
  final JobDao _jobDao;
  final JobFileDao _jobFileDao;
  final SlackService _slackService;
  final TransferService _transferService;
  final CompressionService _compressionService;
  final DriveService _driveService;
  final LogService? _logService;
  final QueueStateNotifier? _queueStateNotifier;

  bool _isProcessing = false;
  int? _currentJobId;
  // Resolves when the processing loop has exited and all in-flight state
  // writes have completed. Used by graceful shutdown so the database is
  // never closed while the queue may still be writing.
  Completer<void>? _stopCompleter;
  // Tracks whether the current processing run was halted by an explicit
  // Stop (operator action, tray quit, window close) versus draining
  // naturally. Used to decide whether to emit the queue-all-done event.
  bool _stoppedByUser = false;

  /// Real-time progress data for UI consumption.
  final ValueNotifier<ProgressData?> progressNotifier = ValueNotifier(null);

  JobQueueService({
    required JobDao jobDao,
    required JobFileDao jobFileDao,
    required SlackService slackService,
    required TransferService transferService,
    required CompressionService compressionService,
    required DriveService driveService,
    LogService? logService,
    QueueStateNotifier? queueStateNotifier,
  })  : _jobDao = jobDao,
        _jobFileDao = jobFileDao,
        _slackService = slackService,
        _transferService = transferService,
        _compressionService = compressionService,
        _driveService = driveService,
        _logService = logService,
        _queueStateNotifier = queueStateNotifier;

  /// Sanitize a drive label for safe use as a folder name.
  /// Replaces non-alphanumeric characters with underscore. Empty labels
  /// fall back to the placeholder "Drive".
  static String sanitizeDriveLabel(String label) {
    final cleaned = label.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return cleaned.isEmpty ? 'Drive' : cleaned;
  }

  /// Build a per-card destination subfolder name in `label_driveletter`
  /// format (e.g., `EOS_DIGITAL_E`). Always combines both label and letter
  /// so two cards with identical labels still get distinct subfolders.
  Future<String> buildCardSubfolder(DetectedDrive drive) async {
    final identity = await _driveService.getDriveIdentity(drive.path);
    final rawLabel = identity?.label ?? drive.label;
    final letter = drive.path.isNotEmpty ? drive.path.substring(0, 1) : 'X';
    return '${sanitizeDriveLabel(rawLabel)}_$letter';
  }

  bool get isProcessing => _isProcessing;
  int? get currentJobId => _currentJobId;

  /// Start processing the queue. Processes one job at a time.
  Future<void> startProcessing() async {
    if (_isProcessing) return;
    _isProcessing = true;
    _stoppedByUser = false;
    _queueStateNotifier?.notifyQueueRunningStarted();

    var hadFailures = false;
    var processedAny = false;
    try {
      while (_isProcessing) {
        final job = await _jobDao.getNextQueuedJob();
        if (job == null) {
          _isProcessing = false;
          break;
        }

        processedAny = true;
        _currentJobId = job.id;
        await _processJob(job);
        // Re-read the just-processed job to detect failure outcome.
        final after = await _jobDao.watchJob(job.id).first;
        if (after?.status == JobStatus.failed) hadFailures = true;
        _currentJobId = null;
      }
    } finally {
      // Loop exited (queue drained, stopped, or threw). Resolve any
      // pending stopProcessing future AFTER state writes are complete.
      final completer = _stopCompleter;
      _stopCompleter = null;
      completer?.complete();
      // Emit allDone only when the queue drained naturally with no
      // failures AND we actually processed something. A pure Stop
      // (no work happened) MUST NOT trigger the celebration.
      if (processedAny && !hadFailures && !_stoppedByUser) {
        _queueStateNotifier?.notifyQueueAllDone();
      }
    }
  }

  /// Stop processing and kill any running subprocess. Returns a Future
  /// that resolves AFTER the processing loop has exited and all in-flight
  /// state writes have completed (including pending-status writes from
  /// hash cancellation), so the caller can safely close the database
  /// once awaited.
  Future<void> stopProcessing() {
    // Reentrant: a second call (e.g., tray quit fired right after the UI
    // stop button) must observe the SAME pending completer until the
    // loop actually exits. Returning `Future.value()` here once the flag
    // is flipped would let shutdown close the database mid-write.
    final pending = _stopCompleter;
    if (pending != null) return pending.future;
    if (!_isProcessing) {
      // Either never started, or already finished cleanly — nothing to await.
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _stopCompleter = completer;
    _isProcessing = false;
    _stoppedByUser = true;
    _transferService.cancel();
    _compressionService.cancel();
    return completer.future;
  }

  Future<void> _processJob(Job job) async {
    _logService?.info('Job #${job.id} started — ${job.type.name} ${job.sourcePath} → ${job.destinationPath}');
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
    } catch (e, st) {
      // Final-review fix #3: top-level _processJob catch must reach the
      // persistent log. Without this, an uncaught exception inside the
      // transfer/compression pipelines leaves no on-disk trace — only
      // the DB error message and Slack ping. The log is the only
      // post-mortem channel for non-Slack-watching operators.
      _logService?.error(
        'Job #${job.id} (${job.type.name}) crashed: $e\n${st.toString().split('\n').take(3).join('\n')}',
      );
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
    var completedBytes = 0;
    var failedCount = 0;

    for (final file in files) {
      if (!_isProcessing) break;
      if (file.status == FileStatus.completed) {
        completedCount++;
        completedBytes += file.fileSize;
        continue;
      }

      // 015 — pre-robocopy safety + cleanup. Runs BEFORE markFileStarted
      // because we read file.startedAt to detect "ever attempted" and
      // we want the local view to reflect the pre-call DB state. The
      // local `file` variable is a snapshot from getFilesForJob, so
      // markFileStarted's row mutation does not change it; ordering
      // here is for explicit reader semantics.
      // Plan: ~/.claude/plans/playful-brewing-peach.md
      final destPath = file.destinationFilePath;
      final destEntityType =
          await FileSystemEntity.type(destPath, followLinks: false);

      if (destEntityType == FileSystemEntityType.notFound) {
        // Lonely dest — robocopy creates fresh. No cleanup needed.
      } else if (destEntityType != FileSystemEntityType.file) {
        // Symlink, junction, or directory at dest. Refuse to touch:
        // a junction could redirect into anywhere (system path or
        // network share), and File.delete() on a non-regular entity
        // is unsafe. Mark failed; operator resolves manually.
        final entityKind = destEntityType == FileSystemEntityType.link
            ? 'symlink/junction'
            : 'non-regular entity';
        await _jobFileDao.markFileFailed(file.id,
            'Refused to overwrite $entityKind at destination: $destPath');
        failedCount++;
        _logService?.error(
          'Job #${job.id} file ${file.fileName}: dest is a $entityKind '
          '($destPath) — resolve manually before retry',
        );
        continue;
      } else {
        final destFile = File(destPath);
        try {
          final sourceSize = await File(file.sourceFilePath).length();
          final destSize = await destFile.length();
          final everAttempted = file.startedAt != null;
          final isPartial = destSize < sourceSize;
          final shouldDelete = file.wasOverwriteApproved ||
              (everAttempted && isPartial);

          if (shouldDelete) {
            try {
              await destFile.delete();
              _logService?.info(
                'Pre-robocopy cleanup of destination $destPath '
                '(approved=${file.wasOverwriteApproved}, '
                'attempted=$everAttempted, partial=$isPartial)',
              );
            } on FileSystemException catch (e) {
              // Permission denied / read-only / locked. Fail this
              // FILE cleanly rather than crashing the whole job via
              // the outer catch in _processJob.
              await _jobFileDao.markFileFailed(file.id,
                  'Could not remove existing destination file: ${e.message}');
              failedCount++;
              _logService?.error(
                'Job #${job.id} file ${file.fileName}: pre-robocopy '
                'delete failed at $destPath — ${e.message}',
              );
              continue;
            }
          } else {
            // Dest exists and we are NOT deleting — Option 4 mtime
            // cutoff guard. If dest was modified after the job was
            // created (i.e., after conflict-preflight saw it), this
            // is a TOCTOU intrusion or post-attempt external
            // replacement we cannot trust. /XN /XC /XO would let
            // robocopy skip silently and size-only verification
            // could mark completed wrongly. Fail loudly here.
            final destMtime = await destFile.lastModified();
            if (destMtime.isAfter(job.createdAt)) {
              await _jobFileDao.markFileFailed(file.id,
                  'Destination modified after job creation '
                  '(mtime=${destMtime.toIso8601String()} > '
                  'createdAt=${job.createdAt.toIso8601String()}). '
                  'Refusing to overwrite without explicit approval.');
              failedCount++;
              _logService?.warning(
                'Job #${job.id} file ${file.fileName}: mtime cutoff '
                'guard tripped at $destPath '
                '(mtime=$destMtime > createdAt=${job.createdAt})',
              );
              continue;
            }
          }
        } on FileSystemException catch (e) {
          // length() / lastModified() failed. Fail conservatively.
          await _jobFileDao.markFileFailed(file.id,
              'Could not read destination metadata: ${e.message}');
          failedCount++;
          _logService?.error(
            'Job #${job.id} file ${file.fileName}: dest metadata read '
            'failed at $destPath — ${e.message}',
          );
          continue;
        }
      }

      await _jobFileDao.markFileStarted(file.id);

      // Wire progress callback for real-time UI updates.
      _transferService.onProgress = (event) {
        final startTime = _transferService.fileStartTime;
        final totalBytes = _transferService.fileTotalBytes;
        if (startTime != null && totalBytes > 0 && event.percentage != null) {
          final elapsed = DateTime.now().difference(startTime);
          final transferredBytes = (event.percentage! / 100.0) * totalBytes;
          final speed = elapsed.inMilliseconds > 0
              ? transferredBytes / (elapsed.inMilliseconds / 1000.0)
              : 0.0;
          final remainingBytes = totalBytes - transferredBytes;
          final eta = speed > 0
              ? Duration(seconds: (remainingBytes / speed).round())
              : null;
          progressNotifier.value = ProgressData(
            currentFileName: event.fileName ?? file.fileName,
            speedBytesPerSec: speed,
            eta: eta,
            elapsed: elapsed,
          );
        } else if (event.fileName != null) {
          progressNotifier.value = ProgressData(
            currentFileName: event.fileName,
          );
        }
      };

      final success = await _transferService.transferFile(
        sourceFile: file.sourceFilePath,
        destinationFile: file.destinationFilePath,
      );

      _transferService.onProgress = null;
      progressNotifier.value = null;

      // If the transfer was cancelled by stopProcessing, the subprocess
      // was killed and `success` is false — but this is NOT a real
      // failure. Reset the file to pending so robocopy /Z resumes
      // cleanly when the operator restarts the queue.
      if (!_isProcessing) {
        await _jobFileDao.resetFileToPending(file.id);
        break;
      }

      if (success) {
        if (job.verificationMode == VerificationMode.sha256) {
          // SHA-256 hash verification — parallel since source and dest are on different drives.
          progressNotifier.value = ProgressData(
            currentFileName: 'Verifying: computing hashes...',
          );
          final results = await Future.wait([
            _transferService.computeFileHash(file.sourceFilePath),
            _transferService.computeFileHash(file.destinationFilePath),
          ]);
          final sourceHash = results[0];
          final destHash = results[1];
          progressNotifier.value = null;

          // Same cancellation guard for the hashing subprocesses: if the
          // operator stopped during hashing, the hash runners were
          // killed. Reset the file to pending; recovery will re-verify.
          if (!_isProcessing) {
            await _jobFileDao.resetFileToPending(file.id);
            break;
          }

          await _jobFileDao.updateFileHashes(
            file.id,
            sourceHash: sourceHash,
            destinationHash: destHash,
          );

          if (sourceHash == null || destHash == null) {
            // Hash computation failed (not cancelled — that case is
            // handled above). Real failure path.
            await _jobFileDao.markFileFailed(
              file.id,
              'SHA-256 verification failed: could not compute hash',
            );
            failedCount++;
            _logService?.error('Job #${job.id} file ${file.fileName} — SHA-256 hash computation failed: source=$sourceHash dest=$destHash');
          } else if (sourceHash == destHash) {
            await _jobFileDao.markFileCompleted(file.id, verified: true);
            completedCount++;
            completedBytes += file.fileSize;
            _logService?.info('Job #${job.id} file ${file.fileName} — SHA-256 verified: source=$sourceHash dest=$destHash MATCH');
          } else {
            await _jobFileDao.markFileFailed(
              file.id,
              'SHA-256 hash mismatch',
            );
            failedCount++;
            _logService?.warning('Job #${job.id} file ${file.fileName} — SHA-256 MISMATCH: source=$sourceHash dest=$destHash');
          }
        } else {
          // Size-based verification (default).
          final verified = await _transferService.verifyTransfer(
            sourceFile: file.sourceFilePath,
            destinationFile: file.destinationFilePath,
          );
          if (verified) {
            await _jobFileDao.markFileCompleted(file.id, verified: true);
            completedCount++;
            completedBytes += file.fileSize;
            _logService?.info('Job #${job.id} file transferred and verified: ${file.fileName}');
          } else {
            await _jobFileDao.markFileFailed(
              file.id,
              'Verification failed: size mismatch',
            );
            failedCount++;
            _logService?.warning('Job #${job.id} file verification failed: ${file.fileName}');
          }
        }
        await _jobDao.updateJobProgress(
          job.id,
          completedFiles: completedCount,
          completedBytes: completedBytes,
        );
      } else {
        await _jobFileDao.markFileFailed(file.id, 'Transfer failed');
        failedCount++;
        _logService?.error('Job #${job.id} file transfer failed: ${file.fileName}');
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

    // Final-review fix #9 + 015-S6: stamp the final counters
    // explicitly before markJobCompleted/markJobFailed. The per-file
    // updateJobProgress only fires on SUCCESS, so a recovered job
    // whose file rows were already completed pre-crash would
    // otherwise carry stale `jobs.completedFiles` and
    // `jobs.completedBytes` into history.
    await _jobDao.updateJobProgress(
      job.id,
      completedFiles: completedCount,
      completedBytes: completedBytes,
    );

    final allVerified = failedCount == 0;
    if (failedCount > 0) {
      _logService?.error('Job #${job.id} failed — $completedCount transferred, $failedCount failed verification');
      await _jobDao.markJobFailed(
        job.id,
        '$completedCount/${completedCount + failedCount} files transferred, $failedCount failed verification',
      );
    } else {
      _logService?.info('Job #${job.id} completed — $completedCount files transferred');
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
    var completedBytes = 0;
    var failedCount = 0;

    for (final file in files) {
      if (!_isProcessing) break;
      if (file.status == FileStatus.completed) {
        completedCount++;
        completedBytes += file.fileSize;
        continue;
      }

      await _jobFileDao.markFileStarted(file.id);

      // Wire progress callback for real-time UI updates.
      _compressionService.onProgress = (progress) {
        Duration? eta;
        if (progress.eta != null) {
          // Parse HandBrake ETA string like "00h33m34s".
          final match = RegExp(r'(\d+)h(\d+)m(\d+)s').firstMatch(progress.eta!);
          if (match != null) {
            eta = Duration(
              hours: int.parse(match.group(1)!),
              minutes: int.parse(match.group(2)!),
              seconds: int.parse(match.group(3)!),
            );
          }
        }
        progressNotifier.value = ProgressData(
          currentFileName: file.fileName,
          fps: progress.fps,
          eta: eta,
        );
      };

      final success = await _compressionService.compressFile(
        inputFile: file.sourceFilePath,
        outputFile: file.destinationFilePath,
        presetName: job.presetName ?? '',
      );

      _compressionService.onProgress = null;
      progressNotifier.value = null;

      // Cancellation guard: if HandBrake was killed by stopProcessing,
      // `success` is false but this is not a real failure — reset to
      // pending so the file can be re-processed on resume.
      if (!_isProcessing) {
        await _jobFileDao.resetFileToPending(file.id);
        break;
      }

      if (success) {
        await _jobFileDao.markFileCompleted(file.id, verified: true);
        completedCount++;
        completedBytes += file.fileSize;
        _logService?.info(
          'Job #${job.id} compressed: ${file.fileName}',
        );
        await _jobDao.updateJobProgress(
          job.id,
          completedFiles: completedCount,
          completedBytes: completedBytes,
        );
      } else {
        await _jobFileDao.markFileFailed(file.id, 'Compression failed');
        failedCount++;
        // Final-review fix #2: compression branch was silent on file
        // failure. Mirror the transfer branch and write to the log so
        // post-mortem has the per-file failure trail (preset issues,
        // codec problems are diagnosed from these lines).
        _logService?.error(
          'Job #${job.id} compression failed: ${file.fileName}',
        );
      }
    }

    // Check if interrupted by stop.
    if (!_isProcessing) {
      await _jobDao.updateJobStatus(job.id, JobStatus.paused);
      return;
    }

    // Final-review fix #9 + 015-S6: stamp the final counters
    // explicitly before markJobCompleted. The per-file
    // updateJobProgress only fires on SUCCESS, so a recovered job
    // whose file rows were already completed pre-crash would
    // otherwise reach completion with stale jobs.completedFiles +
    // jobs.completedBytes. This guarantees the row reflects reality.
    await _jobDao.updateJobProgress(
      job.id,
      completedFiles: completedCount,
      completedBytes: completedBytes,
    );

    if (failedCount > 0) {
      // Final-review fix #2: log the job-level failure summary too.
      _logService?.error(
        'Job #${job.id} compression FAILED — $completedCount/${files.length} compressed, $failedCount failed',
      );
      await _jobDao.markJobFailed(
        job.id,
        '$completedCount/${files.length} files compressed, $failedCount failed',
      );
      // Final-review fix #1: when compression has any failures, do NOT
      // send the green-checkmark "Compression Complete" Slack message.
      // notifyJobFailed gives the operator an honest signal.
      await _slackService.notifyJobFailed(
        jobId: job.id,
        phase: 'Compression',
        error: '$completedCount/${files.length} files compressed, $failedCount failed',
      );
    } else {
      _logService?.info(
        'Job #${job.id} compression completed — $completedCount files',
      );
      await _jobDao.markJobCompleted(job.id);
      await _slackService.notifyCompressionCompleted(
        job: job,
        completedFiles: completedCount,
        totalFiles: files.length,
      );
    }
  }

  /// Create transfer jobs for multiple drives in batch.
  ///
  /// Each card writes into its own per-card subfolder
  /// (`destination/<label>_<driveletter>/...`) so two cards with identical
  /// folder structures (e.g., two Canon cameras both with
  /// `DCIM/100CANON/C0001.MP4`) cannot overwrite each other.
  ///
  /// All jobs are created atomically (job + files + totals in a single
  /// transaction). Cards with no video files are skipped without creating
  /// a job. Conflict detection (existing files at destination) is
  /// performed first as a single global preflight; if [onConflict] is
  /// provided and conflicts are found, the callback is awaited to obtain
  /// a [ConflictResolution] which is then applied to the file list before
  /// any jobs are created.
  Future<({int created, int skipped, List<String> conflicts})>
      createBatchTransferJobs(
    List<DetectedDrive> drives,
    String destination, {
    VerificationMode verificationMode = VerificationMode.size,
    Future<ConflictResolution> Function(List<ConflictEntry> conflicts)?
        onConflict,
  }) async {
    // Phase 1: enumerate per-card files with per-card subfolders.
    final cardPlans = <_CardTransferPlan>[];
    for (final drive in drives) {
      final drivePath = drive.path;
      final files = await Directory(drivePath)
          .list(recursive: true)
          .where((e) => e is File)
          .where((e) {
            final ext = p.extension(e.path).toLowerCase();
            return videoExtensions.contains(ext);
          })
          .toList();

      if (files.isEmpty) {
        cardPlans.add(_CardTransferPlan.empty(drive));
        continue;
      }

      final subfolder = await buildCardSubfolder(drive);
      final cardDest = p.join(destination, subfolder);
      final entries = <_PlannedFile>[];
      for (final entity in files) {
        final size = await File(entity.path).length();
        final relativePath = p.relative(entity.path, from: drivePath);
        entries.add(_PlannedFile(
          sourcePath: entity.path,
          destinationPath: p.join(cardDest, relativePath),
          fileName: p.basename(entity.path),
          fileSize: size,
        ));
      }
      cardPlans.add(_CardTransferPlan(
        drive: drive,
        cardDestination: cardDest,
        files: entries,
      ));
    }

    // Phase 2: global conflict preflight across all cards. T103/FR-046:
    // also stat the destination size so the resolution dialog can
    // render side-by-side sizes with an "identical"/"very different"
    // hint.
    final allConflicts = <ConflictEntry>[];
    for (final plan in cardPlans) {
      for (final file in plan.files) {
        final destFile = File(file.destinationPath);
        if (await destFile.exists()) {
          int? destBytes;
          try {
            destBytes = await destFile.length();
          } catch (_) {
            // File vanished between exists() and length() — render '?'.
          }
          allConflicts.add(ConflictEntry(
            sourcePath: file.sourcePath,
            destinationPath: file.destinationPath,
            sourceBytes: file.fileSize,
            destinationBytes: destBytes,
          ));
        }
      }
    }

    var resolution = ConflictResolution.overwrite;
    if (allConflicts.isNotEmpty) {
      if (onConflict != null) {
        resolution = await onConflict(allConflicts);
      }
      if (resolution == ConflictResolution.cancel ||
          resolution == ConflictResolution.newFolder) {
        // Caller handles re-target / abort externally. Return paths
        // (not entries) so the legacy `({conflicts: List<String>})`
        // result shape stays stable for callers.
        return (
          created: 0,
          skipped: 0,
          conflicts: allConflicts.map((c) => c.destinationPath).toList(),
        );
      }
      _applyResolution(cardPlans, resolution);
    }

    // Phase 3: assign sortOrder values once, then create jobs atomically.
    final baseOrder = await _jobDao.getMaxSortOrder();
    var created = 0;
    var skipped = 0;
    var orderIndex = 0;

    for (final plan in cardPlans) {
      if (plan.files.isEmpty) {
        skipped++;
        continue;
      }
      orderIndex++;
      final totalBytes = plan.files.fold<int>(0, (sum, f) => sum + f.fileSize);
      try {
        await _jobDao.createJobWithFiles(
          job: JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.queued,
            sourcePath: plan.drive.path,
            destinationPath: plan.cardDestination,
            verificationMode: Value(verificationMode),
            sortOrder: Value(baseOrder + orderIndex),
            createdAt: DateTime.now(),
          ),
          buildFiles: (newJobId) => plan.files
              .map((f) => JobFilesCompanion.insert(
                    jobId: newJobId,
                    sourceFilePath: f.sourcePath,
                    destinationFilePath: f.destinationPath,
                    fileName: f.fileName,
                    fileSize: f.fileSize,
                    status: FileStatus.pending,
                    wasOverwriteApproved:
                        Value(f.wasOverwriteApproved),
                  ))
              .toList(),
          totalBytes: totalBytes,
        );
        created++;
      } on StateError {
        // All files for this card were filtered out — skip without
        // creating a phantom zero-file job.
        skipped++;
      }
    }

    return (
      created: created,
      skipped: skipped,
      conflicts: allConflicts.map((c) => c.destinationPath).toList(),
    );
  }

  /// Apply a conflict resolution to the planned file list. `skip` removes
  /// conflicting entries; `rename` rewrites their destination path with
  /// an auto-suffix (`_1`, `_2`, ...). `overwrite` stamps the per-file
  /// `wasOverwriteApproved` flag for files whose dest exists at
  /// preflight time (015 — replaces the v2.4.0 no-op). `cancel`/
  /// `newFolder` are handled by the caller and never reach this
  /// method.
  void _applyResolution(
      List<_CardTransferPlan> plans, ConflictResolution resolution) {
    if (resolution == ConflictResolution.overwrite) {
      // 015: mark every file whose dest currently exists as approved.
      // Files without an existing dest stay `false` — that prevents a
      // post-preflight TOCTOU intrusion onto a previously-empty dest
      // from triggering the executor's delete branch on the basis of
      // group approval that was never granted for this specific path.
      for (final plan in plans) {
        for (final file in plan.files) {
          if (File(file.destinationPath).existsSync()) {
            file.wasOverwriteApproved = true;
          }
        }
      }
      return;
    }

    for (final plan in plans) {
      final kept = <_PlannedFile>[];
      for (final file in plan.files) {
        final exists = File(file.destinationPath).existsSync();
        if (!exists) {
          kept.add(file);
          continue;
        }
        switch (resolution) {
          case ConflictResolution.skip:
            // drop
            break;
          case ConflictResolution.rename:
            kept.add(file.copyWith(
                destinationPath: _suffixedPath(file.destinationPath)));
            break;
          case ConflictResolution.overwrite:
          case ConflictResolution.cancel:
          case ConflictResolution.newFolder:
            kept.add(file);
            break;
        }
      }
      plan.files
        ..clear()
        ..addAll(kept);
    }
  }

  /// Append `_1`, `_2`, ... before the file extension until a free path
  /// is found.
  String _suffixedPath(String path) {
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '${stem}_$i$ext');
      if (!File(candidate).existsSync()) return candidate;
      i++;
    }
  }

  /// Create a chained compression job after a successful transfer.
  /// Preserves the relative folder structure from the transfer destination
  /// so duplicate basenames in different folders cannot collide in the
  /// compression output.
  Future<void> _createChainedCompressionJob(Job transferJob) async {
    final outputPath = transferJob.compressionOutputPath;
    if (outputPath == null) return;

    final transferFiles = await _jobFileDao.getFilesForJob(transferJob.id);
    final ready = transferFiles
        .where((f) => f.status == FileStatus.completed && f.verified)
        .toList();

    if (ready.isEmpty) return;

    final totalBytes = ready.fold<int>(0, (sum, f) => sum + f.fileSize);
    final baseOrder = await _jobDao.getMaxSortOrder();

    await _jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.compression,
        status: JobStatus.queued,
        sourcePath: transferJob.destinationPath,
        destinationPath: outputPath,
        presetName: Value(transferJob.presetName),
        sortOrder: Value(baseOrder + 1),
        createdAt: DateTime.now(),
      ),
      buildFiles: (newJobId) => ready
          .map((f) => JobFilesCompanion.insert(
                jobId: newJobId,
                sourceFilePath: f.destinationFilePath,
                destinationFilePath: p.join(
                  outputPath,
                  p.relative(
                    f.destinationFilePath,
                    from: transferJob.destinationPath,
                  ),
                ),
                fileName: f.fileName,
                fileSize: f.fileSize,
                status: FileStatus.pending,
              ))
          .toList(),
      totalBytes: totalBytes,
    );
  }
}

/// Operator-chosen response when a transfer job's destination already
/// contains some of the files it would write.
enum ConflictResolution { skip, rename, newFolder, overwrite, cancel }

/// One conflicting file pair surfaced to the resolution dialog and the
/// batch-job preflight callback (T103, FR-046). Carries both source and
/// destination metadata so consumers can show side-by-side sizes and a
/// "very different" / "identical size" hint per row.
///
/// Lives in the service layer (not the UI widget file) because both the
/// dialog AND `createBatchTransferJobs` need to construct/consume it,
/// and a service must not import from `lib/ui/`.
class ConflictEntry {
  /// Path to the file in the source location.
  final String sourcePath;

  /// Path the job would have written to. The actual conflict.
  final String destinationPath;

  /// Source file size in bytes.
  final int sourceBytes;

  /// Existing destination file size in bytes. `null` if the dest
  /// file vanished between the conflict scan and dialog open
  /// (race window — caller may pass null defensively).
  final int? destinationBytes;

  const ConflictEntry({
    required this.sourcePath,
    required this.destinationPath,
    required this.sourceBytes,
    required this.destinationBytes,
  });
}

/// Internal: a planned file destination prior to job creation.
class _PlannedFile {
  String sourcePath;
  String destinationPath;
  String fileName;
  int fileSize;

  /// 015: stamped `true` by `_applyResolution` when the operator chose
  /// `Overwrite` AND this file's dest existed at preflight time. The
  /// executor honors the flag absolutely (delete dest pre-robocopy
  /// regardless of size). Default `false` is the safe baseline.
  /// TODO(refactor): consolidate with create_job_screen._PlannedFile —
  /// see specs/014-ui-redesign Codex Phase 14 review.
  bool wasOverwriteApproved;

  _PlannedFile({
    required this.sourcePath,
    required this.destinationPath,
    required this.fileName,
    required this.fileSize,
    this.wasOverwriteApproved = false,
  });

  _PlannedFile copyWith({String? destinationPath}) => _PlannedFile(
        sourcePath: sourcePath,
        destinationPath: destinationPath ?? this.destinationPath,
        fileName: fileName,
        fileSize: fileSize,
        wasOverwriteApproved: wasOverwriteApproved,
      );
}

/// Internal: the planned transfer for a single card in a batch.
class _CardTransferPlan {
  final DetectedDrive drive;
  final String cardDestination;
  final List<_PlannedFile> files;

  _CardTransferPlan({
    required this.drive,
    required this.cardDestination,
    required this.files,
  });

  factory _CardTransferPlan.empty(DetectedDrive drive) => _CardTransferPlan(
        drive: drive,
        cardDestination: '',
        files: <_PlannedFile>[],
      );
}
