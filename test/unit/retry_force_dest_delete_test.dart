import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/daos/job_file_dao.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/services/compression_service.dart';
import 'package:video_pipeline/services/drive_service.dart';
import 'package:video_pipeline/services/job_queue_service.dart';
import 'package:video_pipeline/services/slack_service.dart';
import 'package:video_pipeline/services/transfer_service.dart';

// 017 (T045a, FR-005, SC-004, Codex H2): contract test for the
// operator-driven retry path that closes the "same-size corrupt
// destination" loop.
//
// The full Windows-only delete-before-robocopy invocation is exercised
// in T067 acceptance. This unit test pins the cross-platform contract:
// after `retryFile(forceDestDelete: true)`,
//   1. The file row's verify axis is cleared (status=pending,
//      verifyStatus=pending, failureKind=none, hashes null).
//   2. The job row is reset to a re-runnable state.
//   3. The in-memory `_forceDestDeleteFileIds` set carries the fileId,
//      so the next pass of `_processTransfer` will bypass both the
//      feature-015 delete predicate AND the size-match short-circuit.
//
// Without (3), the loop would observe `wasOverwriteApproved=false` +
// `destSize == sourceSize` and skip robocopy entirely, re-verifying
// the same corrupt bytes forever.

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;
  late JobQueueService queue;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);

    queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: SlackService(settingsDao: db.settingsDao),
      transferService: TransferService(),
      compressionService: CompressionService(),
      driveService: DriveService(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<({int jobId, int fileId})> _seedMismatchedFile() async {
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.failed,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.sha256),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_001.MP4',
          destinationFilePath: r'E:\dest\IMG_001.MP4',
          fileName: 'IMG_001.MP4',
          fileSize: 3,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 3,
    );

    final files = await jobFileDao.getFilesForJob(jobId);
    final fileId = files.single.id;

    // Simulate the post-mismatch state: copy succeeded (bytes are on
    // disk and credited), but SHA-256 caught corruption.
    await jobFileDao.markFileCompleted(fileId, verified: false);
    await jobFileDao.markFileVerifyMismatch(
      fileId,
      sourceHash: 'a' * 64,
      destHash: 'b' * 64,
    );

    return (jobId: jobId, fileId: fileId);
  }

  test(
      'retryFile(forceDestDelete: true) clears verify axis and arms the '
      'delete-bypass set', () async {
    final seeded = await _seedMismatchedFile();

    // Pre-state sanity: the seeded file is exactly the H2 trap shape —
    // wasOverwriteApproved=false, status=completed, verifyStatus=mismatch.
    final before = await jobFileDao.getFile(seeded.fileId);
    expect(before!.wasOverwriteApproved, isFalse);
    expect(before.status, FileStatus.completed);
    expect(before.verifyStatus, VerifyStatus.mismatch);
    expect(before.failureKind, FailureKind.verifyMismatch);
    expect(queue.isForceDestDeletePending(seeded.fileId), isFalse);

    await queue.retryFile(seeded.fileId, forceDestDelete: true);

    final after = await jobFileDao.getFile(seeded.fileId);
    expect(after!.status, FileStatus.pending,
        reason: 'File row must re-enter the pending pool.');
    expect(after.verifyStatus, VerifyStatus.pending,
        reason: 'Verify axis cleared so a fresh hash check can run.');
    expect(after.failureKind, FailureKind.none);
    expect(after.sourceHash, isNull);
    expect(after.destinationHash, isNull);
    expect(after.errorMessage, isNull);
    expect(after.completedAt, isNull);
    expect(after.startedAt, before.startedAt,
        reason: 'startedAt is the load-bearing 015 "everAttempted" '
            'signal — must be preserved across resets.');

    expect(queue.isForceDestDeletePending(seeded.fileId), isTrue,
        reason: 'In-memory set must carry the fileId so the next pass '
            'of _processTransfer bypasses both the feature-015 delete '
            'predicate AND the size-match short-circuit (Codex H2).');

    final job = await jobDao.getJob(seeded.jobId);
    expect(job!.status, JobStatus.queued,
        reason: 'Job is reset for retry by resetJobForRetry.');
  });

  test(
      'retryFile(forceDestDelete: false) does NOT arm the delete-bypass set',
      () async {
    final seeded = await _seedMismatchedFile();

    await queue.retryFile(seeded.fileId, forceDestDelete: false);

    expect(queue.isForceDestDeletePending(seeded.fileId), isFalse,
        reason: 'Without explicit operator approval, the same-size '
            'short-circuit must remain active so we do not silently '
            'replace destinations on every retry.');

    final after = await jobFileDao.getFile(seeded.fileId);
    expect(after!.status, FileStatus.pending,
        reason: 'Verify axis is still cleared regardless of the flag — '
            'the flag only governs the delete-then-robocopy bypass.');
    expect(after.verifyStatus, VerifyStatus.pending);
  });

  test('retryFile is a no-op when the fileId does not exist', () async {
    await queue.retryFile(999999, forceDestDelete: true);
    expect(queue.isForceDestDeletePending(999999), isFalse,
        reason: 'Missing file must not arm the bypass set — guards '
            'against a stale UI ID after the row was deleted.');
  });
}
