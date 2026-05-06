import 'package:flutter/material.dart';

import 'database/daos/settings_dao.dart';
import 'main.dart';
import 'services/update_service.dart';
import 'ui/theme/app_theme.dart';
import 'ui/screens/shell_screen.dart';

class VideoPipelineApp extends StatefulWidget {
  const VideoPipelineApp({super.key});

  @override
  State<VideoPipelineApp> createState() => _VideoPipelineAppState();
}

class _VideoPipelineAppState extends State<VideoPipelineApp> {
  @override
  void initState() {
    super.initState();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    final settingsDao = SettingsDao(database);
    final settings = await settingsDao.getSettings();
    if (!settings.checkUpdatesOnLaunch) return;

    final updateService = UpdateService();
    final result = await updateService.checkForUpdate();

    if (result.updateAvailable && mounted) {
      await settingsDao.setLastUpdateCheck(DateTime.now());
      _showUpdateDialog(result);
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update Available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${result.latestVersion} is available.'),
            if (result.releaseNotes != null) ...[
              const SizedBox(height: 8),
              Text(
                result.releaseNotes!,
                style: const TextStyle(fontSize: 12),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          if (result.downloadUrl != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                // Open download URL in browser.
                // In production, use url_launcher package.
              },
              child: const Text('Download'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Pipeline',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const ShellScreen(),
    );
  }
}
