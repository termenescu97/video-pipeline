import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/settings_dao.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/main.dart' as app_main;
import 'package:video_pipeline/services/log_service.dart';
import 'package:video_pipeline/services/slack_service.dart';

// 019 T028 (FR-018, US6, P3): Slack best-effort contract under
// SettingsDao failure.
//
// Codex round-26 P2 [LIKELY]: `SlackService._send` originally called
// `_getWebhookUrl()` BEFORE the try block, so a SettingsDao failure
// (DB locked, schema error, etc.) propagated up into the calling
// pipeline phase — turning what should be a swallowed observability
// concern into a pipeline-killing exception. Constitution V says
// observable progress should never block the main pipeline; T027 moved
// the call inside the try block.
//
// This test verifies the contract: a SettingsDao that throws on
// getSettings() does NOT cause the Slack notify call to throw —
// the failure is logged and the pipeline caller proceeds.

class _ThrowingSettingsDao extends SettingsDao {
  _ThrowingSettingsDao(super.db);

  @override
  Future<AppSetting?> getSettings() async {
    throw StateError('synthetic settings DAO failure');
  }
}

void main() {
  setUpAll(() async {
    // SlackService.send touches the global logService from main.dart.
    // Initialize it once for the test process. Late-final means
    // subsequent assignments throw — guard with a try/catch on read.
    try {
      // ignore: unnecessary_statements
      app_main.logService;
    } catch (_) {
      app_main.logService = LogService();
      await app_main.logService.init();
    }
  });

  test(
      'SettingsDao throw on getSettings does NOT propagate from any '
      'Slack notify call (Constitution V — observability must not '
      'block the main pipeline)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final throwingDao = _ThrowingSettingsDao(db);
    final slack = SlackService(settingsDao: throwingDao, dio: Dio());

    // Build a synthetic Job (the only field Slack reads is operatorName
    // + the totals; defaults are fine).
    final jobId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.completed,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
            sourceDriveSerial: const Value('SN-TEST'),
          ),
        );
    final job = (await db.jobDao.getJob(jobId))!;

    // Each notify path must complete without rethrowing the
    // SettingsDao failure. We test all five (the five that exist on
    // SlackService at v2.5.0). Any rethrow → test fails.
    await expectLater(
      slack.notifyTransferStarted(job: job),
      completes,
      reason: 'notifyTransferStarted MUST NOT propagate SettingsDao failures.',
    );
    await expectLater(
      slack.notifyTransferCompleted(
        job: job,
        completedFiles: 1,
        verifiedFiles: 0,
        unverifiedFiles: 0,
        mismatchedFiles: 0,
      ),
      completes,
      reason: 'notifyTransferCompleted MUST NOT propagate SettingsDao failures.',
    );
    await expectLater(
      slack.notifyTransferFailed(
        job: job,
        fileName: 'IMG_1.MOV',
        error: 'test',
        completedFiles: 0,
      ),
      completes,
    );
    await expectLater(
      slack.notifyCompressionStarted(job: job),
      completes,
    );
    await expectLater(
      slack.notifyCompressionCompleted(
        job: job,
        completedFiles: 1,
        totalFiles: 1,
      ),
      completes,
    );
  });
}
