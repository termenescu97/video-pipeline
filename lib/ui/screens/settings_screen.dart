import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
  final _operatorController = TextEditingController();
  Timer? _debounceTimer;
  bool _testingWebhook = false;
  bool _checkUpdates = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await settingsDao.getSettings();
    _webhookController.text = settings?.slackWebhookUrl ?? '';
    _operatorController.text = settings?.operatorName ?? '';
    setState(() => _checkUpdates = settings?.checkUpdatesOnLaunch ?? true);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _webhookController.dispose();
    _operatorController.dispose();
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
                _debounceTimer?.cancel();
                _debounceTimer = Timer(
                  const Duration(milliseconds: 500),
                  () => settingsDao.setSlackWebhookUrl(value),
                );
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
            Text('Operator',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _operatorController,
              decoration: const InputDecoration(
                labelText: 'Operator Name',
                hintText: 'Your name (shown in Slack and job history)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                _debounceTimer?.cancel();
                _debounceTimer = Timer(
                  const Duration(milliseconds: 500),
                  () => settingsDao.setOperatorName(value),
                );
              },
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
            if (Platform.isWindows) ...[
              const SizedBox(height: 32),
              Text('Testing',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _prepTestCards,
                child: const Text('Prep Test Cards'),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Copy test video files to all inserted SD cards',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _prepTestCards() async {
    // Detect drives.
    final drives = await driveService.getRemovableDrives();
    if (drives.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No removable drives detected')),
        );
      }
      return;
    }

    // Pick source folder.
    final sourceFolder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder with test video files',
    );
    if (sourceFolder == null) return;

    // Run prep.
    final result = await driveService.prepTestCards(sourceFolder, drives);

    if (!mounted) return;

    if (result.filesCopied == 0 && result.errors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No video files (.MOV, .MP4) found in the selected folder'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Show results.
    final filesPerCard = drives.isNotEmpty && result.cardsPrepped > 0
        ? result.filesCopied ~/ result.cardsPrepped
        : 0;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Test Cards Prepped'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Prepped ${result.cardsPrepped} card(s) with $filesPerCard test file(s) each.'),
            Text('Total files copied: ${result.filesCopied}'),
            if (result.errors.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Errors:', style: TextStyle(color: Colors.red)),
              ...result.errors.map((e) => Text('• $e',
                  style: const TextStyle(fontSize: 12, color: Colors.red))),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
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
