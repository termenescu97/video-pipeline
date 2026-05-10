import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../services/log_service.dart';
import '../database.dart';
import '../tables.dart';

part 'job_dao.g.dart';

@DriftAccessor(tables: [Jobs, JobFiles])
class JobDao extends DatabaseAccessor<AppDatabase> with _$JobDaoMixin {
  JobDao(super.db);

  /// Optional logger for recovery events. Wired in main.dart after
  /// LogService.init(). Final-review fix #6: rescued jobs were
  /// previously invisible to post-mortem; now each one writes a line
  /// to copiatorul3000.log.
  LogService? logService;

  /// 018 T022 (FR-013, US5, P3): self-healing read paths. The four
  /// operator-facing reads ([getJob], [watchJob], [watchAllJobs],
  /// [watchCompletedJobs]) join `jobs` to a per-job aggregate
  /// sub-select that computes `actual_unverified = COUNT(*) FROM
  /// job_files WHERE verify_status = 'unverified'`. The returned
  /// [Job.unverifiedFiles] is the JOIN result, not the persisted
  /// column. Persisted `jobs.unverified_files` becomes a denormalized
  /// cache for write paths that don't go through these reads; the
  /// reads always self-correct without an extra round-trip.
  ///
  /// Single query per emission keeps the SQLite cost identical to the
  /// previous `select(jobs)` shape — the sub-select is row-local.
  /// Codex round-23 P2 corrected the original "wrap each method with
  /// per-row COUNT round-trips" plan; that would have multiplied query
  /// load on the high-traffic UI streams.
  static const String _jobsWithSelfHealedUnverifiedSelect = '''
    SELECT jobs.*,
      (SELECT COUNT(*) FROM job_files
         WHERE job_id = jobs.id AND verify_status = 'unverified'
      ) AS actual_unverified
    FROM jobs
  ''';

  Job _mapWithSelfHealedUnverified(QueryRow row) {
    final base = jobs.map(row.data);
    final actual = row.read<int>('actual_unverified');
    return base.unverifiedFiles == actual
        ? base
        : base.copyWith(unverifiedFiles: actual);
  }

  /// Watch all jobs ordered by sort order (queue order).
  Stream<List<Job>> watchAllJobs() {
    return customSelect(
      '$_jobsWithSelfHealedUnverifiedSelect '
      'ORDER BY sort_order ASC, created_at ASC',
      readsFrom: {jobs, jobFiles},
    ).watch().map(
        (rows) => rows.map(_mapWithSelfHealedUnverified).toList());
  }

