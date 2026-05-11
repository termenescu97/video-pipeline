import 'dart:async';

import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../services/queue_state_notifier.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/copy_all_cards_dialog.dart';
import '../widgets/handbrake_banner.dart';
import '../widgets/history_surface.dart';
import '../widgets/job_card.dart';
import '../widgets/job_card_completed.dart';
import '../widgets/skeleton_row.dart';
import 'settings_screen.dart';

/// Queue list panel — can be used standalone or as left panel in ShellScreen.
class HomeScreen extends StatefulWidget {
  /// Shared expansion set — owned by the shell. Reading is OK; toggling
  /// goes through [onToggleExpanded] so the shell can notify all listeners.
  final Set<int>? expandedJobIds;
  final ValueChanged<int>? onToggleExpanded;

  /// Notifies the shell when a job is deleted so the expansion set can
  /// drop its ID (prevents unbounded set growth).
  final ValueChanged<int>? onJobDeleted;

  /// Callback for embedded mode (ShellScreen).
  final VoidCallback? onCreateJob;

  /// US11 (T085): the keyboard-selected job ID, owned by the shell.
  /// HomeScreen renders a focus ring on the matching card; clicks
  /// don't currently change selection (mouse-driven flow uses
  /// click-to-expand, not click-to-select). When null, no focus ring
  /// is shown.
  final int? selectedQueueJobId;

