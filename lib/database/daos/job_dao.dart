import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'job_dao.g.dart';

@DriftAccessor(tables: [Jobs, JobFiles])
class JobDao extends DatabaseAccessor<AppDatabase> with _$JobDaoMixin {
  JobDao(super.db);

  /// Watch all jobs ordered by sort order (queue order).
  Stream<List<Job>> watchAllJobs() {
    return (select(jobs)
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .watch();
  }

  /// Reorder jobs by swapping sortOrder values between two jobs identified by ID.
  Future<void> reorderJobs(int movedJobId, int targetJobId) async {
    if (movedJobId == targetJobId) return;

    final movedJob = await getJob(movedJobId);
    final targetJob = await getJob(targetJobId);
    if (movedJob == null || targetJob == null) return;

    await transaction(() async {
      await (update(jobs)..where((t) => t.id.equals(movedJobId)))
          .write(JobsCompanion(sortOrder: Value(targetJob.sortOrder)));
      await (update(jobs)..where((t) => t.id.equals(targetJobId)))
          .write(JobsCompanion(sortOrder: Value(movedJob.sortOrder)));
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
  Future<Job?> getNextQueuedJob() {
    return (select(jobs)
          ..where(
            (t) =>
                t.status.equalsValue(JobStatus.queued) |
                t.status.equalsValue(JobStatus.paused),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
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
          startedAt: Value(null),
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
