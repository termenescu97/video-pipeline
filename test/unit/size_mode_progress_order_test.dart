import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/daos/job_file_dao.dart';
import 'package:video_pipeline/database/daos/settings_dao.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/services/compression_service.dart';
import 'package:video_pipeline/services/drive_service.dart';
import 'package:video_pipeline/services/job_queue_service.dart';
import 'package:video_pipeline/services/slack_service.dart';
import 'package:video_pipeline/services/transfer_service.dart';

// 018 T025 (FR-015, US5, P3, SC-009): size-mode progress decoupling.
//
// T024 restructured the size-mode branch in `_processTransfer` to mirror
// the SHA-256 sequence exactly:
//   robocopy → markFileCompleted(verified: false) →
//   credit completedCount/completedBytes → updateJobProgress →
//   verifyTransfer → markFileSizeOnlyVerified (or rollback on failure).
//
// Without this restructure the operator's progress bar froze during
// the verify-blocking I/O step on a 161 GB job — the same 0/27 freeze
// pattern that motivated 017A's SHA-256-branch decoupling, just in a
// different verify mode.
//
// We exercise the contract by stubbing TransferService with a verify
// completer the test controls. The forward sequence asserts:
//
//   1. Bytes are credited BEFORE verifyTransfer resolves (operator sees
//      live progress on long verify steps).
//   2. On verify success, file row lands at verifyStatus=notVerified +
//      verified=true (round-11 baseline preserved).
//   3. On verify failure, the credit is undone (completedBytes back to
//      0, file at status=failed). Rollback is the cost of decoupling.

class _NoopSlackService extends SlackService {
  _NoopSlackService(SettingsDao dao) : super(settingsDao: dao);

  @override
  Future<void> notifyTransferStarted({required Job job}) async {}
  @override
  Future<void> notifyTransferCompleted({
    required Job job,
    required int completedFiles,
    required int verifiedFiles,
    required int unverifiedFiles,
    required int mismatchedFiles,
    int? notVerifiedFiles,
  }) async {}
  @override
  Future<void> notifyTransferFailed({
    required Job job,
    required String fileName,
    required String error,
    required int completedFiles,
  }) async {}
  @override
  Future<void> notifyCompressionStarted({required Job job}) async {}
  @override
  Future<void> notifyCompressionCompleted({
    required Job job,
    required int completedFiles,
    required int totalFiles,
    Job? parentTransferJob,
    int? parentVerifiedFiles,
    int? parentNotVerifiedFiles,
    int? parentUnverifiedFiles,
    int? parentMismatchedFiles,
  }) async {}
  @override
  Future<void> notifyJobFailed({
    required int jobId,
    required String phase,
    required String error,
  }) async {}
}

class _ControlledTransferService extends TransferService {
  /// Resolves immediately for the single robocopy call (success).
  /// verifyTransfer blocks on `verifyRelease` so the test can assert
  /// the post-robocopy / pre-verify state.
  Completer<bool> verifyRelease = Completer<bool>();

  /// Set true once the test has read pre-verify progress.
  bool verifyEntered = false;
  Completer<void> verifyEnteredCompleter = Completer<void>();

