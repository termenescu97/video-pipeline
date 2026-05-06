import 'package:dio/dio.dart';

import '../database/database.dart';
import '../database/daos/settings_dao.dart';
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
    } catch (_) {
      // Best-effort: swallow errors, pipeline continues.
    }
  }

  Future<void> notifyTransferStarted({required Job job}) async {
    final totalGb = formatBytes(job.totalBytes);
    await _send(
      '📂 *Transfer Started*\n'
      'Job: ${job.id}\n'
      'Source: ${job.sourcePath}\n'
      'Destination: ${job.destinationPath}\n'
      'Files: ${job.totalFiles} ($totalGb)',
    );
  }

  Future<void> notifyTransferCompleted({
    required Job job,
    required int completedFiles,
    bool allVerified = true,
  }) async {
    final totalGb = formatBytes(job.totalBytes);
    final duration = job.startedAt != null
        ? DateTime.now().difference(job.startedAt!).inMinutes
        : 0;
    await _send(
      '✅ *Transfer Complete*\n'
      'Job: ${job.id}\n'
      'Files: $completedFiles/${job.totalFiles}\n'
      'Size: $totalGb\n'
      'Duration: $duration min\n'
      'Verification: ${allVerified ? "Passed" : "FAILED — some files did not match"}',
    );
  }

  Future<void> notifyTransferFailed({
    required Job job,
    required String fileName,
    required String error,
    required int completedFiles,
  }) async {
    await _send(
      '❌ *Transfer FAILED*\n'
      'Job: ${job.id}\n'
      'File: $fileName\n'
      'Error: $error\n'
      'Completed: $completedFiles/${job.totalFiles} before failure',
    );
  }

  Future<void> notifyCompressionStarted({required Job job}) async {
    await _send(
      '🎬 *Compression Started*\n'
      'Job: ${job.id}\n'
      'Preset: ${job.presetName ?? "unknown"}\n'
      'Files: ${job.totalFiles}\n'
      'Output: ${job.compressionOutputPath ?? job.destinationPath}',
    );
  }

  Future<void> notifyCompressionCompleted({
    required Job job,
    required int completedFiles,
    required int totalFiles,
  }) async {
    final duration = job.startedAt != null
        ? DateTime.now().difference(job.startedAt!).inMinutes
        : 0;
    await _send(
      '✅ *Compression Complete*\n'
      'Job: ${job.id}\n'
      'Files: $completedFiles/$totalFiles\n'
      'Duration: $duration min',
    );
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
