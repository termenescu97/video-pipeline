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
import 'planned_file.dart';
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
  // 016: set by shell_screen's _gracefulShutdown when the Phase B drain
  // wait times out and we proceed to Phase C without the loop having
  // finished. Once true, any late-arriving DB writes from the loop
  // (e.g., a `resetFileToPending` after a slow subprocess finally
  // exits) are short-circuited so they don't throw into a closed
  // Drift connection. recoverStaleJobs picks up any remaining
  // inProgress rows on the next launch.
  bool _shutdownAbandoned = false;

  /// Mark the queue as "shutdown abandoned." See [_shutdownAbandoned].
  /// Idempotent. Called from `shell_screen._gracefulShutdown` on Phase
  /// B timeout or unexpected throw; safe to call any number of times.
  void markShutdownAbandoned() {
    _shutdownAbandoned = true;
  }

  /// Centralized abandonment-aware DAO write wrapper. Use for EVERY
  /// DB-mutating call inside `_processJob`, `_processTransfer`,
  /// `_processCompression` — including terminal completion/failure
  /// writes and the outer catch's `markJobFailed`. Without this wrap,
  /// any post-Phase-B writes (after shell_screen abandoned the drain
  /// and Phase C closed the DB) would throw a `ConnectionClosedException`
  /// or `StateError` and surface as noisy unhandled errors.
  ///
  /// Semantics:
  ///  - If `_shutdownAbandoned` is true on entry: silently skip (do
  ///    not call op). Returns immediately.
  ///  - Else: run op. If it throws AND `_shutdownAbandoned` flipped
  ///    to true during the await (Phase C closed the DB under us):
  ///    silently swallow. Otherwise rethrow — real bugs (schema,
  ///    constraint, disk-full, etc.) surface to the outer catch chain
  ///    instead of being hidden by an over-broad `catch (_)`.
  ///
  /// Codex 016 implementation review fixed three HIGH unguarded-write
  /// gaps; the wrapper is the centralized fix.
  Future<void> _safeWrite(Future<void> Function() op) async {
    if (_shutdownAbandoned) return;
    try {
      await op();
    } catch (_) {
      if (_shutdownAbandoned) return;
      rethrow;
    }
  }

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
    await _safeWrite(() => _jobDao.markJobStarted(job.id));

    try {
      // Validate source exists before processing.
      final sourceDir = Directory(job.sourcePath);
      if (!await sourceDir.exists()) {
        await _safeWrite(() => _jobDao.markJobFailed(
            job.id, 'Source path not found: ${job.sourcePath}'));
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
      await _safeWrite(() => _jobDao.markJobFailed(job.id, e.toString()));
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
    // 017 (US1+US2): Slack expansion (FR-016) needs per-state counts.
    // Tracked locally during the loop; passed to notifyTransferCompleted.
    var verifiedCount = 0;
    var unverifiedCount = 0;
    var mismatchedCount = 0;

    for (final file in files) {
      if (!_isProcessing) break;

      // 017 (T046, FR-006): copied-but-unverified recovery. The file
      // was copied to disk in a prior run, then shutdown fired before
      // verify could complete. Bytes are already on disk; do NOT
      // re-copy. Re-enter the verify phase only.
      if (file.status == FileStatus.completed &&
          file.verifyStatus == VerifyStatus.pending) {
        // Bytes already credited in the prior run's updateJobProgress;
        // re-tallying matches what the persisted counters say.
        completedCount++;
        completedBytes += file.fileSize;

        if (job.verificationMode != VerificationMode.sha256) {
          // Size-mode files leave verifyStatus at default 'pending'
          // forever (Codex M5). Nothing to do beyond tallying.
          continue;
        }

        // SHA-256 mode: re-run the hash check, nothing else.
        progressNotifier.value = ProgressData(
          currentFileName: 'Verifying (recovered): ${file.fileName}',
        );
        final results = await Future.wait([
          _transferService.computeFileHash(file.sourceFilePath),
          _transferService.computeFileHash(file.destinationFilePath),
        ]);
        final sourceHash = results[0];
        final destHash = results[1];
        progressNotifier.value = null;

        if (!_isProcessing) break;

        if (sourceHash == null || destHash == null) {
          await _safeWrite(() => _jobFileDao.markFileUnverified(file.id));
          await _safeWrite(() => _jobDao.incrementUnverified(job.id));
          unverifiedCount++;
          _logService?.warning(
            'Recovered ${file.fileName}: SHA-256 subsystem failed',
            jobId: job.id,
            fileIndex: completedCount,
            totalFiles: files.length,
            phase: LogPhase.recover,
          );
        } else if (sourceHash == destHash) {
          await _safeWrite(() => _jobFileDao.markFileVerified(
                file.id,
                sourceHash: sourceHash,
                destHash: destHash,
              ));
          verifiedCount++;
          _logService?.info(
            'Recovered ${file.fileName} verified',
            jobId: job.id,
            fileIndex: completedCount,
            totalFiles: files.length,
            phase: LogPhase.recover,
          );
        } else {
          await _safeWrite(() => _jobFileDao.markFileVerifyMismatch(
                file.id,
                sourceHash: sourceHash,
                destHash: destHash,
              ));
          mismatchedCount++;
          _logService?.warning(
            'Recovered ${file.fileName} MISMATCH',
            jobId: job.id,
            fileIndex: completedCount,
            totalFiles: files.length,
            phase: LogPhase.recover,
          );
        }
        continue;
      }

      if (file.status == FileStatus.completed) {
        completedCount++;
        completedBytes += file.fileSize;
        // 017 (US1+US2): tally per-state verify counts for the Slack
        // expansion (FR-016). On a job that resumes after the verify
        // phase already completed, we still need accurate aggregates.
        switch (file.verifyStatus) {
          case VerifyStatus.verified:
            verifiedCount++;
            break;
          case VerifyStatus.unverified:
            unverifiedCount++;
            break;
          case VerifyStatus.mismatch:
            mismatchedCount++;
            break;
          case VerifyStatus.pending:
            // Handled by the recovery branch above; shouldn't reach here.
            break;
        }
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
        //
        // Known coverage gap (Codex 015 review LOW): Windows `.lnk`
        // shortcuts resolve as `FileSystemEntityType.file`, not
        // `link`, so they bypass this guard. `.lnk` is a regular
        // file containing a serialized shortcut header pointing at
        // a target — robocopy/.delete() act on the .lnk file itself,
        // not the target. Functionally safe but worth flagging if
        // a future review wants explicit `.lnk` rejection (would
        // need a `p.extension(destPath).toLowerCase() == '.lnk'`
        // check here).
        final entityKind = destEntityType == FileSystemEntityType.link
            ? 'symlink/junction'
            : 'non-regular entity';
        await _safeWrite(() => _jobFileDao.markFileFailed(file.id,
            'Refused to overwrite $entityKind at destination: $destPath'));
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
              await _safeWrite(() => _jobFileDao.markFileFailed(file.id,
                  'Could not remove existing destination file: ${e.message}'));
              failedCount++;
              _logService?.error(
                'Job #${job.id} file ${file.fileName}: pre-robocopy '
                'delete failed at $destPath — ${e.message}',
              );
              continue;
            }
          } else if (everAttempted && !isPartial) {
            // Codex review fix (HIGH): legitimate "cancelled-between-
            // robocopy-success-and-verification" case. We started this
            // file in a prior run, robocopy completed (dest size ==
            // source size), then the operator cancelled or the app
            // crashed before the verification step wrote
            // markFileCompleted. dest.lastModified() is necessarily
            // > job.createdAt because robocopy ran AFTER job creation;
            // applying the mtime cutoff here would falsely flag our
            // own completed work as a TOCTOU intrusion and force the
            // operator to manually retry every cancelled-mid-verify
            // file. Skip the mtime guard for this case — robocopy
            // with /XN/XC/XO will skip the file (correctly identifying
            // it as Same/Changed), then verification will run and
            // pass on a real match. Documented size-only-mode gap
            // remains: a same-size content-different rogue would
            // pass size verification; SHA-256 mode catches it.
            _logService?.info(
              'Job #${job.id} file ${file.fileName}: dest matches '
              'source size on resumed file — letting robocopy skip + '
              'verification confirm idempotently ($destPath)',
            );
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
              await _safeWrite(() => _jobFileDao.markFileFailed(file.id,
                  'Destination modified after job creation '
                  '(mtime=${destMtime.toIso8601String()} > '
                  'createdAt=${job.createdAt.toIso8601String()}). '
                  'Refusing to overwrite without explicit approval.'));
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
          await _safeWrite(() => _jobFileDao.markFileFailed(file.id,
              'Could not read destination metadata: ${e.message}'));
          failedCount++;
          _logService?.error(
            'Job #${job.id} file ${file.fileName}: dest metadata read '
            'failed at $destPath — ${e.message}',
          );
          continue;
        }
      }

      await _safeWrite(() => _jobFileDao.markFileStarted(file.id));

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
      // 016: routed through _safeWrite — if Phase C already closed the
      // DB before this drain Future resolved, the write is silently
      // skipped; recoverStaleJobs handles next launch.
      if (!_isProcessing) {
        await _safeWrite(() => _jobFileDao.resetFileToPending(file.id));
        break;
      }

      if (success) {
        if (job.verificationMode == VerificationMode.sha256) {
          // 017 (US1, FR-002, T034): credit bytes to overall progress
          // IMMEDIATELY upon robocopy success, regardless of subsequent
          // verify outcome. The legacy `verified` boolean stays false
          // until markFileVerified flips it; verifyStatus stays 'pending'
          // until the hash check resolves it. Two _safeWrite calls per
          // Codex H1 — gating-the-bug-back is now structurally impossible.
          await _safeWrite(() => _jobFileDao.markFileCompleted(file.id, verified: false));
          completedCount++;
          completedBytes += file.fileSize;
          await _safeWrite(() => _jobDao.updateJobProgress(
                job.id,
                completedFiles: completedCount,
                completedBytes: completedBytes,
              ));
          _logService?.info(
            'Copied ${file.fileName}',
            jobId: job.id,
            fileIndex: completedCount,
            totalFiles: files.length,
            phase: LogPhase.transfer,
          );

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

          // 017 (T046): cancellation mid-verify leaves file at
          // status=completed + verifyStatus=pending. recoverStaleJobs
          // detects this and routes to verify-only on next launch
          // (FR-006). DO NOT reset to pending — that would re-trigger
          // robocopy on resume and double-credit bytes.
          if (!_isProcessing) {
            break;
          }

          if (sourceHash == null || destHash == null) {
            // 017 (US1, FR-003 unverified): hash subsystem failed (PS
            // broken, etc.). Bytes are on disk but cryptographic trust
            // is NOT established. Soft failure — operator sees ⚠ chip.
            await _safeWrite(() => _jobFileDao.markFileUnverified(file.id));
            await _safeWrite(() => _jobDao.incrementUnverified(job.id));
            unverifiedCount++;
            _logService?.warning(
              'SHA-256 subsystem failed for ${file.fileName}: could not compute hash',
              jobId: job.id,
              fileIndex: completedCount,
              totalFiles: files.length,
              phase: LogPhase.verify,
            );
          } else if (sourceHash == destHash) {
            // 017 (US1, FR-003 verified): cryptographic trust established.
            await _safeWrite(() => _jobFileDao.markFileVerified(
                  file.id,
                  sourceHash: sourceHash,
                  destHash: destHash,
                ));
            verifiedCount++;
            _logService?.info(
              'SHA-256 verified ${file.fileName}',
              jobId: job.id,
              fileIndex: completedCount,
              totalFiles: files.length,
              phase: LogPhase.verify,
            );
          } else {
            // 017 (US2, FR-003 mismatch + FR-005): real corruption — bytes
            // on disk differ from source. Soft failure (FR-004 — copy
            // succeeded; verify failed); operator decides via banner.
            // Retry routes through forceDestDelete=true (Codex H2).
            await _safeWrite(() => _jobFileDao.markFileVerifyMismatch(
                  file.id,
                  sourceHash: sourceHash,
                  destHash: destHash,
                ));
            mismatchedCount++;
            _logService?.warning(
              'SHA-256 hash mismatch for ${file.fileName}: source=$sourceHash dest=$destHash',
              jobId: job.id,
              fileIndex: completedCount,
              totalFiles: files.length,
              phase: LogPhase.verify,
            );
          }
        } else {
          // Size-based verification (default; v2.4.0 semantics preserved).
          // Per Codex M5: size match does NOT establish cryptographic trust.
          // verifyStatus stays at default 'pending' for forward-operation
          // size-mode rows; the legacy `verified` boolean is set true.
          final verified = await _transferService.verifyTransfer(
            sourceFile: file.sourceFilePath,
            destinationFile: file.destinationFilePath,
          );
          if (verified) {
            await _safeWrite(() =>
                _jobFileDao.markFileCompleted(file.id, verified: true));
            completedCount++;
            completedBytes += file.fileSize;
            _logService?.info(
              'Copied ${file.fileName} (size-verified)',
              jobId: job.id,
              fileIndex: completedCount,
              totalFiles: files.length,
              phase: LogPhase.transfer,
            );
          } else {
            await _safeWrite(() => _jobFileDao.markFileFailed(
                  file.id,
                  'Verification failed: size mismatch',
                ));
            failedCount++;
            _logService?.warning(
              'Size mismatch for ${file.fileName}',
              jobId: job.id,
              phase: LogPhase.verify,
            );
          }
          await _safeWrite(() => _jobDao.updateJobProgress(
                job.id,
                completedFiles: completedCount,
                completedBytes: completedBytes,
              ));
        }
      } else {
        await _safeWrite(() =>
            _jobFileDao.markFileFailed(file.id, 'Transfer failed'));
        failedCount++;
        _logService?.error('Job #${job.id} file transfer failed: ${file.fileName}');
        // Codex review fix (MEDIUM): persist final progress before the
        // early return. Without this, completedFiles/completedBytes
        // accumulated by THIS run's pass over already-completed rows
        // (the `file.status == FileStatus.completed → continue` branch
        // at the top of the loop) plus any mid-run successes is lost
        // when this failure path returns — DB stays at whatever the
        // last per-file success persisted, which can lag the actual
        // on-disk state if the prior run crashed between markFile-
        // Completed and updateJobProgress.
        await _safeWrite(() => _jobDao.updateJobProgress(
              job.id,
              completedFiles: completedCount,
              completedBytes: completedBytes,
            ));
        await _safeWrite(() => _jobDao.markJobFailed(
            job.id, 'File transfer failed: ${file.fileName}'));
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
    // 016: routed through _safeWrite — if Phase C already closed the
    // DB, the write is silently skipped; recoverStaleJobs handles it.
    if (!_isProcessing) {
      await _safeWrite(
          () => _jobDao.updateJobStatus(job.id, JobStatus.paused));
      return;
    }

    // Final-review fix #9 + 015-S6: stamp the final counters
    // explicitly before markJobCompleted/markJobFailed. The per-file
    // updateJobProgress only fires on SUCCESS, so a recovered job
    // whose file rows were already completed pre-crash would
    // otherwise carry stale `jobs.completedFiles` and
    // `jobs.completedBytes` into history.
    await _safeWrite(() => _jobDao.updateJobProgress(
          job.id,
          completedFiles: completedCount,
          completedBytes: completedBytes,
        ));

    if (failedCount > 0) {
      _logService?.error(
        'Job failed — $completedCount transferred, $failedCount failed copy',
        jobId: job.id,
        phase: LogPhase.finalize,
      );
      await _safeWrite(() => _jobDao.markJobFailed(
            job.id,
            '$completedCount/${completedCount + failedCount} files transferred, $failedCount failed copy',
          ));
    } else {
      // 017 (FR-004): mismatchedCount > 0 does NOT fail the job — bytes
      // are on disk, just not trusted. Soft fail surfaced via banner +
      // Slack warning prefix below. Operator decides next action.
      _logService?.info(
        'Job completed — $completedCount transferred, '
        '$verifiedCount verified, $unverifiedCount unverified, '
        '$mismatchedCount mismatch',
        jobId: job.id,
        phase: LogPhase.finalize,
      );
      await _safeWrite(() => _jobDao.markJobCompleted(job.id));
    }
    // 017 (T043, FR-016): Slack call expanded with per-state verify
    // counts. Warning prefix fires automatically when
    // mismatchedCount > 0 or unverifiedCount > 0.
    await _slackService.notifyTransferCompleted(
      job: job,
      completedFiles: completedCount,
      verifiedFiles: verifiedCount,
      unverifiedFiles: unverifiedCount,
      mismatchedFiles: mismatchedCount,
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

      await _safeWrite(() => _jobFileDao.markFileStarted(file.id));

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
      // 016: routed through _safeWrite (was an explicit guard block).
      if (!_isProcessing) {
        await _safeWrite(() => _jobFileDao.resetFileToPending(file.id));
        break;
      }

      if (success) {
        await _safeWrite(
            () => _jobFileDao.markFileCompleted(file.id, verified: true));
        completedCount++;
        completedBytes += file.fileSize;
        _logService?.info(
          'Job #${job.id} compressed: ${file.fileName}',
        );
        await _safeWrite(() => _jobDao.updateJobProgress(
              job.id,
              completedFiles: completedCount,
              completedBytes: completedBytes,
            ));
      } else {
        await _safeWrite(
            () => _jobFileDao.markFileFailed(file.id, 'Compression failed'));
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
    // 016: routed through _safeWrite — same pattern as the transfer
    // branch.
    if (!_isProcessing) {
      await _safeWrite(
          () => _jobDao.updateJobStatus(job.id, JobStatus.paused));
      return;
    }

    // Final-review fix #9 + 015-S6: stamp the final counters
    // explicitly before markJobCompleted. The per-file
    // updateJobProgress only fires on SUCCESS, so a recovered job
    // whose file rows were already completed pre-crash would
    // otherwise reach completion with stale jobs.completedFiles +
    // jobs.completedBytes. This guarantees the row reflects reality.
    await _safeWrite(() => _jobDao.updateJobProgress(
          job.id,
          completedFiles: completedCount,
          completedBytes: completedBytes,
        ));

    if (failedCount > 0) {
      // Final-review fix #2: log the job-level failure summary too.
      _logService?.error(
        'Job #${job.id} compression FAILED — $completedCount/${files.length} compressed, $failedCount failed',
      );
      await _safeWrite(() => _jobDao.markJobFailed(
            job.id,
            '$completedCount/${files.length} files compressed, $failedCount failed',
          ));
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
        'Compression completed — $completedCount files',
        jobId: job.id,
        phase: LogPhase.finalize,
      );
      await _safeWrite(() => _jobDao.markJobCompleted(job.id));

      // 017 (T045, FR-019): for chained compression, query parent's
      // transfer-phase verify counts and pass them through to Slack so
      // the final ping surfaces transfer-side outcomes (Codex H3 closure).
      Job? parentTransferJob;
      int? parentVerifiedFiles;
      int? parentUnverifiedFiles;
      int? parentMismatchedFiles;
      if (job.parentJobId != null) {
        parentTransferJob = await _jobDao.getJob(job.parentJobId!);
        if (parentTransferJob != null) {
          final parentFiles =
              await _jobFileDao.getFilesForJob(parentTransferJob.id);
          parentVerifiedFiles = parentFiles
              .where((f) => f.verifyStatus == VerifyStatus.verified)
              .length;
          parentUnverifiedFiles = parentFiles
              .where((f) => f.verifyStatus == VerifyStatus.unverified)
              .length;
          parentMismatchedFiles = parentFiles
              .where((f) => f.verifyStatus == VerifyStatus.mismatch)
              .length;
        }
      }
      await _slackService.notifyCompressionCompleted(
        job: job,
        completedFiles: completedCount,
        totalFiles: files.length,
        parentTransferJob: parentTransferJob,
        parentVerifiedFiles: parentVerifiedFiles,
        parentUnverifiedFiles: parentUnverifiedFiles,
        parentMismatchedFiles: parentMismatchedFiles,
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
      final entries = <PlannedFile>[];
      for (final entity in files) {
        final size = await File(entity.path).length();
        final relativePath = p.relative(entity.path, from: drivePath);
        entries.add(PlannedFile(
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
        for (var i = 0; i < plan.files.length; i++) {
          final file = plan.files[i];
          if (File(file.destinationPath).existsSync()) {
            // PlannedFile is immutable post-T024 consolidation — copyWith
            // produces a new instance; in-place mutation no longer works.
            plan.files[i] = file.copyWith(wasOverwriteApproved: true);
          }
        }
      }
      return;
    }

    for (final plan in plans) {
      final kept = <PlannedFile>[];
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
        // 017 (T045, FR-019): link this chained compression to its
        // transferAndCompress parent so notifyCompressionCompleted can
        // surface the parent's verify counts (Constitution V).
        parentJobId: Value(transferJob.id),
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

/// 017 (T025): the duplicate `_PlannedFile` definition that lived here
/// has been consolidated into `lib/services/planned_file.dart` per Codex
/// M7 + R-A9. Both this file and `create_job_screen.dart` now import
/// the shared `PlannedFile` class.

/// Internal: the planned transfer for a single card in a batch.
class _CardTransferPlan {
  final DetectedDrive drive;
  final String cardDestination;
  final List<PlannedFile> files;

  _CardTransferPlan({
    required this.drive,
    required this.cardDestination,
    required this.files,
  });

  factory _CardTransferPlan.empty(DetectedDrive drive) => _CardTransferPlan(
        drive: drive,
        cardDestination: '',
        files: <PlannedFile>[],
      );
}