  const HomeScreen({
    super.key,
    this.expandedJobIds,
    this.onToggleExpanded,
    this.onJobDeleted,
    this.onCreateJob,
    this.selectedQueueJobId,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool get _isEmbedded => widget.onCreateJob != null;

  Set<int> get _expandedJobIds => widget.expandedJobIds ?? const <int>{};

  /// Snapshot of the just-completed jobs that drove the most recent
  /// queue → all-done transition. Populated when the queue service
  /// fires `notifyQueueAllDone`; cleared on `notifyDismissedByUser`
  /// (operator created a job, started the queue, or dismissed the
  /// celebration card explicitly). Drives the JobCardCompleted hero
  /// (T060, FR-012).
  List<Job>? _celebrationBatch;
  StreamSubscription<QueueStateEvent>? _queueStateSub;
  Timer? _celebrationDismissTimer;

  /// Wall-clock time when the most recent run transitioned from idle
  /// to running. Captured on `runningStarted`, used at `allDone` to
  /// pick out the jobs that completed during this run. Replaces the
  /// previous fixed 60s window which silently dropped jobs that
  /// completed early in long batches (Codex Phase 8 review).
  DateTime? _runStartTime;

  /// Monotonic counter incremented on every event that should
  /// invalidate any in-flight celebration query. Without it, an
  /// `allDone` async could resolve and resurrect a dismissed
  /// celebration card after the operator clicked "Dismiss" or
  /// "New Job" (Codex Phase 8 review).
  int _celebrationGen = 0;

  /// Failed-job IDs the operator has dismissed in the current session
  /// (T066). Resets on app restart — short-lived enough that a fresh
  /// failure is always surfaced. The banner shows iff
  /// `currentFailedIds - _dismissedFailureIds` is non-empty: a NEW
  /// failure (an ID the set has never seen) un-dismisses naturally.
  /// We also prune IDs that no longer correspond to failed jobs so
  /// the set doesn't grow unbounded across retry/delete cycles.
  Set<int> _dismissedFailureIds = const <int>{};

  @override
  void initState() {
    super.initState();
    _queueStateSub = queueStateNotifier.events.listen(_handleQueueStateEvent);
  }

  @override
  void dispose() {
    _queueStateSub?.cancel();
    _celebrationDismissTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleQueueStateEvent(QueueStateEvent event) async {
    if (!mounted) return;
    switch (event) {
      case QueueStateEvent.runningStarted:
        // Stamp the run's start time and clear any stale celebration.
        _celebrationGen++;
        _celebrationDismissTimer?.cancel();
        setState(() {
          _runStartTime = DateTime.now();
          _celebrationBatch = null;
        });
        break;
      case QueueStateEvent.allDone:
        final start = _runStartTime;
        if (start == null) {
          // App started after the run was already in progress; we have
          // no anchor, so skip the celebration rather than guess.
          break;
        }
        final gen = ++_celebrationGen;
        final allCompleted = await jobDao.getCompletedJobsList();
        // Stale-async guard: if the operator dismissed (or a new run
        // started) while we were awaiting the DB, our generation no
        // longer matches and the result must be discarded.
        if (!mounted || gen != _celebrationGen) return;
        final batch = allCompleted
            .where((j) =>
                j.status == JobStatus.completed &&
                j.completedAt != null &&
                !j.completedAt!.isBefore(start))
            .toList();
        if (batch.isEmpty) break;
        setState(() => _celebrationBatch = batch);
        // Auto-dismiss alongside the StatusBar green dot (5 minutes).
        _celebrationDismissTimer?.cancel();
        _celebrationDismissTimer = Timer(
          const Duration(minutes: 5),
          () {
            if (mounted) {
              _celebrationGen++;
              setState(() => _celebrationBatch = null);
            }
          },
        );
        break;
      case QueueStateEvent.dismissedByUser:
        _celebrationGen++;
        _celebrationDismissTimer?.cancel();
        if (_celebrationBatch != null) {
          setState(() => _celebrationBatch = null);
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: jobDao.watchAllJobs(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // T106: skeleton rows during the first DB query — gives a
          // sense of WHERE jobs will appear instead of a free-floating
          // spinner. Three rows matches the empirical typical batch
          // size (one per detected SD card).
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: Insets.s),
            children: List.generate(
                3, (_) => const SkeletonRow(height: 64)),
          );
        }

        final jobs = snapshot.data ?? const <Job>[];
        final failedJobs =
            jobs.where((j) => j.status == JobStatus.failed).toList();
        // T066: a job that was dismissed and then retried (or deleted)
        // must not keep its slot in the dismissed set — otherwise a
        // re-failure of the same ID would be pre-suppressed. We prune
        // for THIS frame's render via a local set, and schedule a
        // post-frame setState to persist the pruning. Direct mid-build
        // mutation would be fragile (Codex Phase 9 review NIT).
        final activeFailedIds = failedJobs.map((j) => j.id).toSet();
        final prunedDismissed =
            _dismissedFailureIds.intersection(activeFailedIds);
        if (prunedDismissed.length != _dismissedFailureIds.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _dismissedFailureIds = prunedDismissed);
            }
          });
        }
        final visibleFailures = failedJobs
            .where((j) => !prunedDismissed.contains(j.id))
            .toList();

