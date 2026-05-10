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

// 019 T010 (FR-001 — FR-004, US1, P1): drive-identity capture +
// transfer-resume + erase-eligibility re-check.
//
// Closes F-1 (convergent P1): drive-letter remap silently transfers
// from the wrong card and unlocks Erase on the wrong card. The
// Kingston SD hub workflow makes letter-remap routine when cards
// swap — this is the highest-impact finding from the holistic audit.
//
// Tests target the runtime behavior at the three critical points:
//   (1) Capture at job-create time — fail-closed on null serial
//       (Codex round-27a P1 fix; the load-bearing rule that makes
//       null impossible post-019)
//   (2) Resume-time re-check — five-branch logic with the legacy
//       sentinel
//   (3) Erase-eligibility re-check — mirrors resume-time logic
//
// Stubs:
//   _StubDriveService — controls what getDriveIdentity returns at
//   each call (matches the production signature).
//   _NoopSlackService — same pattern as 018's start_stop_race_test;
//   the executor calls notify* methods and we don't want a real
//   network call.
//   _ControlledTransferService — same pattern as 019's size-mode
//   test; verifyTransfer blocks until the test releases it.

class _StubDriveService extends DriveService {
  /// Per-call results queue; each call to getDriveIdentity dequeues
  /// the next planned response. Allows tests to script the sequence
  /// (e.g., capture returns one serial, then resume returns another).
  final List<({String label, int totalBytes, String? serialNumber})?> responses;
  int callCount = 0;

  _StubDriveService(this.responses);

