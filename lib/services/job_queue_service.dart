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
  // 018 T010 (FR-008, US3): explicit stop signal observable to the
  // processing loop at every iteration boundary. Distinct from
  // _isProcessing so that startProcessing() can wait for an in-flight
  // stopProcessing() to fully drain before flipping _isProcessing back
  // to true — closes the race where two concurrent loops could both
  // observe _isProcessing == false during the drain window and both
  // start. Set synchronously in stopProcessing(); cleared by
  // startProcessing() AFTER the prior _stopCompleter resolves.
  bool _stopRequested = false;
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

  // 017 (Codex round-2 P2 #2): the persistent force-delete approval now
  // lives on `JobFile.forceDestDeleteApproved`. The previous in-memory
  // _forceDestDeleteFileIds set was lost on app restart between the
  // operator's Retry click and the executor's consumption — closing
  // this gap requires durable state, not transient state.

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
    // 018 T010 (FR-008, US3): if a stopProcessing() is currently
    // draining, await its completer BEFORE doing anything else. Without
    // this, two concurrent startProcessing() calls during the drain
    // window can both observe _isProcessing == false and both flip it
    // to true, spawning two concurrent loops against the same queue.
    final pending = _stopCompleter;
    if (pending != null && !pending.isCompleted) {
      await pending.future;
    }
    // RE-CHECK AND FLIP ATOMICALLY. Dart microtasks run to completion
    // before the next microtask runs, so the lines below MUST NOT be
    // separated by any `await`. If a refactor inserts an await between
    // the re-check and the flip, the FR-008 race re-opens — even a
    // logging await would be sufficient to break the invariant.
    if (_isProcessing) return;
    _isProcessing = true;
    _stopRequested = false;
    _stoppedByUser = false;
    _queueStateNotifier?.notifyQueueRunningStarted();

    var hadFailures = false;
    var hadVerifyWarnings = false;
    var processedAny = false;
    try {
      while (_isProcessing && !_stopRequested) {
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
        // Codex round-18 P2 #2: a SHA-256 transfer that ends with
        // mismatch/unverified files lands at JobStatus.completed (FR-004
        // — bytes are on disk; verify is a soft fail). Without this
        // signal, the celebration "All cards copied & verified" would
        // fire on jobs that explicitly produced verify warnings,
        // misleading the operator about the verify outcome.
        if (after != null) {
          final files = await _jobFileDao.getFilesForJob(after.id);
          if (files.any((f) =>
              f.verifyStatus == VerifyStatus.mismatch ||
              f.verifyStatus == VerifyStatus.unverified)) {
            hadVerifyWarnings = true;
          }
        }
        _currentJobId = null;
      }
    } finally {
      // Loop exited (queue drained, stopped, or threw). Resolve any
      // pending stopProcessing future AFTER state writes are complete.
      final completer = _stopCompleter;
      _stopCompleter = null;
      completer?.complete();
      // Emit allDone only when the queue drained naturally with no
      // failures, no verify warnings, AND we actually processed
      // something. A pure Stop (no work happened) MUST NOT trigger
      // the celebration; neither does a run that produced
      // verifyStatus=mismatch / unverified rows (Codex round-18 P2 #2).
      if (processedAny && !hadFailures && !hadVerifyWarnings && !_stoppedByUser) {
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
    // 018 T010 (FR-008, US3): set _stopRequested SYNCHRONOUSLY at the
    // top so any concurrent startProcessing() that arrives after this
    // call (but before the loop drains) observes the request via the
    // unresolved _stopCompleter and waits for drain. Mid-iteration loop
    // checks also see the flag immediately on the next await
    // resumption.
    _stopRequested = true;
    // Reentrant: a second call (e.g., tray quit fired right after the UI
    // stop button) must observe the SAME pending completer until the
    // loop actually exits. Returning `Future.value()` here once the flag
    // is flipped would let shutdown close the database mid-write.
    final pending = _stopCompleter;
    if (pending != null) return pending.future;
    if (!_isProcessing) {
      // Either never started, or already finished cleanly — nothing to await.
      // Reset the request flag so a future startProcessing() proceeds cleanly.
      _stopRequested = false;
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

  /// 017B (Codex round-14 P2 #2): after the operator resolves verify
  /// warnings on a transferAndCompress parent (Retry or Accept), the
  /// auto-chain that was suppressed at finalize time needs a way to
  /// fire. This helper:
  ///   - returns false if [parentJobId] isn't a transferAndCompress
  ///     OR if a chained child already exists OR if files still have
  ///     unresolved mismatch/unverified rows.
  ///   - otherwise creates the chained compression job and returns
  ///     true.
  /// Operator-attribution: only called from explicit "Resume
  /// compression" / "Accept" UI handlers, never from the executor.
  Future<bool> maybeChainCompression(int parentJobId) async {
    final created = await createChainedCompressionJobIfAbsent(parentJobId);
    if (created == null) return false;
    _logService?.info(
      'Operator-resumed compression chain for transferAndCompress '
      'parent #$parentJobId',
      jobId: parentJobId,
      phase: LogPhase.finalize,
    );
    await startProcessing();
    return true;
  }

  /// 018 T008 (FR-007, US3, P2): centralized chain-creation gate.
  /// Wraps `hasChainedChild` check + parent fetch + verify-axis gate
  /// + insertion in a single Drift transaction. Two concurrent
  /// invocations against the same parent will see the first
  /// invocation's INSERT inside the transaction's read snapshot —
  /// only one chained child is ever created.
  ///
  /// Replaces the prior "check + insert" pattern that was spread
  /// across multiple awaits without a transaction. Reachable today
  /// via Accept-mismatched + Accept-unverified clicked in quick
  /// succession on the same job; round-22 P2 flagged the resulting
  /// race that could spawn duplicate compression children competing
  /// for the same destination path.
  ///
  /// Returns the new chained child's job id on success, `null` on
  /// dedup hit OR any gate failure (parent missing / wrong type /
  /// wrong status / non-completed file row / unresolved verify
  /// warning / no compression-ready files).
  ///
  /// Both auto-chain (`_processJob` post-clean-transfer) and
  /// operator-driven chain (`maybeChainCompression`) MUST route
  /// through this method. Direct calls to `_createChainedCompressionJob`
  /// from outside the gate would bypass the dedup invariant.
  Future<int?> createChainedCompressionJobIfAbsent(int parentJobId) async {
    // Inline the _safeWrite abandonment-check pattern: this method
    // returns int? (the new child id), but _safeWrite is typed
    // Future<void>. Mirroring the same drop-on-abandon + rethrow-
    // otherwise semantics directly here avoids generifying _safeWrite
    // and touching every existing caller.
    if (_shutdownAbandoned) return null;
    try {
      return await _jobDao.transaction(() async {
        final parent = await _jobDao.getJob(parentJobId);
        if (parent == null) return null;
        if (parent.type != JobType.transferAndCompress) return null;
        // Dedup gate inside the transaction: a second concurrent
        // invocation will see the first's INSERT here even though
        // both invocations entered the transaction concurrently —
        // SQLite serializes writes via BEGIN IMMEDIATE.
        if (await _jobDao.hasChainedChild(parentJobId)) return null;

        // Codex round-16 P1 #2: refuse to chain if the parent is in
        // any non-completed terminal state. A transferAndCompress
        // with copy failures sits at status=failed; chaining over
        // the copy-completed subset would silently drop the failed
        // files from the operator's intent.
        if (parent.status != JobStatus.completed &&
            parent.status != JobStatus.paused) {
          return null;
        }

        final files = await _jobFileDao.getFilesForJob(parentJobId);
        final hasNonCompletedRow =
            files.any((f) => f.status != FileStatus.completed);
        if (hasNonCompletedRow) return null;

        final hasNonCleanVerify = files.any((f) =>
            f.verifyStatus == VerifyStatus.mismatch ||
            f.verifyStatus == VerifyStatus.unverified);
        if (hasNonCleanVerify) return null;

        return await _createChainedCompressionJob(parent);
      });
    } catch (_) {
      if (_shutdownAbandoned) return null;
      rethrow;
    }
  }

  /// 017 (US2, T040, FR-005, Codex H2): operator-driven retry of a single
  /// file (typically after a verify mismatch). When [forceDestDelete] is
  /// true, the next pass through `_processTransfer` will delete the
  /// destination before robocopy regardless of size match — closes the
  /// "same-size corrupt destination" loop where the feature-015 delete
  /// predicate would skip robocopy and re-verify the same corrupt bytes
  /// forever.
  ///
  /// Resets the file row's verify axis (verifyStatus/failureKind/hashes)
  /// AND the parent job's status to pending so the queue scheduler can
  /// pick the job up again. Persists the operator's force-delete intent
  /// to `JobFile.forceDestDeleteApproved` so it survives app exit
  /// between the Retry click and `_processTransfer`'s consumption
  /// (Codex round-2 P2 #2).
  Future<void> retryFile(int fileId, {bool forceDestDelete = false}) async {
    final file = await _jobFileDao.getFile(fileId);
    if (file == null) return;
    if (forceDestDelete) {
      _logService?.warning(
        'Operator retry of ${file.fileName} with forceDestDelete=true '
        'after verify mismatch — approval persisted to '
        'JobFile.forceDestDeleteApproved (Codex round-2 P2 #2)',
        jobId: file.jobId,
        phase: LogPhase.recover,
      );
    }
    // 018 T003 (FR-001 + FR-002, US1): single atomic call replaces
    // the prior two-write sequence (resetFileForRetry +
    // requeueJobForFileRetry). Either the entire retry intent is
    // persisted or none of it is — eliminates the "ghost pending"
    // failure mode where a crash between the two writes left the
    // file at status=pending while the parent stayed at
    // status=completed (no recovery arm matched, intent lost).
    //
    // Public signature unchanged. Existing callers see no surface
    // change. Codex round-16 P1 #1's per-file-scoped semantics are
    // preserved (resetFileForRetry is still the inner row reset; we
    // do NOT route through resetJobForRetry which would arm every
    // verifyMismatch row).
    await _safeWrite(() => _jobDao.applyPerFileRetry(
          jobId: file.jobId,
          fileId: fileId,
          forceDestDelete: forceDestDelete,
        ));
  }

  Future<void> _processJob(Job job) async {
    _logService?.info(
      'Job started — ${job.type.name} ${job.sourcePath} → ${job.destinationPath}',
      jobId: job.id,
      phase: LogPhase.enqueue,
    );
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
          // Codex round-13 P2 #2: auto-chain compression ONLY when
          // every file passed verification. If any file ended at
          // verifyStatus=mismatch / unverified, _createChainedCompressionJob
          // would silently exclude them (it filters on the legacy
          // `verified` boolean), compressing only the verified
          // subset before the operator has triaged the warnings.
          // Pause for explicit operator decision instead.
          final updatedJob = await _jobDao.getJob(job.id);
          if (updatedJob?.status == JobStatus.completed) {
            final files = await _jobFileDao.getFilesForJob(job.id);
            final hasNonCleanVerify = files.any((f) =>
                f.verifyStatus == VerifyStatus.mismatch ||
                f.verifyStatus == VerifyStatus.unverified);
            if (hasNonCleanVerify) {
              _logService?.warning(
                'Auto-chain compression suppressed: '
                '${files.where((f) => f.verifyStatus == VerifyStatus.mismatch).length} '
                'mismatch + '
                '${files.where((f) => f.verifyStatus == VerifyStatus.unverified).length} '
                'unverified files. Operator must Retry or Accept the '
                'mismatches before compression auto-chains.',
                jobId: job.id,
                phase: LogPhase.finalize,
              );
            } else {
              // 018 T009 (FR-007, US3): route through the centralized
              // dedup gate. Both auto-chain (this site) and operator-
              // driven chain (maybeChainCompression) MUST go through
              // the same gate so the hasChainedChild check + insert
              // is transactional. Direct calls would re-open the
              // round-22 P2 race where two paths could both insert.
              await createChainedCompressionJobIfAbsent(job.id);
            }
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
          // 018 T021 (FR-013, US5): atomic single-transaction variant
          // replaces the previous two `_safeWrite`s. If a Phase-B drain
          // had timed out between them, the row write could land while
          // the counter increment got dropped, leaving Job.unverifiedFiles
          // permanently under-counted. The local `unverifiedCount++`
          // stays — it's the in-memory tally for the end-of-loop Slack
          // notification, separate from the persisted Job counter.
          await _safeWrite(
              () => _jobFileDao.markFileUnverifiedAndIncrement(file.id));
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

      // Codex round-20 P2 #1: pre-existing `failed` rows are NOT auto-
      // reprocessed. The "Retry failed files" path (`resetJobForRetry`)
      // flips them to `pending` BEFORE requeuing, so a true full-retry
      // pass sees them as pending and processes them. A per-file retry
      // (`requeueJobForFileRetry` via `retryFile`) intentionally leaves
      // other failed rows alone — the operator chose ONE file. Without
      // this skip, the executor's loop would fall through to the dest
      // checks below and re-copy/re-delete unrelated destinations.
      // Tally into `failedCount` so the post-loop branch still routes
      // through `notifyJobFailed` and the job stays `failed` rather
      // than being silently lifted to `completed` by the per-file
      // retry's success.
      if (file.status == FileStatus.failed) {
        failedCount++;
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
          case VerifyStatus.notVerified:
            // Size-mode baseline — bytes match by size, no SHA-256 was
            // attempted. Counted neither as verified nor as warning.
            break;
        }
        continue;
      }

      // 017 (US2, T040, FR-005, Codex H2 + round-2 P2 #2 + round-3 P2 #2):
      // consume the persisted force-delete approval ONCE per processing
      // pass, regardless of dest existence or which branch we land in
      // below. Reading + clearing here gives us correct single-use
      // semantics even when the dest was deleted before this pass: the
      // approval is consumed even if no delete happens. A re-mismatch
      // on the next pass requires a fresh banner Retry click.
      final forceDestDelete = file.forceDestDeleteApproved;
      if (forceDestDelete) {
        await _safeWrite(
            () => _jobFileDao.clearForceDestDeleteApproved(file.id));
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
          // 017 (US2, T040, FR-005, Codex H2): operator-driven retry of
          // a verify-mismatched file. Bypasses the entire feature-015
          // delete predicate AND the size-match short-circuit below —
          // even a dest with `wasOverwriteApproved=false` and identical
          // size to source is replaced wholesale, because the bytes
          // have already been verified to differ. The approval was
          // already consumed at the top of this iteration via
          // `forceDestDelete` (Codex round-3 P2 #2 single-use clear).
          final shouldDelete = forceDestDelete ||
              file.wasOverwriteApproved ||
              (everAttempted && isPartial);

          if (shouldDelete) {
            try {
              await destFile.delete();
              _logService?.info(
                'Pre-robocopy cleanup of destination $destPath '
                '(approved=${file.wasOverwriteApproved}, '
                'attempted=$everAttempted, partial=$isPartial, '
                'forceDestDelete=$forceDestDelete)',
                jobId: job.id,
                phase: forceDestDelete ? LogPhase.recover : LogPhase.transfer,
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
            // 018 T021 (FR-013): atomic variant — see recovery branch
            // above for rationale.
            await _safeWrite(
                () => _jobFileDao.markFileUnverifiedAndIncrement(file.id));
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
          // 017B Codex round-11: forward operation now writes
          // verifyStatus=notVerified (matching the v8 migration
          // backfill) so size-mode rows are visibly distinct from
          // SHA-256 subsystem failures (`unverified`). HistorySurface
          // and Slack treat notVerified as the size-mode baseline.
          final verified = await _transferService.verifyTransfer(
            sourceFile: file.sourceFilePath,
            destinationFile: file.destinationFilePath,
          );
          if (verified) {
            await _safeWrite(
                () => _jobFileDao.markFileSizeOnlyVerified(file.id));
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
        _logService?.error(
          'File transfer failed: ${file.fileName}',
          jobId: job.id,
          fileIndex: completedCount + failedCount,
          totalFiles: files.length,
          phase: LogPhase.transfer,
        );
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
      // Codex round-13 P2 #1: route failed-copy jobs through
      // notifyJobFailed instead of the green-check-by-default
      // notifyTransferCompleted. Without this branch a job that
      // markJobFailed-ed above would still send "Transfer Complete /
      // Passed" to Slack — silent false success.
      await _slackService.notifyJobFailed(
        jobId: job.id,
        phase: 'Transfer',
        error:
            '$completedCount/${completedCount + failedCount} files transferred, '
            '$failedCount failed copy',
      );
      return;
    }
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
          'Compressed ${file.fileName}',
          jobId: job.id,
          fileIndex: completedCount,
          totalFiles: files.length,
          phase: LogPhase.compress,
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
          'Compression failed: ${file.fileName}',
          jobId: job.id,
          fileIndex: completedCount + failedCount,
          totalFiles: files.length,
          phase: LogPhase.compress,
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
        'Compression FAILED — $completedCount/${files.length} compressed, '
        '$failedCount failed',
        jobId: job.id,
        phase: LogPhase.finalize,
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
      int? parentNotVerifiedFiles;
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
          // Codex round-20 P2 #2: count the size-mode baseline rows so
          // a default (size-mode) transferAndCompress chained Slack
          // ping doesn't read "Transfer verification: 0 verified ·
          // Passed" when every file actually passed size verification.
          parentNotVerifiedFiles = parentFiles
              .where((f) => f.verifyStatus == VerifyStatus.notVerified)
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
        parentNotVerifiedFiles: parentNotVerifiedFiles,
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

    // 017 (T058, FR-008, Codex H3): NTFS is case-insensitive. Two source
    // files with paths that differ only in case (e.g., `DCIM/IMG_001.MOV`
    // and `dcim/img_001.MOV` from a case-sensitive source like exFAT or
    // a network share) collapse to the same destination NTFS file and
    // silently overwrite one another mid-batch. `File.existsSync()` in
    // _applyResolution only catches collisions against pre-existing
    // disk state, NOT collisions WITHIN the planned set.
    //
    // Walk the planned set with a case-insensitive Set<String> of claimed
    // destinations; on duplicate, route the second-and-later occurrences
    // through a suffixed rename whose candidate is also checked against
    // the claimed set so generated suffixes don't re-collide.
    _normalizeCaseCollisionsAcrossPlans(cardPlans);

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

    // Codex round-12 P1: the rename branch must check against the
    // lowercased PLANNED-set, not just disk. After case-collision
    // normalization, the planned set may contain `foo_1.mov` as the
    // second occurrence of a case-collision; a naive disk-only
    // _suffixedPath for the original `FOO.mov` would happily pick
    // `FOO_1.mov` (lowercased = same NTFS key) and re-collide. Build
    // the lowercased claimed set from EVERY plan in this batch, then
    // route renames through _suffixedPathAgainst.
    final claimedLower = <String>{};
    for (final plan in plans) {
      for (final file in plan.files) {
        claimedLower.add(file.destinationPath.toLowerCase());
      }
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
            // drop — release the claimed key so a later rename can use it.
            claimedLower.remove(file.destinationPath.toLowerCase());
            break;
          case ConflictResolution.rename:
            // Drop the original claimed key (we're about to relocate
            // the file), then mint a suffix that's free both on disk
            // AND across the rest of the planned set.
            claimedLower.remove(file.destinationPath.toLowerCase());
            final renamed =
                _suffixedPathAgainst(file.destinationPath, claimedLower);
            claimedLower.add(renamed.toLowerCase());
            kept.add(file.copyWith(destinationPath: renamed));
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

  // _suffixedPath retired — _applyResolution now uses
  // _suffixedPathAgainst with the lowercased planned-set so suffix
  // generation can't re-collide on NTFS (Codex round-12 P1 fix).

  /// 017 (T058, FR-008, Codex H3): suffixed-rename variant that ALSO
  /// rejects candidates whose lowercased form is already claimed in
  /// [takenLower]. Without this check, two case-only-conflicting sources
  /// (`IMG_001.MOV` vs `img_001.mov`) could both rename to `IMG_001_1.mov`
  /// vs `img_001_1.mov` and re-collide on NTFS.
  String _suffixedPathAgainst(String path, Set<String> takenLower) {
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '${stem}_$i$ext');
      final candidateLower = candidate.toLowerCase();
      if (!takenLower.contains(candidateLower) &&
          !File(candidate).existsSync()) {
        return candidate;
      }
      i++;
    }
  }

  /// 017 (T058, FR-008, Codex H3): in-place rewrite of any planned
  /// destination that case-only-conflicts with another already-claimed
  /// destination in the same batch. Walks every plan, every file, in
  /// order; the first occurrence keeps its destination, subsequent
  /// occurrences are rerouted via [_suffixedPathAgainst].
  ///
  /// The detector + rewriter is a single pass to keep the implementation
  /// simple; the [takenLower] set is mutated as we go so generated
  /// suffixes account for prior renames.
  void _normalizeCaseCollisionsAcrossPlans(List<_CardTransferPlan> plans) {
    final flatLists = plans.map((plan) => plan.files).toList();
    normalizeCaseCollisions(
      flatLists,
      onRename: (original, renamed) {
        _logService?.warning(
          'Case-only destination collision: $original collapses to '
          'existing NTFS key — renaming to $renamed',
          phase: LogPhase.preflight,
        );
      },
    );
  }

  /// 017 (T058, FR-008, Codex H3, T060): pure algorithm extracted from
  /// [_normalizeCaseCollisionsAcrossPlans] so it's unit-testable without
  /// a real drive/filesystem setup. Mutates the lists in [plans] in place
  /// to break case-only NTFS collisions.
  ///
  /// First occurrence of each case-folded destination keeps the original
  /// path; later occurrences are rerouted via the same suffixed-rename
  /// pattern used elsewhere ([_suffixedPathAgainst]). The [onRename]
  /// callback fires once per rewrite for telemetry/logging.
  ///
  /// Public (not @visibleForTesting) because the single-job preflight in
  /// `CreateJobScreen` calls this directly — Codex round-4 P2 #2 fix.
  void normalizeCaseCollisions(
    List<List<PlannedFile>> plans, {
    void Function(String original, String renamed)? onRename,
  }) {
    final takenLower = <String>{};
    for (final files in plans) {
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        final lower = file.destinationPath.toLowerCase();
        if (!takenLower.contains(lower)) {
          takenLower.add(lower);
          continue;
        }
        final renamed =
            _suffixedPathAgainst(file.destinationPath, takenLower);
        files[i] = file.copyWith(destinationPath: renamed);
        takenLower.add(renamed.toLowerCase());
        onRename?.call(file.destinationPath, renamed);
      }
    }
  }

  /// Create a chained compression job after a successful transfer.
  /// Preserves the relative folder structure from the transfer destination
  /// so duplicate basenames in different folders cannot collide in the
  /// compression output.
  // 018 T008/T009 (FR-007): returns the new child's job id so the
  // centralized gate `createChainedCompressionJobIfAbsent` can hand
  // it back to callers. MUST only be called from inside that gate
  // (or its transaction); calling directly from the outside bypasses
  // the dedup invariant.
  Future<int?> _createChainedCompressionJob(Job transferJob) async {
    final outputPath = transferJob.compressionOutputPath;
    if (outputPath == null) return null;

    final transferFiles = await _jobFileDao.getFilesForJob(transferJob.id);
    // Codex round-15 P1: filter on the v8 verify axis, not the legacy
    // `verified` boolean. acceptMismatch / acceptUnverified
    // intentionally leave `verified=false` (so it doesn't lie about
    // cryptographic trust) but flip verifyStatus to verified /
    // notVerified — meaning the operator approved the file for
    // downstream compression. Filtering by `verified=true` would
    // silently exclude every accepted file from the compression
    // child even though the operator's intent was the opposite.
    //
    // Compression-ready ≡ status=completed AND verifyStatus is one
    // the operator considers acceptable: `verified` (SHA-256 match),
    // `notVerified` (size-mode baseline OR operator-accepted
    // unverified). `mismatch` and `unverified` are still excluded
    // because they're unresolved warnings; maybeChainCompression
    // already gated on those upstream, but the defense-in-depth
    // filter here ensures a stray re-call can't sneak them through.
    final ready = transferFiles
        .where((f) =>
            f.status == FileStatus.completed &&
            (f.verifyStatus == VerifyStatus.verified ||
                f.verifyStatus == VerifyStatus.notVerified))
        .toList();

    if (ready.isEmpty) return null;

    final totalBytes = ready.fold<int>(0, (sum, f) => sum + f.fileSize);
    final baseOrder = await _jobDao.getMaxSortOrder();

    return await _jobDao.createJobWithFiles(
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
