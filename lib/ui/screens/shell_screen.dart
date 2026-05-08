import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../utils/history_export.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import '../widgets/activity_panel.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/copy_all_cards_dialog.dart';
import '../widgets/keyboard_cheat_sheet.dart';
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

  /// Shared expansion state. Lifted to the shell so a job whose card
  /// migrates between panels (queued → completed → moves to Activity)
  /// keeps its expansion state — fixes a Principle V regression Codex
  /// flagged in the Phase 7 review. Both HomeScreen and ActivityPanel
  /// read from / write to the same set.
  final Set<int> _expandedJobIds = <int>{};

  /// US11 (T085): keyboard-focus selection in the queue. Drives ↑/↓
  /// navigation and Space/Delete/Ctrl+R actions. Stored as a job ID
  /// (not an index) so the selection survives reorders.
  int? _selectedQueueJobId;

  /// Shell-side mirror of the queue list, used by selection-cycling
  /// shortcuts (↑/↓) and selection-target shortcuts (Space/Delete/
  /// Ctrl+R). HomeScreen has its own StreamBuilder for rendering;
  /// shell needs the same data to compute "next/prev card" without
  /// drilling through HomeScreen's build. Drift caches the underlying
  /// query so the duplicate subscription is cheap.
  List<Job> _activeJobsForSelection = const <Job>[];
  StreamSubscription<List<Job>>? _activeJobsSub;

  void _toggleExpanded(int jobId) {
    setState(() {
      if (!_expandedJobIds.add(jobId)) {
        _expandedJobIds.remove(jobId);
      }
    });
  }

  void _onJobDeleted(int jobId) {
    if (_expandedJobIds.remove(jobId)) {
      // Removed from expansion set on delete — prevents the set from
      // growing unbounded over the app's lifetime.
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _initSystemTray();
    trayManager.addListener(this);
    // Intercept window close so we can stop the queue and persist state
    // before the OS terminates the process.
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    // US11 (T085): subscribe to active jobs for selection cycling.
    _activeJobsSub = jobDao.watchAllJobs().listen((jobs) {
      final filtered = jobs
          .where((j) => j.status != JobStatus.completed)
          .toList();
      // Drop selection if the selected job no longer exists or moved
      // out of the queue (e.g., transitioned to completed).
      if (_selectedQueueJobId != null &&
          !filtered.any((j) => j.id == _selectedQueueJobId)) {
        _selectedQueueJobId = null;
      }
      if (mounted) {
        setState(() => _activeJobsForSelection = filtered);
      }
    });
  }

  @override
  void dispose() {
    _activeJobsSub?.cancel();
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

  /// Phased graceful shutdown (feature 016).
  ///
  /// Replaces the v2.4.0 single-30s-timeout-around-everything pattern,
  /// which would skip cleanup entirely if `stopProcessing` blocked on a
  /// subprocess that wouldn't die (kernel-pinned I/O, stuck network
  /// share). The phased structure splits shutdown into:
  ///
  ///   - Phase A: signal stop + send subprocess kill (non-blocking).
  ///   - Phase B: bounded 10 s wait for the queue drain. On timeout,
  ///     mark the queue abandoned so any late writes from the loop
  ///     short-circuit cleanly via JobQueueService._safeWrite instead
  ///     of throwing into a closed DB.
  ///   - Phase C: independent cleanup steps with per-step timeouts.
  ///     ALWAYS run regardless of Phase B outcome. Order: DB close
  ///     (5 s) → lock release → log close (2 s). Each timeout-bounded
  ///     so a hung step can't starve the rest.
  ///
  /// `recoverStaleJobs` on the next launch picks up any inProgress
  /// rows whose post-cancel `resetFileToPending` was abandoned.
  Future<void> _gracefulShutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;

    // Phase A — signal stop + send subprocess kill (non-blocking).
    final drain = jobQueueService.stopProcessing();

    // Phase B — bounded wait for queue drain. 10 s is generous for
    // normal cancellation (the loop's last DB writes are millisecond-
    // scale) and short enough that the operator's window-close gesture
    // feels responsive when a subprocess is actually stuck.
    try {
      await drain.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      jobQueueService.markShutdownAbandoned();
      stderr.writeln(
        '[shutdown] Queue drain timed out after 10s — abandoning '
        'drain and proceeding to cleanup. recoverStaleJobs handles '
        'stale rows on next launch.',
      );
      logService.warning(
        'Shutdown drain timed out — drain Future may resolve later '
        'but will write against a closed DB; markShutdownAbandoned '
        'was called to short-circuit. recoverStaleJobs on next '
        'launch picks up any inProgress rows.',
      );
    } catch (e, st) {
      jobQueueService.markShutdownAbandoned();
      stderr.writeln('[shutdown] Drain wait threw: $e');
      logService.error(
        'Shutdown drain threw: $e\n'
        '${st.toString().split("\n").take(3).join("\n")}',
      );
    }

    // Phase C — independent cleanup steps. Each guarded so a failure
    // in one does NOT skip the rest. Order: DB close FIRST (load-
    // bearing for data integrity), lock release SECOND, log close
    // LAST (best-effort).
    //
    // 5 s timeout on database.close() — Codex review fix (MEDIUM):
    // without a timeout, a hung close would block lock release and
    // log close indefinitely, defeating the v2 reorder's intent.
    // Drift's close awaits in-flight statements, which under normal
    // conditions resolves in milliseconds; 5 s is generous for a
    // genuine kernel-level disk hang.
    try {
      await database.close().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      stderr.writeln('[shutdown] database.close timed out after 5s');
    } catch (e) {
      stderr.writeln('[shutdown] database.close failed: $e');
    }
    try {
      await instanceLock.release();
    } catch (e) {
      stderr.writeln('[shutdown] instanceLock.release failed: $e');
    }
    try {
      logService.info('App closed');
      // 2 s timeout on log close. The DB is already closed by this
      // point, so even if log close hangs we don't lose data
      // integrity — just a final log line.
      await logService.close().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      stderr.writeln('[shutdown] logService.close timed out after 2s');
    } catch (e) {
      stderr.writeln('[shutdown] logService.close failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      // US11 (T086): full shortcut map. Flutter's Shortcuts widget
      // automatically scopes — text input fields (TextField, TextFormField)
      // intercept printable keys before they reach this map, so typing
      // "?" in the operator-name field inserts the character rather
      // than opening the cheat sheet (FR-049 / T099).
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const _CreateJobIntent(),
        const SingleActivator(LogicalKeyboardKey.keyC,
                control: true, shift: true):
            const _CopyAllCardsIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _ToggleQueueIntent(),
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            const _OpenSettingsIntent(),
        // CharacterActivator binds the produced character (not the
        // physical key), so `?` works on any keyboard layout —
        // US (shift+/), AZERTY (shift+,), German (shift+ß), etc.
        // F1 is the layout-independent fallback (Codex Phase 13 WARN).
        const CharacterActivator('?'): const _OpenCheatSheetIntent(),
        const SingleActivator(LogicalKeyboardKey.f1):
            const _OpenCheatSheetIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const _SelectPrevIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const _SelectNextIntent(),
        const SingleActivator(LogicalKeyboardKey.space):
            const _ToggleExpandIntent(),
        // T102: Delete keyboard shortcut restored behind T101's
        // typed-confirmation gate. Operator must type "delete" to
        // proceed — same gate as right-click → Delete (Constitution
        // Principle I, FR-047).
        const SingleActivator(LogicalKeyboardKey.delete):
            const _DeleteSelectedIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _RetrySelectedIntent(),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true):
            const _RevealLogIntent(),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            const _ExportCsvIntent(),
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
          _CopyAllCardsIntent: CallbackAction<_CopyAllCardsIntent>(
            onInvoke: (_) => _onCopyAllCards(),
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
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) => _openSettings(),
          ),
          _OpenCheatSheetIntent: CallbackAction<_OpenCheatSheetIntent>(
            onInvoke: (_) => KeyboardCheatSheet.show(context),
          ),
          _SelectPrevIntent: CallbackAction<_SelectPrevIntent>(
            onInvoke: (_) => _moveSelection(-1),
          ),
          _SelectNextIntent: CallbackAction<_SelectNextIntent>(
            onInvoke: (_) => _moveSelection(1),
          ),
          _ToggleExpandIntent: CallbackAction<_ToggleExpandIntent>(
            onInvoke: (_) {
              final id = _selectedQueueJobId;
              if (id != null) _toggleExpanded(id);
              return null;
            },
          ),
          _DeleteSelectedIntent: CallbackAction<_DeleteSelectedIntent>(
            onInvoke: (_) => _deleteSelected(),
          ),
          _RetrySelectedIntent: CallbackAction<_RetrySelectedIntent>(
            onInvoke: (_) => _retrySelected(),
          ),
          _RevealLogIntent: CallbackAction<_RevealLogIntent>(
            onInvoke: (_) => _revealLogFile(),
          ),
          _ExportCsvIntent: CallbackAction<_ExportCsvIntent>(
            onInvoke: (_) {
              exportHistoryToCsv(context);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: StatusBar(
              onSettings: _openSettings,
              onCheatSheet: () => KeyboardCheatSheet.show(context),
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
                          expandedJobIds: _expandedJobIds,
                          onToggleExpanded: _toggleExpanded,
                          onJobDeleted: _onJobDeleted,
                          selectedQueueJobId: _selectedQueueJobId,
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
                SizedBox(
                  width: 300,
                  child: ActivityPanel(
                    expandedJobIds: _expandedJobIds,
                    onToggleExpanded: _toggleExpanded,
                    onJobDeleted: _onJobDeleted,
                  ),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.touch_app, size: 48, color: Colors.grey),
          const SizedBox(height: Insets.l),
          const Text('Click a job in the queue to expand its detail',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: Insets.s),
          Text('Ctrl+N: New Job  |  Ctrl+Enter: Start/Stop Queue',
              style: AppTextStyles.caption.copyWith(color: Colors.grey)),
        ],
      ),
    );
  }

  // ── US11 shortcut helpers (T085-T097) ─────────────────────────
  // Inlined here because `setState` is @protected and unreachable
  // from a top-level extension on the State class.

  /// Open Settings — shared between Ctrl+, shortcut and StatusBar cog.
  Object? _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    return null;
  }

  /// Open the Copy All Cards review dialog (T088). Same modal
  /// HomeScreen's "Copy All" button uses — single source of truth.
  Object? _onCopyAllCards() {
    // Fire and forget — the dialog manages its own lifecycle.
    // ignore: discarded_futures
    CopyAllCardsDialog.show(context);
    return null;
  }

  /// Cycle the selected queue job by [delta] (-1 prev, +1 next).
  /// Wraps at the ends — pressing ↓ on the last card stays on the
  /// last card; pressing ↑ on the first stays on the first. (Wrap-
  /// around would surprise an operator deep in a long queue.)
  Object? _moveSelection(int delta) {
    if (_activeJobsForSelection.isEmpty) return null;
    final jobs = _activeJobsForSelection;
    int idx;
    if (_selectedQueueJobId == null) {
      idx = delta > 0 ? 0 : jobs.length - 1;
    } else {
      final current =
          jobs.indexWhere((j) => j.id == _selectedQueueJobId);
      if (current < 0) {
        idx = delta > 0 ? 0 : jobs.length - 1;
      } else {
        idx = (current + delta).clamp(0, jobs.length - 1);
      }
    }
    setState(() => _selectedQueueJobId = jobs[idx].id);
    return null;
  }

  /// Delete shortcut (T094 / T102): typed-confirm and delete the
  /// selected job. Active (in-progress) jobs are protected. Routes
  /// through the SAME [ConfirmationDialog.showDestructive] path as
  /// right-click → Delete and ActivityPanel delete — single typed
  /// gate across all destructive entry points (FR-047).
  Future<Object?> _deleteSelected() async {
    final id = _selectedQueueJobId;
    if (id == null) return null;
    final job = _activeJobsForSelection
        .firstWhere((j) => j.id == id, orElse: () => _NoJob.value);
    if (job == _NoJob.value) return null;
    if (job.status == JobStatus.inProgress) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Cannot delete the running job')),
      );
      return null;
    }
    final confirmed = await ConfirmationDialog.showDestructive(
      context: context,
      title: 'Remove Job',
      message: 'Remove this job from the queue?\n\n'
          '${job.sourcePath} → ${job.destinationPath}',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return null;
    jobDao.markRecoveryAcknowledged(job.id);
    await jobDao.deleteJob(job.id);
    _onJobDeleted(job.id);
    if (_selectedQueueJobId == job.id) {
      setState(() => _selectedQueueJobId = null);
    }
    return null;
  }

  /// Retry shortcut: only acts on the selected job if it's in
  /// `failed` state. Silent no-op otherwise — the cheat sheet
  /// describes it as "Retry selected failed job", so the operator
  /// knows the precondition.
  Future<Object?> _retrySelected() async {
    final id = _selectedQueueJobId;
    if (id == null) return null;
    final job = _activeJobsForSelection
        .firstWhere((j) => j.id == id, orElse: () => _NoJob.value);
    if (job == _NoJob.value || job.status != JobStatus.failed) {
      return null;
    }
    await jobDao.resetJobForRetry(job.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job re-queued for retry')),
      );
    }
    return null;
  }

  /// Reveal the persistent log file in Explorer (Ctrl+L). Mirrors
  /// the Settings → Diagnostics "Reveal in Explorer" button so
  /// operators have two paths to the same file.
  Future<Object?> _revealLogFile() async {
    final path = logService.logPath;
    if (path.isEmpty) return null;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reveal log file: $e')),
        );
      }
    }
    return null;
  }

}