        // Warning banners (Slack misconfigured, HandBrake missing,
        // failed-jobs banner) MUST render above both empty and
        // populated queue states. Wrap the whole body in a Column
        // so the banner slot is never hidden by an empty-state early
        // return.
        return Column(
          children: [
            _WarningBannerSlot(
              visibleFailures: visibleFailures,
              // Retry only the failures the operator can SEE in the
              // banner (Codex Phase 9 review WARN). Dismissed failures
              // are silent by operator choice — pulling them back into
              // the queue without prompting would surprise the operator
              // (Principle V: action scope must match what's visible).
              onRetryAllFailed: () => _retryAllFailed(visibleFailures),
              onDismissFailed: () => _dismissFailedBanner(visibleFailures),
            ),
            Expanded(child: _buildBody(context, jobs)),
          ],
        );
      },
    );
  }

  /// T066 dismiss: snapshot the current failed-job IDs into the
  /// dismissed set. The banner stays hidden until a NEW failure ID
  /// appears (one not in the set), at which point it returns.
  void _dismissFailedBanner(List<Job> currentFailures) {
    if (currentFailures.isEmpty) return;
    setState(() {
      _dismissedFailureIds = {
        ..._dismissedFailureIds,
        for (final j in currentFailures) j.id,
      };
    });
  }

  /// T065 retry-all: reset every supplied failed job for retry. Each
  /// reset runs in its own try/catch so a single DB hiccup doesn't
  /// abandon the rest (Codex Phase 9 review WARN — partial success
  /// must be visible to the operator, Principle V).
  ///
  /// Clears the dismiss set as a side-effect — once we've actively
  /// addressed the visible failures, there's nothing left to "stay
  /// dismissed" against. Re-failures will repopulate the banner.
  Future<void> _retryAllFailed(List<Job> failures) async {
    if (failures.isEmpty) return;
    var ok = 0;
    var failed = 0;
    for (final j in failures) {
      try {
        await jobDao.resetJobForRetry(j.id);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _dismissedFailureIds = const <int>{});
    final msg = failed == 0
        ? (ok == 1 ? '1 job re-queued for retry' : '$ok jobs re-queued for retry')
        : 'Re-queued $ok of ${failures.length} — $failed failed to reset';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Widget _buildBody(BuildContext context, List<Job> jobs) {
    // Active queue: everything except `completed`. Failed jobs stay in
    // their natural position (T065, FR-005a — banner is the surfacing
    // mechanism, not a re-sort). Completed jobs render in the
    // right-column ActivityPanel (US4).
    final activeJobs = jobs
        .where((j) => j.status != JobStatus.completed)
        .toList();

        // Compute the next-up index: first queued/paused job's index in
        // activeJobs when no job is in progress. Failed jobs are skipped
        // when picking next-up — they're surfaced by the banner, not as
        // the job to start next. -1 if no next-up exists.
        final hasInProgress =
            activeJobs.any((j) => j.status == JobStatus.inProgress);
        final nextUpIndex = hasInProgress
            ? -1
            : activeJobs.indexWhere((j) =>
                j.status == JobStatus.queued ||
                j.status == JobStatus.paused);

        if (jobs.isEmpty) {
          return StreamBuilder<AppSetting?>(
            stream: settingsDao.watchSettings(),
            builder: (context, settingsSnapshot) {
              final settings = settingsSnapshot.data;
              final firstRunDone = settings?.firstRunCompleted ?? false;

              if (!firstRunDone) {
                // First-run welcome state.
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.video_library, size: 64, color: Colors.blue),
                        const SizedBox(height: Insets.l),
                        Text('Welcome to Copiatorul3000',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: Insets.s),
                        const Text(
                          'Automate video file transfer and compression.\n'
                          'Insert an SD card and create your first job to get started.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: Insets.xl),
                        FilledButton.icon(
                          onPressed: () {
                            settingsDao.setFirstRunCompleted(true);
                            _onCreateJob();
                          },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Get Started'),
                        ),
                        const SizedBox(height: Insets.s),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const SettingsScreen()));
                          },
                          icon: const Icon(Icons.settings),
                          label: const Text('Configure Slack'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Normal empty state. If removable drives are present, hero
              // the "Copy All Cards" CTA (FR-048); otherwise fall back to
              // the standard "Create Job" affordance.
              return FutureBuilder<List<DetectedDrive>>(
                future: driveService.getRemovableDrives(),
                builder: (context, drivesSnapshot) {
                  final drives = drivesSnapshot.data ?? const <DetectedDrive>[];
                  if (drives.isNotEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.sd_storage,
                                size: 56, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(height: Insets.l),
                            Text(
                              '${drives.length} card${drives.length == 1 ? '' : 's'} detected',
                              style: Theme.of(context).textTheme.headlineSmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: Insets.xl),
                            FilledButton.icon(
                              onPressed: _batchCopyAllCards,
                              icon: const Icon(Icons.sd_storage),
                              label: const Text('Copy All Cards'),
                            ),
                            const SizedBox(height: Insets.s),
                            TextButton.icon(
                              onPressed: _onCreateJob,
                              icon: const Icon(Icons.add),
                              label: const Text('Create Job…'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.queue, size: 48, color: Colors.grey),
                        const SizedBox(height: Insets.l),
                        const Text('No jobs in queue'),
                        const SizedBox(height: Insets.s),
                        FilledButton.icon(
                          onPressed: _onCreateJob,
                          icon: const Icon(Icons.add),
                          label: const Text('Create Job'),
                        ),
                        const SizedBox(height: Insets.s),
                        OutlinedButton.icon(
                          onPressed: _batchCopyAllCards,
                          icon: const Icon(Icons.sd_storage),
                          label: const Text('Copy All Cards'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        }

        final isProcessing = jobQueueService.isProcessing;

        return Column(
          children: [
            // Banner slot is rendered by the outer build() wrapper; this
            // inner column starts directly with the queue controls.
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _toggleProcessing,
                      icon: Icon(
                          isProcessing ? Icons.stop : Icons.play_arrow,
                          size: 18),
                      label: Text(
                          isProcessing ? 'Stop' : 'Start',
                          style: AppTextStyles.body),
                      style: isProcessing
                          ? FilledButton.styleFrom(
                              backgroundColor: Theme.of(context).extension<StatusColors>()!.error)
                          : null,
                    ),
                  ),
                  const SizedBox(width: Insets.s),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _batchCopyAllCards,
                      icon: const Icon(Icons.sd_storage, size: 18),
                      label: const Text('Copy All',
                          style: AppTextStyles.body),
                    ),
                  ),
                  const SizedBox(width: Insets.s),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'New Job',
                    onPressed: _onCreateJob,
                  ),
                ],
              ),
            ),
            // Active jobs (reorderable).
            Expanded(
              child: CustomScrollView(
                slivers: [
                  // Completion celebration (FR-012, T060). Pinned above
                  // the active jobs sliver while present so the operator
                  // sees it whether or not the queue scrolls.
                  if (_celebrationBatch != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: JobCardCompleted(
                          recentJobs: _celebrationBatch!,
                          onNewJob: _onCreateJob,
                          onDismiss: () {
                            queueStateNotifier
                                .notifyDismissedByUser();
                          },
                        ),
                      ),
                    ),
                  SliverReorderableList(
                    itemCount: activeJobs.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex--;
                      // FR-006: refuse moves that try to insert anything
                      // into the active job's slot. The active job is
                      // positionally fixed; queued/next-up/failed shuffle
                      // among themselves below it.
                      final activeIdx = activeJobs.indexWhere(
                          (j) => j.status == JobStatus.inProgress);
                      if (activeIdx != -1 && newIndex <= activeIdx) {
                        return;
                      }
                      // True insertion (not swap): build the new order
                      // locally, then persist via setJobsOrder which
                      // re-numbers sortOrder 0..n-1 in one transaction.
                      // Codex Phase 9 review caught the previous swap
                      // path producing [C,B,A] when the operator
                      // expected [C,A,B] for a 3-card top drop.
                      final newOrder = List<Job>.from(activeJobs);
                      final moved = newOrder.removeAt(oldIndex);
                      newOrder.insert(newIndex, moved);
                      jobDao.setJobsOrder(
                          newOrder.map((j) => j.id).toList());
                    },
                    itemBuilder: (context, index) {
                      final job = activeJobs[index];
                      // T062/T063: drag affordance lives ONLY on the ☰
                      // handle inside the card variants. Active is the
                      // sole positionally-fixed variant — pass null
                      // reorderIndex so it never picks up a handle. Failed
                      // routes to JobCardDone which doesn't render a
                      // handle either; we still pass a valid index so a
                      // drag onto a failed row's slot lands cleanly.
                      // T085: render a focus ring around the keyboard-
                      // selected job. The ring is the visual signal for
                      // ↑/↓ navigation; mouse clicks still expand cards
                      // via the existing onTap path.
                      final selected =
                          widget.selectedQueueJobId == job.id;
                      final scheme = Theme.of(context).colorScheme;
                      Widget card = JobCard(
                        job: job,
                        isNextUp: index == nextUpIndex,
                        isExpanded: _expandedJobIds.contains(job.id),
                        onTap: () =>
                            widget.onToggleExpanded?.call(job.id),
                        onDelete: () => _deleteJob(job),
                        onRetry: job.status == JobStatus.failed
                            ? () => _retryJob(job)
                            : null,
                        // T109 fix: card-level Start must run the same
                        // recovery-acknowledgment path as the toolbar
                        // Start, otherwise a "Recovered" chip stays on
                        // the card after the operator presses its own
                        // Start button (Codex Phase 14 review).
                        onStart: _startQueueAcknowledgingRecovery,
                        reorderIndex: job.status == JobStatus.inProgress
                            ? null
                            : index,
                      );
                      if (selected) {
                        card = Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: scheme.primary, width: 2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: card,
                        );
                      }
                      return KeyedSubtree(
                        key: ValueKey(job.id),
                        child: card,
                      );
                    },
                  ),
                  // 017B (FR-B06): cross-job history surface lives in
                  // HomeScreen now that the ActivityPanel is gone.
                  // Sliver-form embed so it scrolls together with the
                  // active queue above; the history surface owns its
                  // own search box, status filters, and CSV export.
                  // Expansion state shared with the active queue so a
                  // job that was expanded above stays expanded when it
                  // transitions to history (Codex round-8 P2 #2).
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Insets.s, Insets.l, Insets.s, Insets.s),
                      child: HistorySurface(
                        expandedJobIds: _expandedJobIds,
                        onToggleExpanded: (id) =>
                            widget.onToggleExpanded?.call(id),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
  }


  void _onCreateJob() {
    // Operator action — dismiss any active "all done" celebration so
    // the green dot + JobCardCompleted clear in sync (T060).
    queueStateNotifier.notifyDismissedByUser();
    if (_isEmbedded) {
      widget.onCreateJob!();
    }
  }

  void _toggleProcessing() {
    if (jobQueueService.isProcessing) {
      jobQueueService.stopProcessing();
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Queue stopped')),
      );
    } else {
      _startQueueAcknowledgingRecovery();
    }
  }

  /// Shared Start path used by the toolbar and the JobCardNextUp
  /// per-card Start button (Codex Phase 14 review). Pressing Start
  /// is an implicit acknowledgment of every recovered job, so we
  /// clear the in-memory recovery set BEFORE kicking off processing
  /// — that way the chip disappears on the next rebuild regardless
  /// of which Start surface the operator used.
  void _startQueueAcknowledgingRecovery() {
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Queue started')),
    );
    for (final id in jobDao.recoveredJobIds.toList()) {
      jobDao.markRecoveryAcknowledged(id);
    }
    jobQueueService.startProcessing().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _deleteJob(Job job) async {
    if (job.status == JobStatus.inProgress) return;

    final confirmed = await ConfirmationDialog.showDestructive(
      context: context,
      title: 'Remove Job',
      message: 'Remove this job from the queue?\n\n'
          '${job.sourcePath} → ${job.destinationPath}',
      confirmLabel: 'Remove',
    );

    if (confirmed) {
      // T100/T109: clear recovery chip when the operator deletes a
      // recovered job — they've explicitly acknowledged it.
      jobDao.markRecoveryAcknowledged(job.id);
      await jobDao.deleteJob(job.id);
      widget.onJobDeleted?.call(job.id);
    }
  }

  Future<void> _retryJob(Job job) async {
    // T100/T109: retry counts as acknowledgment.
    jobDao.markRecoveryAcknowledged(job.id);
    await jobDao.resetJobForRetry(job.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job re-queued for retry')),
      );
    }
  }

  Future<void> _batchCopyAllCards() async {
    await CopyAllCardsDialog.show(context);
  }
}

