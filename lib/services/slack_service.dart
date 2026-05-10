import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../database/database.dart';
import '../database/daos/settings_dao.dart';
import '../database/tables.dart';
import '../main.dart' show logService;
import '../utils/constants.dart';
import '../utils/format_utils.dart';

/// Sends Slack notifications at pipeline phase transitions.
/// Best-effort delivery — failures are logged but don't stop the pipeline.
class SlackService {
  final SettingsDao _settingsDao;
  final Dio _dio;

  SlackService({required SettingsDao settingsDao, Dio? dio})
      : _settingsDao = settingsDao,
        _dio = dio ?? Dio();

  Future<String?> _getWebhookUrl() async {
    final settings = await _settingsDao.getSettings();
    if (settings == null) return null;
    final url = settings.slackWebhookUrl;
    return url.isEmpty ? null : url;
  }

  Future<void> _send(String text) async {
    final url = await _getWebhookUrl();
    if (url == null) return;

    try {
      await _dio.post(
        url,
        data: {'text': text},
        options: Options(
          sendTimeout: Duration(milliseconds: slackTimeoutMs),
          receiveTimeout: Duration(milliseconds: slackTimeoutMs),
        ),
      );
      logService.info('Slack notification sent');
    } catch (e) {
      logService.error('Slack notification failed: $e');
    }
  }

  String _operatorLine(Job job) {
    final name = job.operatorName;
    return (name != null && name.isNotEmpty) ? '\nOperator: $name' : '';
  }

  Future<void> notifyTransferStarted({required Job job}) async {
    final totalGb = formatBytes(job.totalBytes);
    await _send(
      '📂 *Transfer Started*\n'
      'Job: ${job.id}${_operatorLine(job)}\n'
      'Source: ${job.sourcePath}\n'
      'Destination: ${job.destinationPath}\n'
      'Files: ${job.totalFiles} ($totalGb)',
    );
  }

  /// 017 (T043, FR-016): expanded with per-state verify counts. Warning
  /// prefix when mismatchedFiles > 0 OR unverifiedFiles > 0; clean
  /// checkmark only when both are zero. Constitution Principle V —
  /// operators walking away receive actionable detail about non-clean
  /// completions rather than a misleading green check.
  /// 018 T014 (FR-014, US5, P3): added `notVerifiedFiles` so the
  /// passed-label wording mirrors the round-20 fix already shipped in
  /// [notifyCompressionCompleted]. Without this, a clean default
  /// size-mode transfer (every file at `verifyStatus=notVerified`,
  /// 0 SHA-256-verified) would render the bare-zero phrasing
  /// "Verification: Size — Passed" with the body line "Verified: 0 ..."
  /// — operator-confusing because it visually reads like nothing was
  /// checked. Now reads "Verification: Size — N size-verified · Passed"
  /// and a "Size-only" body field counts the size-mode successes
  /// distinctly from "Verified" (cryptographic) and "Unverified"
  /// (subsystem failure). Behavior unchanged for SHA-256-only transfers
  /// where `notVerifiedFiles == 0`.
  Future<void> notifyTransferCompleted({
    required Job job,
    required int completedFiles,
    required int verifiedFiles,
    required int unverifiedFiles,
    required int mismatchedFiles,
    int? notVerifiedFiles,
  }) async {
    await _send(
      formatTransferCompletedBody(
        job: job,
        completedFiles: completedFiles,
        verifiedFiles: verifiedFiles,
        unverifiedFiles: unverifiedFiles,
        mismatchedFiles: mismatchedFiles,
        notVerifiedFiles: notVerifiedFiles,
      ),
    );
  }

  /// 018 T016 (FR-014): formatting extracted as a pure static so tests
  /// can assert the wording without booting the full SlackService +
  /// Dio + global LogService. The runtime [notifyTransferCompleted]
  /// delegates here; behavior is byte-identical.
  @visibleForTesting
  static String formatTransferCompletedBody({
    required Job job,
    required int completedFiles,
    required int verifiedFiles,
    required int unverifiedFiles,
    required int mismatchedFiles,
    int? notVerifiedFiles,
  }) {
    final totalGb = formatBytes(job.totalBytes);
    final duration = job.startedAt != null
        ? DateTime.now().difference(job.startedAt!).inMinutes
        : 0;
    final mode =
        job.verificationMode == VerificationMode.sha256 ? 'SHA-256' : 'Size';
    final notVerified = notVerifiedFiles ?? 0;
    final passedLabel = (verifiedFiles > 0 && notVerified > 0)
        ? '$verifiedFiles verified + $notVerified size-only · Passed'
        : verifiedFiles > 0
            ? '$verifiedFiles verified · Passed'
            : '$notVerified size-verified · Passed';
    final verdict = mismatchedFiles > 0
        ? '⚠ $mismatchedFiles file(s) FAILED verification'
        : unverifiedFiles > 0
            ? '⚠ $unverifiedFiles file(s) copied but UNVERIFIED'
            : 'Verification: $mode — $passedLabel';
    final emoji = (mismatchedFiles > 0 || unverifiedFiles > 0) ? '⚠' : '✅';
    final operator = (job.operatorName != null && job.operatorName!.isNotEmpty)
        ? '\nOperator: ${job.operatorName}'
        : '';
    return '$emoji *Transfer Complete*\n'
        'Job: ${job.id}$operator\n'
        'Files: $completedFiles/${job.totalFiles}\n'
        'Verified: $verifiedFiles · Size-only: $notVerified · Unverified: $unverifiedFiles · Mismatch: $mismatchedFiles\n'
        'Size: $totalGb\n'
        'Duration: $duration min\n'
        '$verdict';
  }

