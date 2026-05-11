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

// 018 T012 (FR-008, US3, P2, SC-004): start/stop race coverage.
//
// Codex round-22 P2: in the original `_stopRequested` design, two
// concurrent `startProcessing()` calls during stop drain could
// both observe `_isProcessing == false` (set by stopProcessing)
// and both proceed, spawning two concurrent loops. The fix (T010):
// startProcessing AWAITS the in-flight `_stopCompleter` BEFORE the
// re-check + atomic flip of `_isProcessing`. The re-check and
// flip MUST sit on consecutive lines with no `await` between them.
//
// We exercise the race by stubbing `TransferService` with a
// shared release completer. Every `transferFile` call increments
// an in-flight counter; the test asserts `maxInFlight == 1` —
// proving NO two concurrent loops ever ran the executor in
// parallel. In unfixed code, two concurrent loops would BOTH
// call transferFile against different queued jobs and the in-
// flight counter would reach 2.

class _NoopSlackService extends SlackService {
  // Override every notify* call to a no-op so we don't reach Slack's
  // settings-DAO + global logService dependencies (uninitialized in
  // unit tests). Constructor still requires settingsDao for the
  // base-class init; we just never invoke its methods.
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

class _SharedReleaseTransferService extends TransferService {
  /// Number of concurrent `transferFile` invocations currently
  /// pending (between increment-on-entry and decrement-on-exit).
  /// With the fix in place this MUST never exceed 1.
  int inFlight = 0;
  int maxInFlight = 0;

  /// Shared completer that all `transferFile` calls await. Test
  /// completes it once to release every pending call AND every
  /// future call (subsequent awaits resolve immediately).
  final Completer<bool> release = Completer<bool>();

  /// Resolves when the FIRST `transferFile` is observably in
  /// flight. Tests use this to synchronize before firing
  /// stopProcessing + concurrent starts.
  final Completer<void> firstStarted = Completer<void>();

  @override
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    if (!firstStarted.isCompleted) firstStarted.complete();
    try {
      return await release.future;
    } finally {
      inFlight--;
    }
  }

  @override
  void cancel() {
    // Intentional no-op. Cancelling here would release the shared
    // completer and shrink the test's race window. The test
    // controls release timing manually.
  }

  @override
  Future<bool> verifyTransfer({
    required String sourceFile,
    required String destinationFile,
  }) async =>
      true;
}

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;
  late _SharedReleaseTransferService transferService;
  late JobQueueService queue;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    transferService = _SharedReleaseTransferService();
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);

    queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: _NoopSlackService(db.settingsDao),
      transferService: transferService,
      compressionService: CompressionService(),
      driveService: DriveService(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  // _processJob's first step is `if (!await sourceDir.exists())` — so
  // the synthetic source path MUST resolve to an existing directory
  // for the loop to reach _processTransfer. Use an OS-level temp dir.
  late final Directory tempSrc =
      Directory.systemTemp.createTempSync('start_stop_src_');
  late final Directory tempDest =
      Directory.systemTemp.createTempSync('start_stop_dest_');

  Future<void> enqueueJobs(int count) async {
    for (var i = 0; i < count; i++) {
      await jobDao.createJobWithFiles(
        job: JobsCompanion.insert(
          type: JobType.transfer,
          status: JobStatus.queued,
          sourcePath: tempSrc.path,
          destinationPath: tempDest.path,
          createdAt: DateTime.now(),
          verificationMode: const Value(VerificationMode.size),
          sortOrder: Value(i),
        ),
        buildFiles: (jId) => [
          JobFilesCompanion.insert(
            jobId: jId,
            sourceFilePath: '${tempSrc.path}/IMG_$i.MP4',
            destinationFilePath: '${tempDest.path}/IMG_$i.MP4',
            fileName: 'IMG_$i.MP4',
            fileSize: 1024,
            status: FileStatus.pending,
          ),
        ],
        totalBytes: 1024,
      );
    }
  }

  test(
      'N concurrent startProcessing calls during stop drain produce '
      'at most ONE in-flight transferFile (SC-004)', () async {
    // Multiple jobs so concurrent loops would have something to race
    // over. Without the fix, each spawned loop would pick a different
    // queued job and call transferFile in parallel.
    await enqueueJobs(5);

    // Loop A starts, picks job 1, calls transferFile, blocks.
    final loopA = queue.startProcessing();
    await transferService.firstStarted.future;
    expect(transferService.inFlight, 1);

    // Stop drain begins. Sets _stopRequested + _stopCompleter.
    // _transferService.cancel() is a no-op in our stub, so the
    // pending transferFile stays blocked — opening the race window.
    final stop = queue.stopProcessing();

    // Fire 5 concurrent startProcessing calls during the drain
    // window. With the fix: all 5 await _stopCompleter.future.
    // Without the fix: 5 loops spawn and race for jobs 2-5.
    final concurrentStarts =
        List.generate(5, (_) => queue.startProcessing());

    // Yield repeatedly so the concurrent starts get scheduled and
    // queue up on _stopCompleter.future before we release the loop.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // Release the in-flight (and any future) transferFile calls.
    // Loop A's iteration finishes; _processTransfer returns;
    // outer loop sees _stopRequested and exits;
    // _stopCompleter resolves; the queued startProcessing calls
    // unblock; the atomic re-check + flip lets one win.
    transferService.release.complete(false);

    await stop;
    await loopA;
    await Future.wait(concurrentStarts);

    expect(transferService.maxInFlight, 1,
        reason: 'FR-008: at most one transferFile in flight at any '
            'moment, regardless of how many concurrent '
            'startProcessing calls arrive during a stop drain.');
  });

  test(
      'reentrant startProcessing during a clean (non-stop) run does NOT '
      'spawn a second loop', () async {
    await enqueueJobs(3);

    final loopA = queue.startProcessing();
    await transferService.firstStarted.future;

    // No stop in flight. Concurrent starts hit the early
    // `if (_isProcessing) return` check immediately.
    final concurrentStarts =
        List.generate(3, (_) => queue.startProcessing());

    // Release everything; loop A drains all 3 jobs sequentially.
    transferService.release.complete(false);

    await loopA;
    await Future.wait(concurrentStarts);

    expect(transferService.maxInFlight, 1,
        reason: 'No reentry should produce concurrent loops; the early '
            '_isProcessing guard rejects duplicate starts.');
  });

  test(
      'stopProcessing on a never-started queue is a no-op '
      '(_stopRequested cleared so future starts proceed)', () async {
    await enqueueJobs(1);

    // Stop without having started — should resolve immediately AND
    // leave the service in a state where a subsequent start works.
    await queue.stopProcessing();

    final loop = queue.startProcessing();
    await transferService.firstStarted.future;
    transferService.release.complete(false);
    await loop;

    expect(transferService.maxInFlight, 1);
  });
}
