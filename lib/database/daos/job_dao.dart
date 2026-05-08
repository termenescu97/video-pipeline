import 'package:drift/drift.dart';

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

  /// Watch all jobs ordered by sort order (queue order).
  Stream<List<Job>> watchAllJobs() {
    return (select(jobs)
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .watch();
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

  /// Watch a single job by ID (efficient).
  Stream<Job?> watchJob(int jobId) {
    return (select(jobs)..where((t) => t.id.equals(jobId)))
        .watchSingleOrNull();
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
  /// Per the spec, recovery moves to [JobStatus.paused] (not [JobStatus.queued])
  /// so the operator must explicitly resume after reviewing.
  Future<void> recoverStaleJobs() async {
    // Capture the rows BEFORE the update so we know which jobs we
    // touched (and so the log entry has source/dest paths). Reading
    // after the update would lose the set (those rows are now
    // `paused`, indistinguishable from operator-paused jobs).
    final rescuedJobs = await (select(jobs)
          ..where((t) => t.status.equalsValue(JobStatus.inProgress)))
        .get();

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
      );
      for (final job in rescuedJobs) {
        logService?.warning(
          '  Recovered job #${job.id}: '
          '${job.sourcePath} → ${job.destinationPath}',
        );
      }
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

  /// Get a single job by ID.
  Future<Job?> getJob(int jobId) {
    return (select(jobs)..where((t) => t.id.equals(jobId))).getSingleOrNull();
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

  /// Watch completed and failed jobs (history).
  Stream<List<Job>> watchCompletedJobs() {
    return (select(jobs)
          ..where(
            (t) =>
                t.status.equalsValue(JobStatus.completed) |
                t.status.equalsValue(JobStatus.failed),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.completedAt)]))
        .watch();
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
      // Reset failed files to pending.
      await (update(db.jobFiles)
            ..where(
              (t) =>
                  t.jobId.equals(jobId) &
                  (t.status.equalsValue(FileStatus.failed) |
                      t.status.equalsValue(FileStatus.pending)),
            ))
          .write(
        const JobFilesCompanion(
          status: Value(FileStatus.pending),
          errorMessage: Value(null),
          completedAt: Value(null),
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