/// Sentinel "no job" Job used by selection helpers' orElse — avoids
/// a nullable return when the selected ID isn't in the active list
/// (race between Stream tick and intent fire). Comparison is by
/// identity (`==` falls through to default).
class _NoJob {
  static final Job value = Job(
    id: -1,
    type: JobType.transfer,
    status: JobStatus.completed,
    sourcePath: '',
    destinationPath: '',
    totalFiles: 0,
    completedFiles: 0,
    totalBytes: 0,
    completedBytes: 0,
    sortOrder: 0,
    autoChain: false,
    verificationMode: VerificationMode.size,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

class _CreateJobIntent extends Intent {
  const _CreateJobIntent();
}

class _CopyAllCardsIntent extends Intent {
  const _CopyAllCardsIntent();
}

class _ToggleQueueIntent extends Intent {
  const _ToggleQueueIntent();
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _OpenCheatSheetIntent extends Intent {
  const _OpenCheatSheetIntent();
}

class _SelectPrevIntent extends Intent {
  const _SelectPrevIntent();
}

class _SelectNextIntent extends Intent {
  const _SelectNextIntent();
}

class _ToggleExpandIntent extends Intent {
  const _ToggleExpandIntent();
}

class _DeleteSelectedIntent extends Intent {
  const _DeleteSelectedIntent();
}

class _RetrySelectedIntent extends Intent {
  const _RetrySelectedIntent();
}

class _RevealLogIntent extends Intent {
  const _RevealLogIntent();
}

class _ExportCsvIntent extends Intent {
  const _ExportCsvIntent();
}