  Future<void> notifyTransferFailed({
    required Job job,
    required String fileName,
    required String error,
    required int completedFiles,
  }) async {
    await _send(
      '❌ *Transfer FAILED*\n'
      'Job: ${job.id}${_operatorLine(job)}\n'
      'File: $fileName\n'
      'Error: $error\n'
      'Completed: $completedFiles/${job.totalFiles} before failure',
    );
  }

  Future<void> notifyCompressionStarted({required Job job}) async {
    await _send(
      '🎬 *Compression Started*\n'
      'Job: ${job.id}${_operatorLine(job)}\n'
      'Preset: ${job.presetName ?? "unknown"}\n'
      'Files: ${job.totalFiles}\n'
      'Output: ${job.compressionOutputPath ?? job.destinationPath}',
    );
  }

  /// 017 (T044, FR-019): expanded with parent transfer-phase verify
  /// counts. For chained compression jobs (created by
  /// `_createChainedCompressionJob` from a transferAndCompress parent),
  /// pass the parent's verify counts so the operator's final Slack ping
  /// surfaces transfer-side outcomes — closes the cross-phase notification
  /// gap (Constitution Principle V).
  ///
  /// Standalone compression jobs (no parent) pass null for all 4 parent
  /// params; the verify line is omitted.
  Future<void> notifyCompressionCompleted({
    required Job job,
    required int completedFiles,
    required int totalFiles,
    Job? parentTransferJob,
    int? parentVerifiedFiles,
    int? parentNotVerifiedFiles,
    int? parentUnverifiedFiles,
    int? parentMismatchedFiles,
  }) async {
    final duration = job.startedAt != null
        ? DateTime.now().difference(job.startedAt!).inMinutes
        : 0;
    final hasParent = parentTransferJob != null;
    final mismatched = parentMismatchedFiles ?? 0;
    final unverified = parentUnverifiedFiles ?? 0;
    final verified = parentVerifiedFiles ?? 0;
    final notVerified = parentNotVerifiedFiles ?? 0;
    // Codex round-20 P2 #2: size-mode jobs land at verifyStatus=notVerified
    // — count those into the "passed" tally so a default size-mode
    // transferAndCompress doesn't report "0 verified · Passed". When
    // both axes have counts (mixed history), surface the SHA-256
    // count plus a "+ N size-only" suffix so the operator can tell
    // whether cryptographic trust was established.
    final passedLabel = mismatched == 0 && unverified == 0
        ? (verified > 0 && notVerified > 0
            ? '$verified verified + $notVerified size-only · Passed'
            : verified > 0
                ? '$verified verified · Passed'
                : '$notVerified size-verified · Passed')
        : null;
    final verifyLine = hasParent
        ? (mismatched > 0
            ? '⚠ Transfer verification: $mismatched file(s) FAILED'
            : unverified > 0
                ? '⚠ Transfer verification: $unverified file(s) UNVERIFIED'
                : 'Transfer verification: $passedLabel')
        : null;
    final emoji = (mismatched > 0 || unverified > 0) ? '⚠' : '✅';
    final body = StringBuffer()
      ..writeln('$emoji *Compression Complete*')
      ..writeln('Job: ${job.id}${_operatorLine(job)}')
      ..writeln('Files: $completedFiles/$totalFiles')
      ..writeln('Duration: $duration min');
    if (verifyLine != null) body.writeln(verifyLine);
    await _send(body.toString().trimRight());
  }

  Future<void> notifyJobFailed({
    required int jobId,
    required String phase,
    required String error,
  }) async {
    await _send(
      '❌ *$phase FAILED*\n'
      'Job: $jobId\n'
      'Error: $error',
    );
  }

  /// Send a test notification to verify webhook configuration.
  Future<bool> sendTestNotification() async {
    final url = await _getWebhookUrl();
    if (url == null) return false;

    try {
      final response = await _dio.post(
        url,
        data: {'text': '🔔 *Video Pipeline* — Test notification. Webhook is working!'},
        options: Options(
          sendTimeout: Duration(milliseconds: slackTimeoutMs),
          receiveTimeout: Duration(milliseconds: slackTimeoutMs),
        ),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
