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

// 019 T022 (FR-010 — FR-012, US4, P2): force-delete deferred clear.
//
// Closes F-4 (convergent P2): forceDestDeleteApproved was previously
// consumed (cleared) at the TOP of the per-file iteration, BEFORE
// the dest-delete + robocopy actually ran. A cancel mid-robocopy or
// crash between consumption and robocopy success would launder the
// operator's retry intent — the next pass would re-hit the same
// corrupt destination without forcing replacement, even though the
// CLAUDE.md spec says "Re-mismatch on the next pass requires a fresh
// banner Retry click." Codex round-26 marked this LIKELY (Opus) and
// CERTAIN (Codex).
//
// Fix (T019 + T020): clear is moved to AFTER markFileCompleted lands.
// Cancel/crash before that point preserves the column.
//
// Cases:
//   1. Successful run with forceDestDelete=true → column reads false
//      after execution (consumed on success).
//   2. Failed run (TransferService returns false) with
//      forceDestDelete=true → column STILL reads true (preserved on
//      failure path so the next retry re-honors it).
//   3. acceptMismatch on a forceDestDelete=true file → column reads
//      false (operator's accept supersedes prior Retry intent).
//   4. acceptUnverified on a forceDestDelete=true file → column reads
//      false (same rationale).

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

class _ControllableTransferService extends TransferService {
  bool transferShouldSucceed;
  _ControllableTransferService({this.transferShouldSucceed = true});

  @override
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    if (transferShouldSucceed) {
      await File(destinationFile).create(recursive: true);
      await File(destinationFile).writeAsBytes(List<int>.filled(1024, 0));
    }
    return transferShouldSucceed;
  }

  @override
  Future<bool> verifyTransfer({
    required String sourceFile,
    required String destinationFile,
  }) async => true;

  @override
  void cancel() {}
}

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;
  late Directory tempSrc;
  late Directory tempDest;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    tempSrc = Directory.systemTemp.createTempSync('forcedel_src_');
    tempDest = Directory.systemTemp.createTempSync('forcedel_dest_');
    await File('${tempSrc.path}/IMG_0.MP4')
        .writeAsBytes(List<int>.filled(1024, 0));
  });

  tearDown(() async {
    await db.close();
    if (tempSrc.existsSync()) tempSrc.deleteSync(recursive: true);
    if (tempDest.existsSync()) tempDest.deleteSync(recursive: true);
  });

  Future<({int jobId, int fileId})> seedForceDeleteFile() async {
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.queued,
        sourcePath: tempSrc.path,
        destinationPath: tempDest.path,
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.size),
        // 019: legacy sentinel — bypass identity re-check from Phase 2;
        // this test is about force-delete column lifecycle, not identity.
        sourceDriveSerial: const Value('__legacy_v8__'),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '${tempSrc.path}/IMG_0.MP4',
          destinationFilePath: '${tempDest.path}/IMG_0.MP4',
          fileName: 'IMG_0.MP4',
          fileSize: 1024,
          status: FileStatus.pending,
          // The load-bearing pre-condition: column starts true.
          forceDestDeleteApproved: const Value(true),
        ),
      ],
      totalBytes: 1024,
    );
    final files = await jobFileDao.getFilesForJob(jobId);
    return (jobId: jobId, fileId: files.first.id);
  }

  test(
      'case 1: successful run consumes force-delete approval (column '
      'reads false after markFileCompleted)', () async {
    final ids = await seedForceDeleteFile();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: _ControllableTransferService(transferShouldSucceed: true),
      compressionService: CompressionService(),
      driveService: DriveService(),
    );

    await queue.startProcessing();

    final files = await jobFileDao.getFilesForJob(ids.jobId);
    expect(files.first.forceDestDeleteApproved, isFalse,
        reason: 'On the successful path, force-delete approval is '
            'consumed AFTER markFileCompleted lands. The operator\'s '
            'intent for this robocopy invocation is now satisfied.');
    expect(files.first.status, FileStatus.completed,
        reason: 'Sanity: file did complete successfully.');
  });

  test(
      'case 2: failed run PRESERVES force-delete approval (column '
      'still reads true so the next retry re-honors it) — Codex '
      'round-26 P2 fix', () async {
    final ids = await seedForceDeleteFile();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: _ControllableTransferService(transferShouldSucceed: false),
      compressionService: CompressionService(),
      driveService: DriveService(),
    );

    await queue.startProcessing();

    final files = await jobFileDao.getFilesForJob(ids.jobId);
    expect(files.first.forceDestDeleteApproved, isTrue,
        reason: 'F-4 fix: cancel/crash mid-robocopy MUST preserve the '
            'operator\'s force-delete approval. The previous top-of-'
            'loop clear consumed intent before the work happened — the '
            'next pass would re-hit the same corrupt destination '
            'without forcing replacement. Deferred clear (T020) only '
            'fires after markFileCompleted lands; failure paths leave '
            'the column intact.');
    expect(files.first.status, FileStatus.failed,
        reason: 'Sanity: transfer did fail.');
  });

  test(
      'case 3: acceptMismatch clears stale force-delete approval '
      '(operator\'s accept supersedes their prior Retry intent)',
      () async {
    final ids = await seedForceDeleteFile();
    // No executor run — directly invoke acceptMismatch.
    await jobFileDao.acceptMismatch(ids.fileId);

    final files = await jobFileDao.getFilesForJob(ids.jobId);
    expect(files.first.forceDestDeleteApproved, isFalse,
        reason: 'T021: acceptMismatch must clear stale force-delete '
            'approval. Without this, a later re-run could mis-fire the '
            'force-delete on a file the operator already accepted.');
    expect(files.first.verifyStatus, VerifyStatus.verified,
        reason: 'Sanity: accept did flip the verify-axis state.');
  });

  test(
      'case 4: acceptUnverified clears stale force-delete approval '
      '(symmetric with acceptMismatch)', () async {
    final ids = await seedForceDeleteFile();
    await jobFileDao.acceptUnverified(ids.fileId);

    final files = await jobFileDao.getFilesForJob(ids.jobId);
    expect(files.first.forceDestDeleteApproved, isFalse,
        reason: 'T021: acceptUnverified mirrors acceptMismatch — '
            'clears stale force-delete approval as part of the '
            'accept transaction.');
    expect(files.first.verifyStatus, VerifyStatus.notVerified);
  });
}