/// Vertical column rendering all warning banners stacked on top of the queue
/// content. Owns the banner-slot region introduced for FR-050 / US7 / US1.
///
/// Banners ship in phases:
///  - Slack-misconfigured (US1, T037): orange settings prompt.
///  - Failed-jobs (US7, T065): red [Retry all] [Dismiss] banner anchored
///    above the queue while there are non-dismissed failures (FR-011).
///  - HandBrake-missing (Polish, T108): plugs in here too.
///
/// Each banner is independent — they stack in this column in priority
/// order (most-actionable first; failed > Slack > HandBrake).
class _WarningBannerSlot extends StatelessWidget {
  final List<Job> visibleFailures;
  final VoidCallback onRetryAllFailed;
  final VoidCallback onDismissFailed;

  const _WarningBannerSlot({
    required this.visibleFailures,
    required this.onRetryAllFailed,
    required this.onDismissFailed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (visibleFailures.isNotEmpty)
          _FailedJobsBanner(
            count: visibleFailures.length,
            onRetryAll: onRetryAllFailed,
            onDismiss: onDismissFailed,
          ),
        const _SlackUnconfiguredBanner(),
        // T108: HandBrake-not-installed banner. Self-checks and
        // renders empty when HandBrake is available, so it's always
        // safe to include here.
        const HandBrakeBanner(compact: true),
      ],
    );
  }
}

