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

  /// Mark file as completed and verified.
  Future<void> markFileCompleted(int fileId, {required bool verified}) {
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      JobFilesCompanion(
        status: const Value(FileStatus.completed),
        verified: Value(verified),
        completedAt: Value(DateTime.now()),
      ),
    );
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
    return (update(jobFiles)..where((t) => t.id.equals(fileId))).write(
      const JobFilesCompanion(
        status: Value(FileStatus.pending),
        startedAt: Value(null),
        completedAt: Value(null),
        errorMessage: Value(null),
      ),
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
