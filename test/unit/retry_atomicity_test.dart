import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/daos/job_file_dao.dart';
import 'package:video_pipeline/database/tables.dart';

// 018 T004 (FR-001 + FR-002, US1, P1, SC-001): per-file retry atomicity.
//
// `JobDao.applyPerFileRetry` is the new single transactional gate
// that replaces the prior two-`_safeWrite` sequence inside
// `JobQueueService.retryFile`. The test matrix verifies:
//
//   1. Retry on a verifyStatus=mismatch row leaves file at
//      pending+pending+forceDestDeleteApproved=true AND parent at
//      queued with counters re-derived from per-row state.
//
//   2. Retry on a verifyStatus=unverified row decrements the
//      Job.unverifiedFiles counter (via the in-transaction
//      recomputeCountersFromFiles call).
//
//   3. ATOMICITY INJECTION — using the @visibleForTesting
//      testOnlyMidTransactionHook, throw a synthetic exception
//      AFTER the file reset and BEFORE the parent update. Assert
//      that NO state change is persisted (file row, parent job,
//      and all counter columns are observably unchanged from
//      pre-call values). This is the core SC-001 evidence.
//
//   4. forceDestDelete=false clears any prior forceDestDeleteApproved
//      (matches existing resetFileForRetry semantics — prevents stale
//      destructive intent from being silently consumed by a later
//      non-force retry).

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

  // Seed a completed-with-mismatch fixture: one job with one file at
  // status=completed, verifyStatus=mismatch, failureKind=verifyMismatch.
  // This is the post-SHA-256-mismatch shape the operator sees in
  // history when they consider clicking Retry.
  Future<({int jobId, int fileId, DateTime startedAt})>
      seedMismatchedFile() async {
    final createdAt = DateTime.now().subtract(const Duration(minutes: 5));
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.completed,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        createdAt: createdAt,
        verificationMode: const Value(VerificationMode.sha256),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_001.MP4',
          destinationFilePath: r'E:\dest\IMG_001.MP4',
          fileName: 'IMG_001.MP4',
          fileSize: 1_000_000_000,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1_000_000_000,
    );
    final files = await jobFileDao.getFilesForJob(jobId);
    final fileId = files.single.id;

    // Walk the row to the post-SHA-256-mismatch state.
    await jobFileDao.markFileStarted(fileId); // sets startedAt
    await jobFileDao.markFileCompleted(fileId, verified: false);
    await jobFileDao.markFileVerifyMismatch(
      fileId,
      sourceHash: 'a' * 64,
      destHash: 'b' * 64,
    );
    // Mark the parent completed (mirrors the v8 behavior for a job
    // whose only "failure" is a verify-axis warning).
    await jobDao.markJobCompleted(jobId);

    final hydratedFile = (await jobFileDao.getFile(fileId))!;
    return (
      jobId: jobId,
      fileId: fileId,
      startedAt: hydratedFile.startedAt!,
    );
  }

  // Same as above but the row ends at verifyStatus=unverified
  // (subsystem failure rather than cryptographic mismatch). Increments
  // Job.unverifiedFiles to give the counter-decrement assertion in
  // case 2 something to observe.
  Future<({int jobId, int fileId})> seedUnverifiedFile() async {
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.completed,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.sha256),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_002.MP4',
          destinationFilePath: r'E:\dest\IMG_002.MP4',
          fileName: 'IMG_002.MP4',
          fileSize: 500_000_000,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 500_000_000,
    );
    final fileId = (await jobFileDao.getFilesForJob(jobId)).single.id;
    await jobFileDao.markFileStarted(fileId);
    await jobFileDao.markFileCompleted(fileId, verified: false);
    await jobFileDao.markFileUnverified(fileId);
    await jobDao.incrementUnverified(jobId);
    await jobDao.markJobCompleted(jobId);
    return (jobId: jobId, fileId: fileId);
  }

  test(
      'case 1: retry on verifyStatus=mismatch leaves file at '
      'pending+pending+forceDestDeleteApproved=true and parent at queued',
      () async {
    final seeded = await seedMismatchedFile();

    await jobDao.applyPerFileRetry(
      jobId: seeded.jobId,
      fileId: seeded.fileId,
      forceDestDelete: true,
    );

    final file = (await jobFileDao.getFile(seeded.fileId))!;
    expect(file.status, FileStatus.pending);
    expect(file.verifyStatus, VerifyStatus.pending);
    expect(file.failureKind, FailureKind.none);
    expect(file.forceDestDeleteApproved, isTrue,
        reason: 'forceDestDelete=true persists to the column for executor '
            'consumption (Codex round-2 P2 #2 single-use semantics).');
    expect(file.sourceHash, isNull);
    expect(file.destinationHash, isNull);
    expect(file.errorMessage, isNull);
    expect(file.completedAt, isNull);
    expect(file.startedAt, seeded.startedAt,
        reason: '015 invariant: startedAt preserved across resets.');

    final job = (await jobDao.getJob(seeded.jobId))!;
    expect(job.status, JobStatus.queued);
    expect(job.errorMessage, isNull);
    expect(job.completedAt, isNull);
    // recomputeCountersFromFiles ran inside the transaction. With one
    // file now at status=pending, completed_files=0 and
    // completed_bytes=0.
    expect(job.completedFiles, 0);
    expect(job.completedBytes, 0);
  });

  test(
      'case 2: retry on verifyStatus=unverified decrements '
      'Job.unverifiedFiles', () async {
    final seeded = await seedUnverifiedFile();

    final beforeJob = (await jobDao.getJob(seeded.jobId))!;
    expect(beforeJob.unverifiedFiles, 1,
        reason: 'Seeded with one unverified file via incrementUnverified.');

    await jobDao.applyPerFileRetry(
      jobId: seeded.jobId,
      fileId: seeded.fileId,
      forceDestDelete: false,
    );

    final afterJob = (await jobDao.getJob(seeded.jobId))!;
    expect(afterJob.unverifiedFiles, 0,
        reason: 'recomputeCountersFromFiles re-derives unverified_files '
            'from per-row state. After retry the row is pending so the '
            'count drops to 0.');
  });

  test(
      'case 3: ATOMICITY — synthetic in-transaction exception leaves '
      'every persisted column unchanged (SC-001)', () async {
    final seeded = await seedMismatchedFile();

    final beforeFile = (await jobFileDao.getFile(seeded.fileId))!;
    final beforeJob = (await jobDao.getJob(seeded.jobId))!;

    await expectLater(
      jobDao.applyPerFileRetry(
        jobId: seeded.jobId,
        fileId: seeded.fileId,
        forceDestDelete: true,
        testOnlyMidTransactionHook: () async {
          throw StateError(
              '018 T004 case 3 synthetic interruption — fires AFTER the '
              'file reset and BEFORE the parent update');
        },
      ),
      throwsA(isA<StateError>()),
    );

    // Drift's transaction primitive must roll back ALL writes made
    // before the throw. Verify per-column on both rows.
    final afterFile = (await jobFileDao.getFile(seeded.fileId))!;
    expect(afterFile.status, beforeFile.status,
        reason: 'Atomicity: file row status must be unchanged.');
    expect(afterFile.verifyStatus, beforeFile.verifyStatus);
    expect(afterFile.failureKind, beforeFile.failureKind);
    expect(afterFile.forceDestDeleteApproved,
        beforeFile.forceDestDeleteApproved);
    expect(afterFile.sourceHash, beforeFile.sourceHash);
    expect(afterFile.destinationHash, beforeFile.destinationHash);
    expect(afterFile.errorMessage, beforeFile.errorMessage);
    expect(afterFile.completedAt, beforeFile.completedAt);
    expect(afterFile.startedAt, beforeFile.startedAt);

    final afterJob = (await jobDao.getJob(seeded.jobId))!;
    expect(afterJob.status, beforeJob.status,
        reason: 'Atomicity: parent job status must be unchanged.');
    expect(afterJob.errorMessage, beforeJob.errorMessage);
    expect(afterJob.completedAt, beforeJob.completedAt);
    expect(afterJob.completedFiles, beforeJob.completedFiles);
    expect(afterJob.completedBytes, beforeJob.completedBytes);
    expect(afterJob.unverifiedFiles, beforeJob.unverifiedFiles);
  });

  test(
      'case 4: forceDestDelete=false clears any prior approval '
      '(matches resetFileForRetry semantics)', () async {
    final seeded = await seedMismatchedFile();

    // First retry with force=true to set the column.
    await jobDao.applyPerFileRetry(
      jobId: seeded.jobId,
      fileId: seeded.fileId,
      forceDestDelete: true,
    );
    expect(
        (await jobFileDao.getFile(seeded.fileId))!.forceDestDeleteApproved,
        isTrue);

    // Walk the row back to a retriable state for the second retry.
    await jobFileDao.markFileStarted(seeded.fileId);
    await jobFileDao.markFileCompleted(seeded.fileId, verified: false);
    await jobFileDao.markFileVerifyMismatch(
      seeded.fileId,
      sourceHash: 'c' * 64,
      destHash: 'd' * 64,
    );

    // Second retry with force=false — must clear the prior approval.
    await jobDao.applyPerFileRetry(
      jobId: seeded.jobId,
      fileId: seeded.fileId,
      forceDestDelete: false,
    );
    expect(
        (await jobFileDao.getFile(seeded.fileId))!.forceDestDeleteApproved,
        isFalse,
        reason: 'forceDestDelete=false MUST clear any prior approval. '
            'Codex round-23 P2: stale destructive intent surviving across '
            'non-force retries would let a later operator-unintended call '
            'consume an old approval.');
  });
}
