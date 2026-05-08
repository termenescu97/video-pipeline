import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/daos/job_file_dao.dart';
import 'package:video_pipeline/database/tables.dart';

// 017 (T049, FR-006/FR-007/FR-018): integration test for the
// recoverStaleJobs path that picks up where an abandoned shutdown
// left off.
//
// Scenario seeded into the in-memory DB:
//   * 1 job in `status=inProgress` (the parent that was running when
//     shutdown was abandoned).
//   * Inside that job:
//     - File A: `status=inProgress` (was mid-robocopy).
//     - File B: `status=completed`, `verifyStatus=pending` (robocopy
//       finished, hash check never ran — the v8 stale state).
//     - File C: `status=completed`, `verifyStatus=verified` (fully
//       finished pre-shutdown).
//
// Expected post-recoverStaleJobs state:
//   * Job moves to `paused` (operator must explicitly resume).
//   * File A reset to `pending`; `startedAt` preserved (load-bearing
//     015 invariant).
//   * File B stays `status=completed` + `verifyStatus=pending` so
//     `_processTransfer`'s recovery branch can re-enter verify-only
//     without re-copying.
//   * File C unchanged.
//   * Job-level aggregate counters re-derived from per-row state — no
//     double-credit, no drift from a partial-write shutdown.

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);
  });

  tearDown(() async {
    await db.close();
  });

  test(
      'FR-006/FR-007/FR-018: rescues abandoned-shutdown state without '
      'double-crediting bytes', () async {
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.inProgress,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.sha256),
      ),
      buildFiles: (jId) => List.generate(
        3,
        (i) => JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_${i}.MP4',
          destinationFilePath: r'E:\dest\IMG_${i}.MP4',
          fileName: 'IMG_$i.MP4',
          fileSize: 1_000_000_000,
          status: FileStatus.pending,
        ),
      ),
      totalBytes: 3_000_000_000,
    );

    final files = await jobFileDao.getFilesForJob(jobId);
    final fileA = files[0];
    final fileB = files[1];
    final fileC = files[2];

    // File A: was mid-robocopy when shutdown fired.
    await jobFileDao.markFileStarted(fileA.id);

    // File B: copy succeeded, hash never ran — the v8 stale state that
    // FR-006 was added to handle.
    await jobFileDao.markFileStarted(fileB.id);
    await jobFileDao.markFileCompleted(fileB.id, verified: false);

    // File C: fully finished pre-shutdown.
    await jobFileDao.markFileStarted(fileC.id);
    await jobFileDao.markFileCompleted(fileC.id, verified: false);
    await jobFileDao.markFileVerified(
      fileC.id,
      sourceHash: 'c' * 64,
      destHash: 'c' * 64,
    );

    // Simulate the partial-write shutdown drifting Job-level counters
    // (e.g., `incrementVerified` for File C wrote, but the verify pass
    // for File B never reached its DAO write).
    await jobDao.updateJobProgress(jobId, completedFiles: 0, completedBytes: 0);

    final fileAStartedAt = (await jobFileDao.getFile(fileA.id))!.startedAt;
    expect(fileAStartedAt, isNotNull,
        reason: 'startedAt is set by markFileStarted; the rescue must '
            'preserve it.');

    await jobDao.recoverStaleJobs();

    // 1. Job moves to paused.
    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.paused,
        reason: 'Recovery routes the job to paused for explicit resume.');

    // 2. File A reset to pending; startedAt preserved.
    final aAfter = await jobFileDao.getFile(fileA.id);
    expect(aAfter!.status, FileStatus.pending);
    expect(aAfter.startedAt, fileAStartedAt,
        reason: '015 load-bearing: recovery must NOT clear startedAt — '
            'the executor uses it to distinguish own /Z partials from '
            'TOCTOU intrusions.');

    // 3. File B stays completed+pending so _processTransfer recovery
    //    branch re-enters verify-only.
    final bAfter = await jobFileDao.getFile(fileB.id);
    expect(bAfter!.status, FileStatus.completed,
        reason: 'Bytes are on disk — must not re-copy.');
    expect(bAfter.verifyStatus, VerifyStatus.pending,
        reason: 'verify never ran — stays pending so recovery branch '
            'in _processTransfer picks it up.');

    // 4. File C unchanged.
    final cAfter = await jobFileDao.getFile(fileC.id);
    expect(cAfter!.status, FileStatus.completed);
    expect(cAfter.verifyStatus, VerifyStatus.verified);

    // 5. Job-level counters re-derived (FR-018) — no double-credit.
    expect(job.completedFiles, 2,
        reason: 'Files B and C are at status=completed; A is pending.');
    expect(job.completedBytes, 2_000_000_000,
        reason: 'Bytes summed from per-row fileSize for completed rows.');
    expect(job.unverifiedFiles, 0,
        reason: 'No file reached verifyStatus=unverified — File B is '
            'pending (will run on recovery), File C verified.');

    // Verify-state per-row tally (the verified count is derived on read,
    // not stored on the Job row).
    final allFiles = await jobFileDao.getFilesForJob(jobId);
    final verifiedCount =
        allFiles.where((f) => f.verifyStatus == VerifyStatus.verified).length;
    expect(verifiedCount, 1, reason: 'Only File C is verified.');
  });

  test(
      'recoverStaleJobs is a no-op when nothing was abandoned', () async {
    // Fully-finished job: no inProgress rows, no completed+pending rows.
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.completed,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        createdAt: DateTime.now(),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_0.MP4',
          destinationFilePath: r'E:\dest\IMG_0.MP4',
          fileName: 'IMG_0.MP4',
          fileSize: 100,
          status: FileStatus.completed,
        ),
      ],
      totalBytes: 100,
    );

    await jobDao.recoverStaleJobs();

    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.completed,
        reason: 'A clean completed job must not be touched by recovery.');
  });
}
