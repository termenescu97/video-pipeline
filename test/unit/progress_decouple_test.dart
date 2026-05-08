import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/daos/job_file_dao.dart';
import 'package:video_pipeline/database/tables.dart';

// 017 (T037, FR-002, US1): regression test for the operator's 2026-05-08
// failure where every SHA-256 hash subprocess died and progress counters
// stuck at 0/27 even though robocopy successfully copied 3 files.
//
// This is a DAO-level test that exercises the post-rewrite state machine
// directly: markFileCompleted(verified: false) advances the copy-side
// state independent of any verify-side mark methods. The full executor
// path is exercised end-to-end in T067 (Windows acceptance).

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    // Insert default settings row so AppSettings reads work (createMode does this in production).
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> _seedJob({VerificationMode mode = VerificationMode.sha256}) async {
    return jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.inProgress,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        createdAt: DateTime.now(),
        verificationMode: Value(mode),
      ),
      buildFiles: (jobId) => List.generate(
        3,
        (i) => JobFilesCompanion.insert(
          jobId: jobId,
          sourceFilePath: r'H:\DCIM\IMG_${i}.MP4',
          destinationFilePath: r'E:\dest\IMG_${i}.MP4',
          fileName: 'IMG_$i.MP4',
          fileSize: 1_000_000_000, // 1 GB each
          status: FileStatus.pending,
        ),
      ),
      totalBytes: 3_000_000_000,
    );
  }

  test('FR-002: markFileCompleted(verified: false) credits bytes immediately',
      () async {
    final jobId = await _seedJob();
    final files = await jobFileDao.getFilesForJob(jobId);

    // Simulate the post-robocopy state for the first file.
    await jobFileDao.markFileCompleted(files[0].id, verified: false);

    final updated = await jobFileDao.getFilesForJob(jobId);
    expect(updated[0].status, FileStatus.completed,
        reason:
            'After markFileCompleted, status is "completed" — bytes are on disk.');
    expect(updated[0].verified, isFalse,
        reason: 'Legacy verified boolean stays false until markFileVerified.');
    expect(updated[0].verifyStatus, VerifyStatus.pending,
        reason:
            'verifyStatus stays pending until verify-side mark methods fire.');
  });

  test(
      'FR-003: hash subsystem failure (markFileUnverified) does NOT undo copy progress',
      () async {
    final jobId = await _seedJob();
    final files = await jobFileDao.getFilesForJob(jobId);

    // Simulate: robocopy succeeded, hash subprocess died for every file.
    for (final f in files) {
      await jobFileDao.markFileCompleted(f.id, verified: false);
      await jobFileDao.markFileUnverified(f.id);
      await jobDao.incrementUnverified(jobId);
    }

    final result = await jobFileDao.getFilesForJob(jobId);
    for (final f in result) {
      expect(f.status, FileStatus.completed,
          reason:
              'Copy succeeded — status remains completed even when verify fails.');
      expect(f.verifyStatus, VerifyStatus.unverified);
      expect(f.failureKind, FailureKind.verifyUnreliable);
    }

    final job = await jobDao.getJob(jobId);
    expect(job!.unverifiedFiles, 3,
        reason:
            'Job-level unverified counter increments per failed verify subsystem call.');
  });

  test(
      'FR-005: markFileVerifyMismatch keeps status=completed (FR-004 — copy succeeded)',
      () async {
    final jobId = await _seedJob();
    final files = await jobFileDao.getFilesForJob(jobId);

    await jobFileDao.markFileCompleted(files[0].id, verified: false);
    await jobFileDao.markFileVerifyMismatch(
      files[0].id,
      sourceHash: 'a' * 64,
      destHash: 'b' * 64,
    );

    final updated = await jobFileDao.getFilesForJob(jobId);
    expect(updated[0].status, FileStatus.completed,
        reason: 'FR-004: bytes ARE on disk; status must NOT change to failed.');
    expect(updated[0].verifyStatus, VerifyStatus.mismatch);
    expect(updated[0].failureKind, FailureKind.verifyMismatch,
        reason:
            'Routes Retry to forceDestDelete=true via failureKind=verifyMismatch (Codex H2).');
    expect(updated[0].sourceHash, 'a' * 64);
    expect(updated[0].destinationHash, 'b' * 64);
  });

  test('FR-003 verified: markFileVerified sets full success state', () async {
    final jobId = await _seedJob();
    final files = await jobFileDao.getFilesForJob(jobId);

    await jobFileDao.markFileCompleted(files[0].id, verified: false);
    await jobFileDao.markFileVerified(
      files[0].id,
      sourceHash: 'c' * 64,
      destHash: 'c' * 64,
    );

    final updated = await jobFileDao.getFilesForJob(jobId);
    expect(updated[0].status, FileStatus.completed);
    expect(updated[0].verified, isTrue,
        reason: 'Legacy boolean flips to true only on cryptographic match.');
    expect(updated[0].verifyStatus, VerifyStatus.verified);
    expect(updated[0].failureKind, FailureKind.none);
  });

  test('FR-018: recomputeCountersFromFiles re-derives correctly', () async {
    final jobId = await _seedJob();
    final files = await jobFileDao.getFilesForJob(jobId);

    // 1 verified, 1 unverified, 1 still pending.
    await jobFileDao.markFileCompleted(files[0].id, verified: false);
    await jobFileDao.markFileVerified(files[0].id,
        sourceHash: 'a' * 64, destHash: 'a' * 64);
    await jobFileDao.markFileCompleted(files[1].id, verified: false);
    await jobFileDao.markFileUnverified(files[1].id);
    // files[2] left pending.

    // Simulate counter drift from a partial-write shutdown.
    await jobDao.updateJobProgress(jobId, completedFiles: 0, completedBytes: 0);

    // Re-derive (FR-018 recovery semantic).
    await jobDao.recomputeCountersFromFiles(jobId);

    final job = await jobDao.getJob(jobId);
    expect(job!.completedFiles, 2,
        reason: '2 files at status=completed (verified + unverified).');
    expect(job.completedBytes, 2_000_000_000,
        reason: 'Bytes summed from per-row fileSize.');
    expect(job.unverifiedFiles, 1);
  });

  test('FR-018: getRescuedJobIds includes copied+pending verify rows',
      () async {
    final jobId = await _seedJob();
    final files = await jobFileDao.getFilesForJob(jobId);

    // Simulate abandoned shutdown mid-verify: file copied, verifyStatus stayed pending.
    await jobFileDao.markFileCompleted(files[0].id, verified: false);

    final rescued = await jobDao.getRescuedJobIds();
    expect(rescued, contains(jobId),
        reason: 'Job with copied+pending verify must appear in rescued set.');
  });
}
