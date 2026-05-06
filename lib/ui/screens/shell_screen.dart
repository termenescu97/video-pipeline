import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../main.dart';
import 'create_job_screen.dart';
import 'job_detail_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// Master-detail shell: queue list on the left, detail/create on the right.
/// Provides keyboard shortcuts for common actions.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with TrayListener {
  int? _selectedJobId;
  bool _showCreateJob = false;

  @override
  void initState() {
    super.initState();
    _initSystemTray();
    trayManager.addListener(this);
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initSystemTray() async {
    if (!Platform.isWindows) return;
    try {
      await trayManager.setIcon('windows/runner/resources/icon-face.png');
      await trayManager.setToolTip('Video Pipeline — Idle');
      await trayManager.setContextMenu(
        Menu(items: [
          MenuItem(key: 'show', label: 'Show'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit'),
        ]),
      );
    } catch (_) {
      // System tray not available — degrade gracefully.
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      // Bring window to front — handled by window_manager if needed.
    }
    if (menuItem.key == 'quit') {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const _CreateJobIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _ToggleQueueIntent(),
      },
      child: Actions(
        actions: {
          _CreateJobIntent: CallbackAction<_CreateJobIntent>(
            onInvoke: (_) {
              setState(() {
                _selectedJobId = null;
                _showCreateJob = true;
              });
              return null;
            },
          ),
          _ToggleQueueIntent: CallbackAction<_ToggleQueueIntent>(
            onInvoke: (_) {
              if (jobQueueService.isProcessing) {
                jobQueueService.stopProcessing();
              } else {
                jobQueueService.startProcessing();
              }
              setState(() {});
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Video Pipeline'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            ),
            body: Row(
              children: [
                // Left panel: queue list.
                SizedBox(
                  width: 360,
                  child: HomeScreen(
                    onJobSelected: (jobId) {
                      setState(() {
                        _selectedJobId = jobId;
                        _showCreateJob = false;
                      });
                    },
                    onCreateJob: () {
                      setState(() {
                        _selectedJobId = null;
                        _showCreateJob = true;
                      });
                    },
                  ),
                ),
                const VerticalDivider(width: 1),
                // Right panel: detail or create.
                Expanded(
                  child: _buildRightPanel(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    if (_showCreateJob) {
      return CreateJobScreen(
        onJobCreated: () {
          setState(() => _showCreateJob = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Job added to queue. Press Start to begin processing'),
            ),
          );
        },
      );
    }

    if (_selectedJobId != null) {
      return JobDetailScreen(
        key: ValueKey(_selectedJobId),
        jobId: _selectedJobId!,
      );
    }

    // Empty state.
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app, size: 48, color: Colors.grey),
          SizedBox(height: 16),
          Text('Select a job or create a new one',
              style: TextStyle(color: Colors.grey)),
          SizedBox(height: 8),
          Text('Ctrl+N: New Job  |  Ctrl+Enter: Start/Stop Queue',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }
}

class _CreateJobIntent extends Intent {
  const _CreateJobIntent();
}

class _ToggleQueueIntent extends Intent {
  const _ToggleQueueIntent();
}
