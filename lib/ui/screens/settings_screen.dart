import 'package:flutter/material.dart';

import '../../main.dart';

/// App settings screen — Slack webhook URL, update preferences.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _webhookController = TextEditingController();
  bool _testingWebhook = false;
  bool _checkUpdates = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await settingsDao.getSettings();
    _webhookController.text = settings.slackWebhookUrl;
    setState(() => _checkUpdates = settings.checkUpdatesOnLaunch);
  }

  @override
  void dispose() {
    _webhookController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Slack Notifications',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _webhookController,
              decoration: const InputDecoration(
                labelText: 'Webhook URL',
                hintText: 'https://hooks.slack.com/services/...',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                settingsDao.setSlackWebhookUrl(value);
              },
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _testingWebhook ? null : _testWebhook,
              child: _testingWebhook
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Test Notification'),
            ),
            const SizedBox(height: 32),
            Text('App Updates',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Check for updates on launch'),
              subtitle: const Text('Prompts when a new version is available'),
              value: _checkUpdates,
              onChanged: (value) {
                setState(() => _checkUpdates = value);
                settingsDao.setCheckUpdatesOnLaunch(value);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testWebhook() async {
    setState(() => _testingWebhook = true);
    final success = await slackService.sendTestNotification();
    setState(() => _testingWebhook = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Test notification sent!'
              : 'Failed — check webhook URL'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }
}
