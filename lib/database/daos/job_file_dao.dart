import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'job_file_dao.g.dart';

@DriftAccessor(tables: [JobFiles])
class JobFileDao extends DatabaseAccessor<AppDatabase> with _$JobFileDaoMixin {
  JobFileDao(super.db);

  /// Watch all files for a specific job.
  Stream<List<JobFile>> watchFilesForJob(int jobId) {
    return (select(jobFiles)..where((t) => t.jobId.equals(jobId))).watch();
  }

  /// Get all files for a job.
  Future<List<JobFile>> getFilesForJob(int jobId) {
    return (select(jobFiles)..where((t) => t.jobId.equals(jobId))).get();
  }

  /// 017B (FR-B08): the HistorySurface tallies verify-axis state per
  /// job to drive its status-filter chips (Verified / Unverified /
  /// Mismatch). Streaming the full file table is fine for the
  /// operator's expected scale; if it becomes a bottleneck swap for
  /// a per-job aggregate DAO query.
  Stream<List<JobFile>> watchAllFiles() {
    return select(jobFiles).watch();
  }

  /// Get a single file by its primary key.
  Future<JobFile?> getFile(int fileId) {
    return (select(jobFiles)..where((t) => t.id.equals(fileId)))
        .getSingleOrNull();
  }

