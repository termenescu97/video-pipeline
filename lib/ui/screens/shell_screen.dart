import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../main.dart';
import '../../services/drive_service.dart';
import '../widgets/activity_panel.dart';
import '../widgets/sources_panel.dart';
import '../widgets/status_bar.dart';
import 'create_job_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// Master-detail shell: queue list on the left, detail/create on the right.
/// Provides keyboard shortcuts for common actions.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen>
    with TrayListener, WindowListener {
  bool _showCreateJob = false;
  bool _shuttingDown = false;
  // When the operator picks a drive from SourcesPanel, hand it to
  // CreateJobScreen via this transient. Cleared when CreateJobScreen
  // dismisses or another panel state takes over.
  DetectedDrive? _preSelectedDrive;

  @override
  void initState() {
    super.initState();
    _initSystemTray();
    trayManager.addListener(this);
    // Intercept window close so we can stop the queue and persist state
    // before the OS terminates the process.
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Re-entry guard: window_manager can fire the event again while we are
    // mid-shutdown.
    if (_shuttingDown) return;
    await _gracefulShutdown();
    await windowManager.destroy();
  }

  Future<void> _initSystemTray() async {
    if (!Platform.isWindows) return;
    try {
      // Resolve icon path relative to the executable.
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      await trayManager.setIcon('$exeDir/data/flutter_assets/assets/video-pipeline-icon.ico');
      await trayManager.setToolTip('Copiatorul3000 — Idle');
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
      _gracefulShutdownAndExit();
    }
  }

  /// Graceful shutdown for tray quit. Performs the same shutdown sequence
  /// as window close, then explicitly calls [exit] (tray quit doesn't go
  /// through the window close path).
  Future<void> _gracefulShutdownAndExit() async {
    if (_shuttingDown) return;
    await _gracefulShutdown();
    exit(0);
  }

  /// Stop the queue, await state persistence, then close log/lock/DB.
  /// Wrapped in a 30-second outer safety timeout so a stuck subprocess
  /// can't keep the app alive indefinitely.
  Future<void> _gracefulShutdown() async {
    _shuttingDown = true;
    try {
      await Future(() async {
        // Wait for the queue to actually stop. No timeout here — state
        // persistence MUST complete to prevent DB corruption.
        await jobQueueService.stopProcessing();
        logService.info('App closed');
        await logService.close();
        await instanceLock.release();
        await database.close();
      }).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          // Last-resort: shutdown sequence stuck. Close what we can and
          // proceed; the OS will reap any remaining handles on exit.
          stderr.writeln(
            '[shutdown] Timed out after 30s — forcing close.',
          );
        },
      );
    } catch (e) {
      stderr.writeln('[shutdown] Error during shutdown: $e');
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
            appBar: StatusBar(
              onSettings: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              // Cheat sheet wired in US11 (T091).
            ),
            // Three-column layout (FR-001). Sources column at 240px on
            // the left, Queue+Detail in the flexible center, Activity
            // column at 300px on the right. Min window 1280×720 ensures
            // there's always enough space for the center to host both
            // the queue list and an inline detail/create pane side by
            // side without responsive collapse (R1 / FR-002).
            body: Row(
              children: [
                // Left column — Sources (FR-020/021/022/023).
                SizedBox(
                  width: 240,
                  child: SourcesPanel(
                    onSourceSelected: (drive) {
                      setState(() {
                        _showCreateJob = true;
                        _preSelectedDrive = drive;
                      });
                    },
                  ),
                ),
                const VerticalDivider(width: 1),
                // Center column — Queue + Detail. The queue list stays
                // visible at all times; selecting a job or opening Create
                // Job replaces only the right side of the flexible
                // center, never the queue. Phase F (US5 T055) replaces
                // _buildRightPanel with inline DetailTabs expansion.
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 360,
                        child: HomeScreen(
                          // onJobSelected kept as a no-op signal so
                          // HomeScreen still treats itself as embedded.
                          // Inline expansion is local to HomeScreen now;
                          // no shell navigation occurs on card tap (US5).
                          onJobSelected: (_) {},
                          onCreateJob: () {
                            setState(() {
                              _showCreateJob = true;
                              _preSelectedDrive = null;
                            });
                          },
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: _buildRightPanel()),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                // Right column — Activity (FR-031/032). History rows
                // expand inline within this column (US5 T054); no
                // navigation away to a detail screen.
                const SizedBox(
                  width: 300,
                  child: ActivityPanel(),
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
        preSelectedDrive: _preSelectedDrive,
        onJobCreated: () {
          setState(() {
            _showCreateJob = false;
            _preSelectedDrive = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Job added to queue. Press Start to begin processing'),
            ),
          );
        },
      );
    }

    // Empty state. Job detail now expands inline within the queue
    // panel (US5); JobDetailScreen is retained as a route for
    // backwards compat (deep-links / programmatic navigation) but
    // is no longer surfaced from the shell by default (T048).
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app, size: 48, color: Colors.grey),
          SizedBox(height: 16),
          Text('Click a job in the queue to expand its detail',
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
