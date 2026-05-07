import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/job_queue_service.dart';
import '../../services/queue_state_notifier.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'queue_summary_composer.dart';

/// Top status bar — replaces the bare AppBar. Surfaces queue state at-a-glance
/// (FR-003) with a single colored dot, summary text, operator name, and
/// affordances for settings + the keyboard cheat sheet.
///
/// State-dot precedence (FR-003a, worst wins):
///   red (any failed) > orange (Slack/HandBrake missing) > blue (running)
///                    > green (recent done <5min) > grey (idle)
class StatusBar extends StatefulWidget implements PreferredSizeWidget {
  final VoidCallback? onSettings;
  final VoidCallback? onCheatSheet;

  const StatusBar({super.key, this.onSettings, this.onCheatSheet});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  Timer? _greenDotTimer;
  bool _recentlyDone = false;
  bool _wasRunning = false;
  bool _handbrakeInstalled = true;
  StreamSubscription<QueueStateEvent>? _notifierSub;

  // Tray tooltip throttling (1 Hz).
  String? _lastTooltip;
  DateTime _lastTooltipPushAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    // Subscribe to QueueStateNotifier so any caller (including HomeScreen
    // celebration card in US6) can fire dismissedByUser to clear the green
    // dot synchronously across the UI.
    _notifierSub = queueStateNotifier.events.listen((event) {
      if (!mounted) return;
      switch (event) {
        case QueueStateEvent.allDone:
          _startGreenDotTimer();
          break;
        case QueueStateEvent.runningStarted:
        case QueueStateEvent.dismissedByUser:
          _clearGreenDot();
          break;
      }
    });