  /// Get next pending file for a job.
  Future<JobFile?> getNextPendingFile(int jobId) {
    return (select(jobFiles)
          ..where(
            (t) =>
                t.jobId.equals(jobId) &
                t.status.equalsValue(FileStatus.pending),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Insert multiple files for a job.
  Future<void> insertFiles(List<JobFilesCompanion> files) async {
    await batch((batch) {
      batch.insertAll(jobFiles, files);
    });
  }

  /// Update file status.
  Future<void> updateFileStatus(int fileId, FileStatus status) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId)))
        .write(JobFilesCompanion(status: Value(status)));
  }

  /// Mark file as started.
  Future<void> markFileStarted(int fileId) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        status: const Value(FileStatus.inProgress),
        startedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Mark file as completed (bytes on disk after robocopy success).
  ///
  /// 017 (T028): [verified] is now OPTIONAL with default `false`. The post-
  /// robocopy path calls `markFileCompleted(fileId)` to credit bytes to
  /// progress immediately (FR-002), independent of verify outcome. The
  /// verify-side state is set later by [markFileVerified] /
  /// [markFileVerifyMismatch] / [markFileUnverified].
  ///
  /// Backward-compat: legacy callers passing `verified: true` still work.
  ///
  /// `verifyStatus` is INTENTIONALLY left untouched — the SHA-256
  /// success path uses [markFileVerified] explicitly. Size-mode rows
  /// keep `verifyStatus=pending`; recovery filters size-mode jobs out
  /// of the "completed+pending" rescue set via the parent's
  /// `verificationMode` (Codex round-3 P2 #1).
  Future<void> markFileCompleted(int fileId, {bool verified = false}) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        status: const Value(FileStatus.completed),
        verified: Value(verified),
        completedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 017 (T029, FR-003): SHA-256 verification passed (cryptographic trust).
  /// Sets `verified=true` (legacy boolean) AND `verifyStatus='verified'`,
  /// stores hashes for audit. Does NOT touch `status` — that's already
  /// `completed` from `markFileCompleted`.
  Future<void> markFileVerified(
    int fileId, {
    required String sourceHash,
    required String destHash,
  }) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        verified: const Value(true),
        verifyStatus: const Value(VerifyStatus.verified),
        failureKind: const Value(FailureKind.none),
        sourceHash: Value(sourceHash),
        destinationHash: Value(destHash),
      ),
    );
  }

  /// 017 (T029, FR-003): SHA-256 mismatch — bytes on disk are corrupt.
  /// Sets `verifyStatus='mismatch'`, `failureKind='verifyMismatch'`. Does
  /// NOT change `status` (bytes are still on disk; FR-004) and does NOT
  /// decrement copy counters. Operator sees a banner with Investigate /
  /// Retry / Skip; Retry routes through `forceDestDelete=true` (Codex H2).
  Future<void> markFileVerifyMismatch(
    int fileId, {
    String? sourceHash,
    String? destHash,
  }) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        verifyStatus: const Value(VerifyStatus.mismatch),
        failureKind: const Value(FailureKind.verifyMismatch),
        sourceHash: Value(sourceHash),
        destinationHash: Value(destHash),
      ),
    );
  }

  /// 017 (T029, FR-003): verification subsystem failed (PS broken, hash
  /// returned malformed output, etc.) — bytes on disk are NOT proven
  /// trustworthy but are also NOT proven corrupt. Warning state, not a
  /// hard fail. UI shows ⚠ chip; Job.unverifiedFiles increments via
  /// JobDao.incrementUnverified.
  Future<void> markFileUnverified(int fileId) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      const JobFilesCompanion(
        verifyStatus: Value(VerifyStatus.unverified),
        failureKind: Value(FailureKind.verifyUnreliable),
      ),
    );
  }

  /// 017 (T030, FR-006/FR-007): used by `recoverStaleJobs` to detect
  /// `status=completed && verifyStatus=pending` rows — files where
  /// robocopy succeeded before shutdown but the SHA-256 check never
  /// ran. These re-enter verify-only on next launch (no re-copy).
  Future<List<JobFile>> getFilesByStateAndVerify({
    required FileStatus status,
    required VerifyStatus verifyStatus,
  }) {
    return (select(jobFiles)
          ..where((t) =>
              t.status.equalsValue(status) &
              t.verifyStatus.equalsValue(verifyStatus)))
        .get();
  }

  /// Mark file as failed with error.
  Future<void> markFileFailed(int fileId, String error) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        status: const Value(FileStatus.failed),
        errorMessage: Value(error),
        completedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Reset a file back to pending state — used when an in-flight transfer
  /// or hash is cancelled (operator stop, app shutdown). The file should
  /// resume cleanly via robocopy `/Z` on next start, NOT be reported as
  /// a permanent failure.
  Future<void> resetFileToPending(int fileId) {
    // 015: deliberately PRESERVE `startedAt` across resets. The
    // executor uses `startedAt != null` as the "ever attempted"
    // signal — distinguishes our own /Z partial fragments (deletable)
    // from never-attempted-file dest intrusions (leave alone).
    // Clearing it would re-arm the partial as a TOCTOU rogue.
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      const JobFilesCompanion(
        status: Value(FileStatus.pending),
        completedAt: Value(null),
        errorMessage: Value(null),
      ),
    );
  }

  /// Reset a per-file row back to pending after operator-driven retry of
  /// a verify-mismatch (017 US2, T040, Codex H2). Differs from
  /// [resetFileToPending]: this clears the verify axis (verifyStatus,
  /// failureKind, hashes) so the row re-enters the verify pipeline as
  /// if it had never been verified. `startedAt` is preserved (load-bearing
  /// 015 invariant — distinguishes own /Z partials from intrusions).
  ///
  /// Codex round-2 P2 #2: when [forceDestDeleteApproved] is true, persist
  /// the operator's force-delete approval to the column so it survives
  /// app exit / crash between the Retry click and `_processTransfer`
  /// consumption. Defaults to false to preserve "no-op for unrelated
  /// resets" semantics.
  Future<void> resetFileForRetry(int fileId,
      {bool forceDestDeleteApproved = false}) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        status: const Value(FileStatus.pending),
        completedAt: const Value(null),
        errorMessage: const Value(null),
        verifyStatus: const Value(VerifyStatus.pending),
        failureKind: const Value(FailureKind.none),
        sourceHash: const Value(null),
        destinationHash: const Value(null),
        forceDestDeleteApproved: Value(forceDestDeleteApproved),
      ),
    );
  }

  /// 017 (v8, Codex round-2 P2 #2): clear the persisted force-delete
  /// approval after `_processTransfer` consumes it (post-delete +
  /// robocopy). Single-use semantics: a re-mismatch on the next pass
  /// requires the operator to re-approve via the banner, never an
  /// automatic re-bypass.
  Future<void> clearForceDestDeleteApproved(int fileId) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      const JobFilesCompanion(forceDestDeleteApproved: Value(false)),
    );
  }

  /// Store SHA-256 hashes on a file record.
  Future<void> updateFileHashes(int fileId, {String? sourceHash, String? destinationHash}) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        sourceHash: Value(sourceHash),
        destinationHash: Value(destinationHash),
      ),
    );
  }

  /// Count completed files for a job.
  Future<int> countCompletedFiles(int jobId) async {
    final count = jobFiles.id.count();
    final query = selectOnly(jobFiles)
      ..addColumns([count])
      ..where(
        jobFiles.jobId.equals(jobId) &
            jobFiles.status.equalsValue(FileStatus.completed),
      );
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }
}