  @override
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    // Touch the destination file so verifyTransfer's File.exists check
    // passes. The size doesn't matter — verifyTransfer is overridden
    // below.
    await File(destinationFile).create(recursive: true);
    return true;
  }

  @override
  Future<bool> verifyTransfer({
    required String sourceFile,
    required String destinationFile,
  }) async {
    verifyEntered = true;
    if (!verifyEnteredCompleter.isCompleted) verifyEnteredCompleter.complete();
    return await verifyRelease.future;
  }

  @override
  void cancel() {}
}

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;
  late _ControlledTransferService transferService;
  late JobQueueService queue;
  late Directory tempSrc;
  late Directory tempDest;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    transferService = _ControlledTransferService();
    queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferService,
      compressionService: CompressionService(),
      driveService: DriveService(),
    );
    tempSrc = Directory.systemTemp.createTempSync('size_mode_src_');
    tempDest = Directory.systemTemp.createTempSync('size_mode_dest_');
    // Source file must exist on disk so _processJob's source-exists
    // check passes.
    await File('${tempSrc.path}/IMG_0.MP4')
        .writeAsBytes(List<int>.filled(1024, 0));
  });

  tearDown(() async {
    await db.close();
    if (tempSrc.existsSync()) tempSrc.deleteSync(recursive: true);
    if (tempDest.existsSync()) tempDest.deleteSync(recursive: true);
  });

  Future<int> enqueueSizeModeJob() async {
    return await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.queued,
        sourcePath: tempSrc.path,
        destinationPath: tempDest.path,
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.size),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '${tempSrc.path}/IMG_0.MP4',
          destinationFilePath: '${tempDest.path}/IMG_0.MP4',
          fileName: 'IMG_0.MP4',
          fileSize: 1024,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1024,
    );
  }

  test(
      'forward path: bytes are credited BEFORE verifyTransfer resolves '
      '(SC-009 — no progress freeze during verify I/O stalls)', () async {
    final jobId = await enqueueSizeModeJob();

    final loop = queue.startProcessing();

    // Wait for the executor to enter verifyTransfer. By the time
    // verifyEntered is true, T024's restructured branch has already:
    //   1. called markFileCompleted(verified: false),
    //   2. incremented completedCount + completedBytes,
    //   3. called updateJobProgress.
    // Bytes MUST be visible in the DB even though verify hasn't
    // resolved yet.
    await transferService.verifyEnteredCompleter.future;

    final mid = await jobDao.getJob(jobId);
    expect(mid!.completedBytes, 1024,
        reason: 'Bytes must be credited to Job.completedBytes BEFORE '
            'verifyTransfer resolves. Without this, a verify-blocking '
            'I/O stall on a 161 GB job freezes the operator\'s '
            'progress bar — the same 0/27 freeze pattern the SHA-256 '
            'branch fixed in 017A.');
    expect(mid.completedFiles, 1);

    // Release verify with success; sequence finalizes.
    transferService.verifyRelease.complete(true);
    await loop;

    final files = await jobFileDao.getFilesForJob(jobId);
    expect(files.first.verifyStatus, VerifyStatus.notVerified,
        reason: 'Size-mode success → notVerified baseline (round-11).');
    expect(files.first.verified, isTrue,
        reason: 'Legacy `verified` boolean stays true on size-mode '
            'success to preserve v2.4.0 readers\' meaning.');
  });

  test(
      'recovery: size-mode file abandoned mid-verify '
      '(status=completed, verifyStatus=pending) is re-verified on '
      'next launch — Codex round-24 P2', () async {
    // Hand-seed the post-abandonment state directly: T024 created
    // this state by writing markFileCompleted BEFORE verifyTransfer.
    // A shutdown between the two writes leaves the row at
    // status=completed && verifyStatus=pending with bytes already
    // credited. Without the round-24 fix, the executor's resume-
    // time switch was treating these as "already done" and
    // continuing — verifyTransfer never re-ran, so the job could
    // be marked as passed even though verify never finished.
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        // Persisted state: paused (rescue path flips inProgress →
        // paused; getNextQueuedJob includes paused).
        status: JobStatus.paused,
        sourcePath: tempSrc.path,
        destinationPath: tempDest.path,
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.size),
        // Bytes were credited in the prior run before shutdown.
        completedFiles: const Value(1),
        completedBytes: const Value(1024),
        totalFiles: const Value(1),
        totalBytes: const Value(1024),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '${tempSrc.path}/IMG_0.MP4',
          destinationFilePath: '${tempDest.path}/IMG_0.MP4',
          fileName: 'IMG_0.MP4',
          fileSize: 1024,
          // Post-abandonment: copy succeeded, verify never ran.
          status: FileStatus.completed,
          // verifyStatus defaults to pending — exactly the state
          // a Phase-B drain leaves behind in T024's restructured
          // size-mode branch.
        ),
      ],
      totalBytes: 1024,
    );

    // Sanity: confirm the rescue selector picks this job up.
    final rescued = await jobDao.getRescuedJobIds();
    expect(rescued.contains(jobId), isTrue,
        reason: 'getRescuedJobIds must include size-mode jobs with '
            'completed+pending file rows. Round-24 dropped the '
            "stale `j.verification_mode = 'sha256'` filter.");

    // Pre-create the destination file so verifyTransfer can stat it.
    await File('${tempDest.path}/IMG_0.MP4').writeAsBytes(
        List<int>.filled(1024, 0));

    // Resume the queue. The executor's recovery branch must re-run
    // verifyTransfer for size-mode + completed + pending and
    // finalize the verify axis.
    final loop = queue.startProcessing();
    await transferService.verifyEnteredCompleter.future;
    transferService.verifyRelease.complete(true);
    await loop;

    final files = await jobFileDao.getFilesForJob(jobId);
    expect(files.first.verifyStatus, VerifyStatus.notVerified,
        reason: 'After recovery, the row must reach the size-mode '
            'verified terminal state. Without the fix it would stay '
            'at verifyStatus=pending forever.');
    expect(files.first.verified, isTrue);

    final after = await jobDao.getJob(jobId);
    expect(after!.completedBytes, 1024,
        reason: 'Bytes from the pre-abandonment credit are preserved '
            '(no double-count on recovery; no rollback on success).');
  });

  test(
      'rollback: verify failure undoes the credited bytes '
      '(completedBytes back to 0, file at status=failed)', () async {
    final jobId = await enqueueSizeModeJob();

    final loop = queue.startProcessing();
    await transferService.verifyEnteredCompleter.future;

    // Bytes are credited mid-flight (proven by the test above; sanity
    // re-check here).
    final mid = await jobDao.getJob(jobId);
    expect(mid!.completedBytes, 1024);

    // Release verify with FAILURE — restructured branch must roll back
    // both the row credit (markFileFailed) and the Job-level counters.
    transferService.verifyRelease.complete(false);
    await loop;

    final after = await jobDao.getJob(jobId);
    expect(after!.completedBytes, 0,
        reason: 'On size-mode verify failure, the credit is undone — '
            'bytes that failed verification are NOT trustworthy and '
            'must not count toward Job.completedBytes. This is the '
            'cost of decoupling progress from verify in the size-mode '
            'branch.');
    expect(after.completedFiles, 0,
        reason: 'completedFiles also rolled back for the same reason.');

    final files = await jobFileDao.getFilesForJob(jobId);
    expect(files.first.status, FileStatus.failed,
        reason: 'File row must end at status=failed on size-mismatch.');
  });
}