    _detectHandbrake();
  }

  Future<void> _detectHandbrake() async {
    final ok = await compressionService.isHandbrakeInstalled();
    if (mounted) setState(() => _handbrakeInstalled = ok);
  }

  void _startGreenDotTimer() {
    _greenDotTimer?.cancel();
    setState(() => _recentlyDone = true);
    _greenDotTimer = Timer(const Duration(minutes: 5), () {
      if (mounted) setState(() => _recentlyDone = false);
    });
  }

  void _clearGreenDot() {
    _greenDotTimer?.cancel();
    _greenDotTimer = null;
    if (_recentlyDone && mounted) {
      setState(() => _recentlyDone = false);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _greenDotTimer?.cancel();
    _notifierSub?.cancel();
    super.dispose();
  }

  void _maybePushTrayTooltip(String summary) {
    if (!Platform.isWindows) return;
    final now = DateTime.now();
    if (summary == _lastTooltip) return;
    if (now.difference(_lastTooltipPushAt) < const Duration(seconds: 1)) return;
    _lastTooltip = summary;
    _lastTooltipPushAt = now;
    // Fire-and-forget; tray failures must not propagate.
    trayManager.setToolTip('Copiatorul3000 — $summary').catchError((_) {});
  }

  /// Derive the queue-all-done event from our own state transitions, since
  /// no other component fires `notifyQueueAllDone` yet (HomeScreen wires its
  /// celebration in US6). When transitioning running → idle with no failures,
  /// emit on the notifier so future subscribers see the same event.
  void _maybeEmitAllDone({required bool isRunning, required int failedCount}) {
    if (_wasRunning && !isRunning && failedCount == 0) {
      // Schedule outside build to avoid emitting during a frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) queueStateNotifier.notifyQueueAllDone();
      });
    }
    _wasRunning = isRunning;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;

    return Material(
      color: scheme.surface,
      elevation: 0,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: Insets.l),
        child: StreamBuilder<List<Job>>(
          stream: jobDao.watchAllJobs(),
          builder: (context, jobsSnapshot) {
            final jobs = jobsSnapshot.data ?? const <Job>[];
            return StreamBuilder<AppSetting?>(
              stream: settingsDao.watchSettings(),
              builder: (context, settingsSnapshot) {
                final settings = settingsSnapshot.data;
                final operatorName = settings?.operatorName ?? '';
                final slackConfigured =
                    (settings?.slackWebhookUrl ?? '').isNotEmpty;

                return ValueListenableBuilder<ProgressData?>(
                  valueListenable: jobQueueService.progressNotifier,
                  builder: (context, progress, _) {
                    final failedCount = jobs
                        .where((j) => j.status == JobStatus.failed)
                        .length;
                    final isRunning = jobs
                        .any((j) => j.status == JobStatus.inProgress);

                    // Run derivation side-effects (post-frame).
                    _maybeEmitAllDone(
                      isRunning: isRunning,
                      failedCount: failedCount,
                    );

                    final completionEta = progress?.eta != null
                        ? DateTime.now().add(progress!.eta!)
                        : null;

                    final summary = QueueSummaryComposer.compose(
                      jobs: jobs,
                      slackConfigured: slackConfigured,
                      handbrakeInstalled: _handbrakeInstalled,
                      recentlyDone: _recentlyDone,
                      completionEta: completionEta,
                    );

                    final dotState = _resolveDotState(
                      failedCount: failedCount,
                      isRunning: isRunning,
                      slackConfigured: slackConfigured,
                      handbrakeInstalled: _handbrakeInstalled,
                      recentlyDone: _recentlyDone,
                    );

                    // Throttled tray tooltip mirror (FR-004).
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _maybePushTrayTooltip(summary);
                    });

                    return Row(
                      children: [
                        Image.asset(
                          'assets/video-pipeline-icon.ico',
                          width: 24,
                          height: 24,
                          errorBuilder: (_, e, s) => Icon(
                            Icons.copy_all,
                            size: 20,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: Insets.s),
                        Text(
                          'Copiatorul3000',
                          style: AppTextStyles.title,
                        ),
                        const SizedBox(width: Insets.xl),
                        _StateDot(
                          color: _dotColor(dotState, statusColors),
                          pulseController: _pulseController,
                          shouldPulse: _shouldPulse(dotState),
                        ),
                        const SizedBox(width: Insets.s),
                        Expanded(
                          child: Text(
                            summary,
                            style: AppTextStyles.body,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (operatorName.isNotEmpty) ...[
                          Icon(Icons.person_outline,
                              size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: Insets.xs),
                          Text(
                            operatorName,
                            style: AppTextStyles.caption.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: Insets.m),
                        ],
                        IconButton(
                          tooltip: 'Settings',
                          icon: const Icon(Icons.settings, size: 20),
                          onPressed: widget.onSettings,
                        ),
                        IconButton(
                          tooltip: 'Keyboard shortcuts',
                          icon: const Icon(Icons.help_outline, size: 20),
                          onPressed: widget.onCheatSheet,
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  _DotState _resolveDotState({
    required int failedCount,
    required bool isRunning,
    required bool slackConfigured,
    required bool handbrakeInstalled,
    required bool recentlyDone,
  }) {
    if (failedCount > 0) return _DotState.attention;
    if (!slackConfigured || !handbrakeInstalled) return _DotState.warning;
    if (isRunning) return _DotState.active;
    if (recentlyDone) return _DotState.recentDone;
    return _DotState.idle;
  }

  Color _dotColor(_DotState state, StatusColors colors) {
    switch (state) {
      case _DotState.attention:
        return colors.dotAttention;
      case _DotState.warning:
        return colors.dotWarning;
      case _DotState.active:
        return colors.dotActive;
      case _DotState.recentDone:
        return colors.dotRecentDone;
      case _DotState.idle:
        return colors.dotIdle;
    }
  }

  bool _shouldPulse(_DotState state) {
    switch (state) {
      case _DotState.active:
      case _DotState.warning:
      case _DotState.attention:
        return true;
      case _DotState.recentDone:
      case _DotState.idle:
        return false;
    }
  }
}

enum _DotState { idle, active, recentDone, attention, warning }

class _StateDot extends StatelessWidget {
  final Color color;
  final AnimationController pulseController;
  final bool shouldPulse;

  const _StateDot({
    required this.color,
    required this.pulseController,
    required this.shouldPulse,
  });

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );

    if (!shouldPulse) return dot;

    return AnimatedBuilder(
      animation: pulseController,
      builder: (_, child) {
        final t = pulseController.value;
        return Opacity(opacity: 0.55 + 0.45 * t, child: dot);
      },
    );
  }
}