  /// Persist a new queue ordering (T065 fix from Codex Phase 9 review —
  /// the previous swap-only `reorderJobs` was a v2.3.0 bug that became
  /// reachable once the drag handle gained visible affordance).
  ///
  /// [orderedJobIds] is the desired top-to-bottom order; each row gets
  /// `sortOrder = index` inside a single transaction so partial state is
  /// not observable. IDs not present in the list are left untouched
  /// (Active stays at its current sortOrder; completed jobs in the
  /// Activity panel are untouched).
  ///
  /// Re-numbering 0..n-1 means inserting C at index 0 from `[A, B, C]`
  /// produces `[C, A, B]` — true insertion semantics, not a two-row
  /// swap that would have produced `[C, B, A]`.
  Future<void> setJobsOrder(List<int> orderedJobIds) async {
    if (orderedJobIds.isEmpty) return;
    await transaction(() async {
      for (var i = 0; i < orderedJobIds.length; i++) {
        await (update(jobs)..where((t) => t.id.equals(orderedJobIds[i])))
            .write(JobsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Watch jobs filtered by status.
  Stream<List<Job>> watchJobsByStatus(JobStatus status) {
    return (select(jobs)..where((t) => t.status.equalsValue(status))).watch();
  }

  /// Watch a single job by ID (efficient). 018 T022: self-healed
  /// `unverifiedFiles` via the join in
  /// [_jobsWithSelfHealedUnverifiedSelect].
  Stream<Job?> watchJob(int jobId) {
    return customSelect(
      '$_jobsWithSelfHealedUnverifiedSelect WHERE id = ?',
      variables: [Variable.withInt(jobId)],
      readsFrom: {jobs, jobFiles},
    ).watch().map(
        (rows) => rows.isEmpty ? null : _mapWithSelfHealedUnverified(rows.first));
  }

  /// Get the next queued or paused job (first in queue).
  ///
  /// Orders by [Jobs.sortOrder] first (matching UI display after
  /// drag-reorder), then [Jobs.createdAt] as a tiebreaker.
  Future<Job?> getNextQueuedJob() {
    return (select(jobs)
          ..where(
            (t) =>
                t.status.equalsValue(JobStatus.queued) |
                t.status.equalsValue(JobStatus.paused),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Returns the highest sortOrder currently assigned to any active
  /// (queued or paused) job, or 0 if none. Used to place new jobs at
  /// the end of the queue.
  Future<int> getMaxSortOrder() async {
    final maxExpr = jobs.sortOrder.max();
    final query = selectOnly(jobs)
      ..where(
        jobs.status.equalsValue(JobStatus.queued) |
            jobs.status.equalsValue(JobStatus.paused),
      )
      ..addColumns([maxExpr]);
    final row = await query.getSingleOrNull();
    return row?.read(maxExpr) ?? 0;
  }

  /// US7 polish (T100): in-memory set of job IDs that THIS process
  /// rescued from in-progress on cold start. Populated inside
  /// [recoverStaleJobs] and read by [JobCardQueued]/[JobCardNextUp]
  /// to render a "Recovered after restart" chip.
  ///
  /// Clearing semantics (FR-051): an entry is removed only when the
  /// operator acts on THAT specific job (resume / cancel / delete /
  /// retry). Creating an UNRELATED new job does NOT clear other
  /// jobs' chips — operators get to see the recovery signal until
  /// they explicitly address each rescued job. Resets on app restart
  /// (in-memory; no schema change).
  final Set<int> _recoveredJobIds = <int>{};
  Set<int> get recoveredJobIds => Set.unmodifiable(_recoveredJobIds);

  /// Operator-action signal: drop [jobId] from [recoveredJobIds].
  /// Called by JobCardQueued/NextUp's resume/cancel/delete/retry
  /// handlers. Idempotent — safe to call for non-recovered IDs.
  void markRecoveryAcknowledged(int jobId) {
    _recoveredJobIds.remove(jobId);
  }

  /// Recover jobs left in [JobStatus.inProgress] state from a previous run
  /// (crash, power loss, kill). Moves them and their in-progress files back
  /// to a resumable state so the operator can review and manually resume.
  ///
  /// 017 (T046-T048, FR-006/FR-007/FR-018): also detects
  /// `status=completed && verifyStatus=pending` rows (NEW v8 stale state —
  /// abandoned shutdown mid-verify). These stay at `status=completed`;
  /// `_processTransfer`'s recovery branch (T046) re-enters verify-only
  /// on next launch — bytes are NOT re-credited.
  ///
  /// After all stale-row mutations, re-derives Job aggregate counters
  /// once per rescued job from per-row state (FR-018).
  ///
  /// Per the spec, recovery moves to [JobStatus.paused] (not
  /// [JobStatus.queued]) so the operator must explicitly resume after
  /// reviewing.
  Future<void> recoverStaleJobs() async {
    // Capture the rows BEFORE the update so we know which jobs we
    // touched (and so the log entry has source/dest paths). Reading
    // after the update would lose the set (those rows are now
    // `paused`, indistinguishable from operator-paused jobs).
    final rescuedJobs = await (select(jobs)
          ..where((t) => t.status.equalsValue(JobStatus.inProgress)))
        .get();

    // 017 (T046, FR-018): the rescued-job set per the spec's union
    // definition — jobs.status=inProgress UNION jobs with files in
    // inProgress UNION jobs with files in completed+verifyStatus=pending.
    // Used at the end for per-job counter re-derivation.
    final rescuedJobIdSet = await getRescuedJobIds();

    await transaction(() async {
      await (update(jobs)
            ..where((t) => t.status.equalsValue(JobStatus.inProgress)))
          .write(const JobsCompanion(status: Value(JobStatus.paused)));

      await (update(db.jobFiles)
            ..where((t) => t.status.equalsValue(FileStatus.inProgress)))
          .write(
        // 015: preserve `startedAt` so the executor can distinguish
        // our own /Z partial fragments (deletable on resume) from
        // never-attempted-file TOCTOU intrusions (leave alone).
        const JobFilesCompanion(
          status: Value(FileStatus.pending),
        ),
      );

      // 017 (T046, FR-006): copied+pending verify rows stay at
      // status=completed — don't reset (would lose copy progress).
      // _processTransfer's loop has a recovery branch that re-runs
      // verify-only for these. We don't mutate them here.
      //
      // Codex round-5 P2 #1: but the parent job needs to land in a
      // schedulable state — getNextQueuedJob filters out completed/
      // failed jobs, so a rescued job whose ONLY stale signal is a
      // completed+pending verify row would never re-enter
      // _processTransfer. Flip such jobs to paused so the operator
      // can explicitly resume from history.
      if (rescuedJobIdSet.isNotEmpty) {
        final rescuedIds = rescuedJobIdSet.toList();
        await (update(jobs)
              ..where((t) =>
                  t.id.isIn(rescuedIds) &
                  (t.status.equalsValue(JobStatus.completed) |
                      t.status.equalsValue(JobStatus.failed))))
            .write(const JobsCompanion(status: Value(JobStatus.paused)));
      }

      // 017 (T048, FR-018): re-derive Job-level counters once per
      // rescued job after all stale-row mutations. Iterates the
      // union set; safe to call recomputeCountersFromFiles inside
      // the same transaction (Drift uses SAVEPOINT semantics so
      // nested transaction calls do not deadlock).
      for (final jobId in rescuedJobIdSet) {
        await recomputeCountersFromFiles(jobId);
      }
    });

    _recoveredJobIds
      ..clear()
      ..addAll(rescuedJobs.map((j) => j.id));

    // Final-review fix #6: emit one log line per rescued job so the
    // post-mortem trail records what we touched. Trust signal for
    // operators: "yes, the app noticed it crashed and rescued these
    // jobs to a resumable state".
    if (rescuedJobs.isNotEmpty) {
      logService?.warning(
        'Crash recovery: rescued ${rescuedJobs.length} in-progress '
        'job(s) to paused state',
        phase: LogPhase.recover,
      );
      for (final job in rescuedJobs) {
        logService?.warning(
          '  Recovered job #${job.id}: '
          '${job.sourcePath} → ${job.destinationPath}',
          jobId: job.id,
          phase: LogPhase.recover,
        );
      }
    }
    // 017 (T046): summary of the broader rescued set (includes the
    // copied+pending case which doesn't appear in `rescuedJobs`).
    final extraRescued = rescuedJobIdSet.length - rescuedJobs.length;
    if (extraRescued > 0) {
      logService?.info(
        'Recovery: re-derived counters for $extraRescued additional job(s) '
        'with copied-but-unverified files (FR-018)',
        phase: LogPhase.recover,
      );
    }
  }

  /// Atomic job creation. Inserts the job, its files, and totals in a
  /// single Drift transaction so a crash mid-creation leaves no partial
  /// state. The [buildFiles] callback receives the new job ID and must
  /// return the file companions with that ID set.
  ///
  /// Throws [StateError] if [buildFiles] returns an empty list — phantom
  /// zero-file jobs would otherwise be marked completed without ever
  /// transferring anything.
  Future<int> createJobWithFiles({
    required JobsCompanion job,
    required List<JobFilesCompanion> Function(int newJobId) buildFiles,
    required int totalBytes,
  }) async {
    return await transaction(() async {
      final newJobId = await into(jobs).insert(job);
      final files = buildFiles(newJobId);
      if (files.isEmpty) {
        throw StateError(
          'Cannot create a job with zero files. '
          'Filter conflicts at the UI layer before calling createJobWithFiles.',
        );
      }
      await batch((b) => b.insertAll(db.jobFiles, files));
      await (update(jobs)..where((t) => t.id.equals(newJobId))).write(
        JobsCompanion(
          totalFiles: Value(files.length),
          totalBytes: Value(totalBytes),
        ),
      );
      return newJobId;
    });
  }

  /// Insert a new job and return its ID.
  Future<int> insertJob(JobsCompanion job) {
    return into(jobs).insert(job);
  }

  /// Update a job's status.
  Future<void> updateJobStatus(int jobId, JobStatus status) {
    return (update(jobs)..where((t) => t.id.equals(jobId)))
        .write(JobsCompanion(status: Value(status)));
  }

  /// Update job progress counters.
  Future<void> updateJobProgress(
    int jobId, {
    int? completedFiles,
    int? completedBytes,
  }) {
    return (update(jobs)..where((t) => t.id.equals(jobId))).write(
      JobsCompanion(
        completedFiles:
            completedFiles != null ? Value(completedFiles) : const Value.absent(),
        completedBytes:
            completedBytes != null ? Value(completedBytes) : const Value.absent(),
      ),
    );
  }

  /// Mark job as started.
  Future<void> markJobStarted(int jobId) {
    return (update(jobs)..where((t) => t.id.equals(jobId))).write(
      JobsCompanion(
        status: const Value(JobStatus.inProgress),
        startedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Mark job as completed.
  Future<void> markJobCompleted(int jobId) {
    return (update(jobs)..where((t) => t.id.equals(jobId))).write(
      JobsCompanion(
        status: const Value(JobStatus.completed),
        completedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Mark job as failed with error message.
  Future<void> markJobFailed(int jobId, String error) {
    return (update(jobs)..where((t) => t.id.equals(jobId))).write(
      JobsCompanion(
        status: const Value(JobStatus.failed),
        errorMessage: Value(error),
        completedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Update job totals after file enumeration.
  Future<void> updateJobTotals(int jobId, int totalFiles, int totalBytes) {
    return (update(jobs)..where((t) => t.id.equals(jobId))).write(
      JobsCompanion(
        totalFiles: Value(totalFiles),
        totalBytes: Value(totalBytes),
      ),
    );
  }

  /// 017 (T031, FR-003): bump Job.unverifiedFiles by 1 when a file's
  /// hash subsystem failed (verifyStatus=unverified). Verified and
  /// mismatched counts are derived from JobFile rows on read — no
  /// stored column for those.
  Future<void> incrementUnverified(int jobId) async {
    await customStatement(
      'UPDATE jobs SET unverified_files = unverified_files + 1 WHERE id = ?',
      [jobId],
    );
  }

  /// 017 (T032, FR-007/FR-018): re-derive Job-level aggregate counters
  /// from per-file state. Called once per rescued job at the END of
  /// recoverStaleJobs (after all stale-row mutations) so counters
  /// match the persisted truth, regardless of which stale states were
  /// detected. Single statement — Drift transaction is the caller's
  /// responsibility if multi-job batching is needed.
  Future<void> recomputeCountersFromFiles(int jobId) async {
    await customStatement('''
      UPDATE jobs
      SET
        completed_files = (
          SELECT COUNT(*) FROM job_files
          WHERE job_id = ? AND status = 'completed'
        ),
        completed_bytes = COALESCE((
          SELECT SUM(file_size) FROM job_files
          WHERE job_id = ? AND status = 'completed'
        ), 0),
        unverified_files = (
          SELECT COUNT(*) FROM job_files
          WHERE job_id = ? AND verify_status = 'unverified'
        )
      WHERE id = ?
    ''', [jobId, jobId, jobId, jobId]);
  }

  /// 017 (T033, FR-018): the rescued-job set for recovery. Union of:
  ///   (a) Job.status='inProgress' (existing v2.4.0 path)
  ///   (b) jobs with at least one JobFile in inProgress state (existing)
  ///   (c) jobs with at least one JobFile in completed+verifyStatus=pending
  ///       (NEW v8 — abandoned shutdown mid-verify)
  ///
  /// Returns deduplicated job IDs. Caller iterates and calls
  /// recomputeCountersFromFiles per ID after stale-row mutations.
  Future<Set<int>> getRescuedJobIds() async {
    // Codex round-3 P2 #1 (now stale, see below): the third UNION arm
    // was originally restricted to SHA-256 jobs because size-mode
    // verify ran INLINE (TransferService.verifyTransfer) before the
    // file row was written, so a size-mode `completed+pending` state
    // could never exist mid-flight.
    //
    // Codex round-24 P2: 018 T024 restructured the size-mode branch to
    // mirror SHA-256: markFileCompleted(verified: false) is now
    // written BEFORE verifyTransfer, then markFileSizeOnlyVerified
    // finalizes after. A shutdown between those two writes leaves the
    // size-mode row at `status=completed && verifyStatus=pending` —
    // an abandoned-mid-verify state that's structurally identical to
    // the SHA-256 case and MUST be rescued the same way. The SHA-256
    // filter is dropped; the executor's recovery branch handles both
    // verify modes correctly (size-mode re-runs verifyTransfer;
    // SHA-256 re-runs the hash pair).
    final rows = await customSelect(
      '''
      SELECT DISTINCT id AS job_id FROM jobs WHERE status = 'inProgress'
      UNION
      SELECT DISTINCT job_id FROM job_files WHERE status = 'inProgress'
      UNION
      SELECT DISTINCT job_id FROM job_files
        WHERE status = 'completed'
          AND verify_status = 'pending'
      ''',
    ).get();
    return rows.map((r) => r.read<int>('job_id')).toSet();
  }

  /// Get a single job by ID. 018 T022: self-healed `unverifiedFiles`
  /// via the join, plus a fire-and-forget reconciliation that fixes
  /// the persisted `jobs.unverified_files` cache when the read
  /// detected drift. Reconciliation is gated to drift-only so a
  /// steady-state read never schedules a write — avoids write storms
  /// on the hot path.
  Future<Job?> getJob(int jobId) async {
    final row = await customSelect(
      '$_jobsWithSelfHealedUnverifiedSelect WHERE id = ?',
      variables: [Variable.withInt(jobId)],
      readsFrom: {jobs, jobFiles},
    ).getSingleOrNull();
    if (row == null) return null;
    final base = jobs.map(row.data);
    final actual = row.read<int>('actual_unverified');
    if (base.unverifiedFiles == actual) return base;
    unawaited(recomputeCountersFromFiles(jobId));
    return base.copyWith(unverifiedFiles: actual);
  }

  /// 017B (FR-B10): batched job lookup for the Diagnostics → Recent
  /// failures section. Returns the rows in DB order; the caller is
  /// expected to sort by `completedAt` for newest-first display.
  Future<List<Job>> getJobsByIds(List<int> jobIds) {
    if (jobIds.isEmpty) return Future.value(const <Job>[]);
    return (select(jobs)..where((t) => t.id.isIn(jobIds))).get();
  }

  /// 017B (Codex round-16 P1 #1): scoped requeue. Flips the Job row
  /// back to `queued` and resets aggregate counters so the queue
  /// scheduler can pick it up — but does NOT touch any JobFile rows.
  /// Used by `JobQueueService.retryFile` so a per-file retry doesn't
  /// sweep unrelated files in the same job (the heavyweight
  /// `resetJobForRetry` arms every verifyMismatch row for force-delete
  /// AND resets every failed/pending file, which is correct for a
  /// job-level "Retry all" action but catastrophic for "Retry verify
  /// on 1 unverified file"). Counters will re-derive from per-row
  /// state via the recovery path or the next run's accumulator.
  Future<void> requeueJobForFileRetry(int jobId) async {
    // Codex round-18 P2 #1: re-derive completedFiles/completedBytes
    // from per-row state in the same transaction. Without this, a
    // per-file retry from a completed job (`resetFileForRetry` flips
    // one file back to `pending`) would re-enter processing with
    // stale counters showing N/N complete when one file is now
    // pending again. recomputeCountersFromFiles also re-derives
    // unverified_files for free, so this single call subsumes the
    // round-17 _recomputeUnverifiedForFile semantics for the parent.
    await transaction(() async {
      await (update(jobs)..where((t) => t.id.equals(jobId))).write(
        const JobsCompanion(
          status: Value(JobStatus.queued),
          errorMessage: Value(null),
          completedAt: Value(null),
        ),
      );
      await recomputeCountersFromFiles(jobId);
    });
  }

  /// 018 T002 (FR-001 + FR-002, US1, P1): atomic per-file retry.
  ///
  /// Combines what `JobQueueService.retryFile` previously did via TWO
  /// separate `_safeWrite` calls (`resetFileForRetry` then
  /// `requeueJobForFileRetry`) into ONE Drift transaction. Either the
  /// entire retry intent is persisted, or none of it is.
  ///
  /// The pre-018 design was reachable with a "ghost pending" failure
  /// mode: crash between the file reset and the parent requeue would
  /// leave the file at `status=pending, verifyStatus=pending` while
  /// the parent stayed at `status=completed`. None of the recovery
  /// arms in `getRescuedJobIds` match this state, so the retry intent
  /// silently disappeared.
  ///
  /// Calls `db.jobFileDao.resetFileForRetry` inside the wrapping
  /// transaction (Drift transactions nest cleanly per project
  /// convention; preserves all of resetFileForRetry's load-bearing
  /// semantics — startedAt preservation, verify axis clear,
  /// _recomputeUnverifiedForFile call — without duplicating them
  /// here). Then runs the parent requeue + counter recompute that
  /// `requeueJobForFileRetry` does, also inside the same transaction.
  ///
  /// [testOnlyMidTransactionHook] is a failure-injection seam used
  /// exclusively by `test/unit/retry_atomicity_test.dart` to assert
  /// atomicity. It fires AFTER the file reset and BEFORE the parent
  /// update. Production callers MUST leave it null.
  Future<void> applyPerFileRetry({
    required int jobId,
    required int fileId,
    required bool forceDestDelete,
    @visibleForTesting
    Future<void> Function()? testOnlyMidTransactionHook,
  }) async {
    await transaction(() async {
      await db.jobFileDao.resetFileForRetry(
        fileId,
        forceDestDeleteApproved: forceDestDelete,
      );
      if (testOnlyMidTransactionHook != null) {
        await testOnlyMidTransactionHook();
      }
      await (update(jobs)..where((t) => t.id.equals(jobId))).write(
        const JobsCompanion(
          status: Value(JobStatus.queued),
          errorMessage: Value(null),
          completedAt: Value(null),
        ),
      );
      await recomputeCountersFromFiles(jobId);
    });
  }

  /// 017B (Codex round-14 P2 #2): does any compression job already
  /// link back to [parentJobId] via Job.parentJobId? Used to suppress
  /// duplicate auto-chain attempts after the operator resolves
  /// mismatch/unverified warnings on a transferAndCompress parent.
  Future<bool> hasChainedChild(int parentJobId) async {
    final row = await (select(jobs)
          ..where((t) => t.parentJobId.equals(parentJobId))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Get completed and failed jobs as a one-time list (for CSV export).
  Future<List<Job>> getCompletedJobsList() {
    return (select(jobs)
          ..where(
            (t) =>
                t.status.equalsValue(JobStatus.completed) |
                t.status.equalsValue(JobStatus.failed),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.completedAt)]))
        .get();
  }

  /// Watch completed and failed jobs (history). 018 T022: self-healed
  /// `unverifiedFiles` via the join in
  /// [_jobsWithSelfHealedUnverifiedSelect].
  Stream<List<Job>> watchCompletedJobs() {
    return customSelect(
      "$_jobsWithSelfHealedUnverifiedSelect "
      "WHERE status IN ('completed', 'failed') "
      "ORDER BY completed_at DESC",
      readsFrom: {jobs, jobFiles},
    ).watch().map(
        (rows) => rows.map(_mapWithSelfHealedUnverified).toList());
  }

  /// Reset a failed job for retry — set status to queued, clear error.
  /// Also resets failed files to pending.
  ///
  /// 015 invariants preserved across retry:
  ///   - `JobFile.wasOverwriteApproved` is NOT cleared. The operator
  ///     approved overwrite for the same set of conflicts at the
  ///     original conflict-preflight; a retry doesn't re-prompt.
  ///   - `JobFile.startedAt` is NOT cleared. The executor uses it to
  ///     distinguish our own /Z partial fragments from TOCTOU
  ///     intrusions; clearing on retry would re-arm partials as
  ///     unknown intrusions and refuse to delete them.
  ///   - `Job.createdAt` is NOT modified. Used as the mtime cutoff
  ///     for the same-size dest guard at executor time.
  /// Filter is `failed | pending` — completed files are deliberately
  /// preserved (operator's verified work is not thrown away on retry).
  Future<void> resetJobForRetry(int jobId) async {
    await transaction(() async {
      await (update(jobs)..where((t) => t.id.equals(jobId))).write(
        const JobsCompanion(
          status: Value(JobStatus.queued),
          errorMessage: Value(null),
          completedAt: Value(null),
          completedFiles: Value(0),
          completedBytes: Value(0),
        ),
      );
      // 017 (Codex round-3 P2 #2): files that previously failed with
      // failureKind='verifyMismatch' (either v8 forward-operation or
      // v7→v8 migrated) get forceDestDeleteApproved=true on this
      // retry pass. Without it, the same-size corrupt destination
      // would be skipped by the size-match short-circuit and re-
      // verify the same bad bytes — infinite loop. Set BEFORE the
      // axis-clear below so the column update lands on the same row.
      await (update(db.jobFiles)
            ..where(
              (t) =>
                  t.jobId.equals(jobId) &
                  t.failureKind.equalsValue(FailureKind.verifyMismatch),
            ))
          .write(
        const JobFilesCompanion(
          forceDestDeleteApproved: Value(true),
        ),
      );
      // Reset failed files AND completed-but-mismatched rows to
      // pending. Codex round-4 P2 #2: completed+verifyMismatch rows
      // are the FR-004 "bytes on disk, hash differs" state; without
      // including them in the reset, a job-level Retry would leave
      // those rows at status=completed, _processTransfer would skip
      // them before consuming forceDestDeleteApproved, and the
      // corrupt destinations would never be replaced.
      //
      // Verify axis cleared so re-run produces fresh hashes;
      // failureKind reset to none so a subsequent retry without a
      // fresh mismatch doesn't keep arming forceDestDeleteApproved.
      await (update(db.jobFiles)
            ..where(
              (t) =>
                  t.jobId.equals(jobId) &
                  (t.status.equalsValue(FileStatus.failed) |
                      t.status.equalsValue(FileStatus.pending) |
                      t.failureKind
                          .equalsValue(FailureKind.verifyMismatch)),
            ))
          .write(
        const JobFilesCompanion(
          status: Value(FileStatus.pending),
          errorMessage: Value(null),
          completedAt: Value(null),
          verifyStatus: Value(VerifyStatus.pending),
          failureKind: Value(FailureKind.none),
          sourceHash: Value(null),
          destinationHash: Value(null),
        ),
      );
    });
  }

  /// Delete a job and its associated files.
  Future<void> deleteJob(int jobId) async {
    await transaction(() async {
      await (delete(db.jobFiles)..where((t) => t.jobId.equals(jobId))).go();
      await (delete(jobs)..where((t) => t.id.equals(jobId))).go();
    });
  }
}