/// "N failed — review" banner pinned at the top of the queue panel
/// while there are non-dismissed failed jobs (T065, FR-011).
///
/// Two actions:
///   [Retry all] — re-queues every failed job and clears the dismiss set.
///   [Dismiss]   — snapshots the current failed IDs so the banner hides
///                 until a NEW failure occurs (T066).
///
/// The banner is the surfacing mechanism — it does NOT re-sort failed
/// jobs to the top of the queue. They keep their natural position
/// (FR-005a, FR-011) so the operator's mental model of "this card was
/// after that one" survives a failure.
class _FailedJobsBanner extends StatelessWidget {
  final int count;
  final VoidCallback onRetryAll;
  final VoidCallback onDismiss;

  const _FailedJobsBanner({
    required this.count,
    required this.onRetryAll,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: statusColors.error.withValues(alpha: 0.12),
        border: Border(
          bottom:
              BorderSide(color: statusColors.error.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: statusColors.error, size: 18),
          const SizedBox(width: Insets.s),
          Expanded(
            child: Text(
              count == 1
                  ? '1 job failed — review'
                  : '$count jobs failed — review',
              style: AppTextStyles.caption.copyWith(
                color: statusColors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetryAll,
            style: TextButton.styleFrom(
              foregroundColor: statusColors.error,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Retry all', style: AppTextStyles.caption),
          ),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              foregroundColor: scheme.onSurfaceVariant,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Dismiss', style: AppTextStyles.caption),
          ),
        ],
      ),
    );
  }
}

/// Slack webhook unconfigured banner (US1, T037). Tap navigates to
/// Settings so the operator can paste a webhook URL.
class _SlackUnconfiguredBanner extends StatelessWidget {
  const _SlackUnconfiguredBanner();

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    return StreamBuilder<AppSetting?>(
      stream: settingsDao.watchSettings(),
      builder: (context, settingsSnapshot) {
        final settings = settingsSnapshot.data;
        final slackMissing =
            settings == null || settings.slackWebhookUrl.isEmpty;
        if (!slackMissing) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: statusColors.warning.withValues(alpha: 0.15),
            child: Row(
              children: [
                Icon(Icons.warning_amber,
                    color: statusColors.warning, size: 18),
                const SizedBox(width: Insets.s),
                Expanded(
                  child: Text(
                    'Slack notifications disabled — tap to configure',
                    style: AppTextStyles.caption
                        .copyWith(color: statusColors.warning),
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: statusColors.warning, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}
