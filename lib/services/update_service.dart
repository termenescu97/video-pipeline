import 'package:dio/dio.dart';

import '../utils/constants.dart';

/// Result of an update check.
class UpdateCheckResult {
  final bool updateAvailable;
  final String? latestVersion;
  final String? downloadUrl;
  final String? releaseNotes;

  UpdateCheckResult({
    required this.updateAvailable,
    this.latestVersion,
    this.downloadUrl,
    this.releaseNotes,
  });
}

/// Checks GitHub Releases for app updates.
/// Never auto-updates — always prompts the user (Constitution Principle VI).
class UpdateService {
  final Dio _dio;

  UpdateService({Dio? dio}) : _dio = dio ?? Dio();

  /// Check GitHub Releases for a newer version.
  Future<UpdateCheckResult> checkForUpdate() async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$githubRepo/releases/latest',
        options: Options(
          headers: {'Accept': 'application/vnd.github.v3+json'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode != 200) {
        return UpdateCheckResult(updateAvailable: false);
      }

      final data = response.data as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      final latestVersion = tagName.replaceFirst('v', '');

      if (_isNewer(latestVersion, appVersion)) {
        // Find the Windows zip asset.
        final assets = data['assets'] as List<dynamic>? ?? [];
        String? downloadUrl;
        for (final asset in assets) {
          final name = (asset['name'] as String?) ?? '';
          if (name.contains('windows') && name.endsWith('.zip')) {
            downloadUrl = asset['browser_download_url'] as String?;
            break;
          }
        }

        return UpdateCheckResult(
          updateAvailable: true,
          latestVersion: latestVersion,
          downloadUrl: downloadUrl,
          releaseNotes: data['body'] as String?,
        );
      }

      return UpdateCheckResult(updateAvailable: false);
    } catch (_) {
      return UpdateCheckResult(updateAvailable: false);
    }
  }

  /// Compare version strings (simple semver comparison).
  bool _isNewer(String latest, String current) {
    final latestParts = latest.split('.').map(int.tryParse).toList();
    final currentParts = current.split('.').map(int.tryParse).toList();

    for (var i = 0; i < 3; i++) {
      final l = (i < latestParts.length ? latestParts[i] : 0) ?? 0;
      final c = (i < currentParts.length ? currentParts[i] : 0) ?? 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}