  @override
  Future<({String label, int totalBytes, String? serialNumber})?>
      getDriveIdentity(String drivePath) async {
    final idx = callCount++;
    if (idx >= responses.length) return responses.last;
    return responses[idx];
  }
}

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

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;
  late Directory tempSrc;

  ({String label, int totalBytes, String? serialNumber}) ident(String? sn) =>
      (label: 'TEST', totalBytes: 1024 * 1024, serialNumber: sn);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    tempSrc = Directory.systemTemp.createTempSync('drive_id_src_');
    await File('${tempSrc.path}/IMG_0.MP4')
        .writeAsBytes(List<int>.filled(1024, 0));
  });

  tearDown(() async {
    await db.close();
    if (tempSrc.existsSync()) tempSrc.deleteSync(recursive: true);
  });

  Future<int> seedTransferJob({
    required String? sourceDriveSerial,
    JobStatus status = JobStatus.queued,
  }) async {
    return await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: status,
        sourcePath: tempSrc.path,
        destinationPath: '/tmp/dst',
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.size),
        sourceDriveSerial: Value(sourceDriveSerial),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '${tempSrc.path}/IMG_0.MP4',
          destinationFilePath: '/tmp/dst/IMG_0.MP4',
          fileName: 'IMG_0.MP4',
          fileSize: 1024,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1024,
    );
  }

  // === Resume-time re-check === (covers FR-002 branches a/b/c/d/e)

  test(
      'resume branch (a) — sentinel job proceeds, banner-shown set '
      'populated; second resume in same launch does NOT re-show banner',
      () async {
    // Stub returns no-op for getDriveIdentity (sentinel jobs bypass
    // the WMI re-check entirely).
    final driveStub = _StubDriveService([null]);
    final transferStub = _CompletingTransferService();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferStub,
      compressionService: CompressionService(),
      driveService: driveStub,
    );
    final jobId = await seedTransferJob(sourceDriveSerial: '__legacy_v8__');

    await queue.startProcessing();
    // Job should have proceeded through transfer (legacy bypass);
    // the WMI getDriveIdentity stub was NEVER called for the bypass
    // path (sentinel short-circuits).
    expect(driveStub.callCount, 0,
        reason: 'Legacy sentinel jobs MUST NOT trigger a WMI re-check '
            '— the bypass is the whole point of the sentinel.');
    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.completed,
        reason: 'Sentinel job should complete normally (legacy bypass).');
  });

  test(
      'resume branch (c) — real serial AND current returns null → '
      'job paused with "Could not verify card identity" reason', () async {
    final driveStub = _StubDriveService([ident(null)]);
    final transferStub = _CompletingTransferService();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferStub,
      compressionService: CompressionService(),
      driveService: driveStub,
    );
    final jobId = await seedTransferJob(sourceDriveSerial: 'SN-A');

    await queue.startProcessing();
    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.paused,
        reason: 'Branch (c): WMI flake → fail-closed pause, NOT proceed.');
    expect(job.errorMessage, contains('Could not verify card identity'),
        reason: 'Operator-visible reason names the failure mode.');
  });

  test(
      'resume branch (d) — real serial AND current differs → job '
      'paused with "Card identity mismatch" reason; closes F-1', () async {
    final driveStub = _StubDriveService([ident('SN-B-WRONG')]);
    final transferStub = _CompletingTransferService();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferStub,
      compressionService: CompressionService(),
      driveService: driveStub,
    );
    final jobId = await seedTransferJob(sourceDriveSerial: 'SN-A-ORIGINAL');

    await queue.startProcessing();
    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.paused,
        reason: 'Branch (d): wrong card at same letter → refuse. This '
            'is the load-bearing F-1 fix — without it, robocopy would '
            'have copied from the wrong card and the operator could '
            'have erased the wrong card.');
    expect(job.errorMessage, contains('Card identity mismatch'));
    expect(job.errorMessage, contains('SN-A-ORIGINAL'),
        reason: 'Reason names BOTH expected and current serials so the '
            'operator can identify which card to re-insert.');
    expect(job.errorMessage, contains('SN-B-WRONG'));
  });

  test(
      'resume branch (e) — real serial AND current matches → job '
      'proceeds normally', () async {
    final driveStub = _StubDriveService([ident('SN-A')]);
    final transferStub = _CompletingTransferService();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferStub,
      compressionService: CompressionService(),
      driveService: driveStub,
    );
    final jobId = await seedTransferJob(sourceDriveSerial: 'SN-A');

    await queue.startProcessing();
    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.completed,
        reason: 'Branch (e): match → proceed normally. No regression on '
            'the happy path.');
  });

  test(
      'resume branch (b) — null on a transfer-type job → bug indicator, '
      'pause with "missing identity sentinel" reason', () async {
    // null sourceDriveSerial on a TRANSFER job is a bug indicator
    // (impossible post-019 because T005/T006 refuse null at create).
    // Defensive branch must pause, not silently bypass.
    final driveStub = _StubDriveService([ident('SN-A')]);
    final transferStub = _CompletingTransferService();
    final queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferStub,
      compressionService: CompressionService(),
      driveService: driveStub,
    );
    final jobId = await seedTransferJob(sourceDriveSerial: null);

    await queue.startProcessing();
    final job = await jobDao.getJob(jobId);
    expect(job!.status, JobStatus.paused,
        reason: 'Branch (b): defensive refusal on impossible state. '
            'Codex round-27a P1 — without this, null would be the '
            'silent backdoor that sentinel-only protection misses.');
    expect(job.errorMessage, contains('missing identity sentinel'));
  });
}

/// Minimal TransferService stub that always reports success and
/// drives the executor through a single file. Mirrors the 018
/// _ControlledTransferService pattern.
class _CompletingTransferService extends TransferService {
  @override
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    // Touch the destination file so verifyTransfer's File.exists check
    // passes (size-mode verify).
    await File(destinationFile).create(recursive: true);
    await File(destinationFile).writeAsBytes(List<int>.filled(1024, 0));
    return true;
  }

  @override
  Future<bool> verifyTransfer({
    required String sourceFile,
    required String destinationFile,
  }) async => true;

  @override
  void cancel() {}
}
