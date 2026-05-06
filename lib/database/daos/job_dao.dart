import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'job_dao.g.dart';

@DriftAccessor(tables: [Jobs, JobFiles])
class JobDao extends DatabaseAccessor<AppDatabase> with _$JobDaoMixin {
  JobDao(super.db);

  /// Watch all jobs ordered by creation time (queue order).
  Stream<List<Job>> watchAllJobs() {
    return (select(jobs)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Watch jobs filtered by status.
  Stream<List<Job>> watchJobsByStatus(JobStatus status) {
    return (select(jobs)..where((t) => t.status.equalsValue(status))).watch();
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

  /// Delete a job and its associated files.
  Future<void> deleteJob(int jobId) async {
    await transaction(() async {
      await (delete(db.jobFiles)..where((t) => t.jobId.equals(jobId))).go();
      await (delete(jobs)..where((t) => t.id.equals(jobId))).go();
    });
  }
}
