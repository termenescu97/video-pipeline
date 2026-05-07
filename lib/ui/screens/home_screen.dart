import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../utils/format_utils.dart';
import '../../services/drive_service.dart';
import '../theme/app_theme.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/copy_all_cards_dialog.dart';
import '../widgets/job_card.dart';
import 'settings_screen.dart';

/// Queue list panel — can be used standalone or as left panel in ShellScreen.
class HomeScreen extends StatefulWidget {
  /// Callbacks for master-detail mode (when embedded in ShellScreen).
  final ValueChanged<int>? onJobSelected;
  final VoidCallback? onCreateJob;

  const HomeScreen({super.key, this.onJobSelected, this.onCreateJob});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool get _isEmbedded => widget.onJobSelected != null;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: jobDao.watchAllJobs(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final jobs = snapshot.data ?? [];
        // Warning banners (Slack misconfigured, HandBrake missing,
        // failed-jobs banner) MUST render above both empty and
        // populated queue states. Wrap the whole body in a Column
        // so the banner slot is never hidden by an empty-state early
        // return.
        return Column(
          children: [
            const _WarningBannerSlot(),
            Expanded(child: _buildBody(context, jobs)),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, List<Job> jobs) {
    // Split into active and completed/failed.
    final activeJobs = jobs
        .where((j) =>
            j.status != JobStatus.completed && j.status != JobStatus.failed)
        .toList();
    final historyJobs = jobs
        .where((j) =>
            j.status == JobStatus.completed || j.status == JobStatus.failed)
        .toList();

        // Compute the next-up index: first queued/paused job's index in
        // activeJobs when no job is in progress. -1 if no next-up exists.
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
                        const SizedBox(height: 16),
                        Text('Welcome to Copiatorul3000',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        const Text(
                          'Automate video file transfer and compression.\n'
                          'Insert an SD card and create your first job to get started.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () {
                            settingsDao.setFirstRunCompleted(true);
                            _onCreateJob();
                          },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Get Started'),
                        ),
                        const SizedBox(height: 8),
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
                            const SizedBox(height: 16),
                            Text(
                              '${drives.length} card${drives.length == 1 ? '' : 's'} detected',
                              style: Theme.of(context).textTheme.headlineSmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _batchCopyAllCards,
                              icon: const Icon(Icons.sd_storage),
                              label: const Text('Copy All Cards'),
                            ),
                            const SizedBox(height: 8),
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
                        const SizedBox(height: 16),
                        const Text('No jobs in queue'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _onCreateJob,
                          icon: const Icon(Icons.add),
                          label: const Text('Create Job'),
                        ),
                        const SizedBox(height: 8),
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
                          style: const TextStyle(fontSize: 13)),
                      style: isProcessing
                          ? FilledButton.styleFrom(
                              backgroundColor: Theme.of(context).extension<StatusColors>()!.error)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _batchCopyAllCards,
                      icon: const Icon(Icons.sd_storage, size: 18),
                      label: const Text('Copy All',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                  SliverReorderableList(
                    itemCount: activeJobs.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex--;
                      jobDao.reorderJobs(
                        activeJobs[oldIndex].id,
                        activeJobs[newIndex].id,
                      );
                    },
                    itemBuilder: (context, index) {
                      final job = activeJobs[index];
                      return ReorderableDragStartListener(
                        key: ValueKey(job.id),
                        index: index,
                        child: JobCard(
                          job: job,
                          isNextUp: index == nextUpIndex,
                          onTap: () => _onJobTap(job),
                          onDelete: () => _deleteJob(job),
                          onRetry: job.status == JobStatus.failed
                              ? () => _retryJob(job)
                              : null,
                        ),
                      );
                    },
                  ),
                  // History section.
                  if (historyJobs.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            const Text('History',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.download, size: 18,
                                  color: Colors.grey),
                              tooltip: 'Export CSV',
                              onPressed: _exportHistory,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final job = historyJobs[index];
                          return JobCard(
                            job: job,
                            onTap: () => _onJobTap(job),
                            onDelete: () => _deleteJob(job),
                            onRetry: job.status == JobStatus.failed
                                ? () => _retryJob(job)
                                : null,
                          );
                        },
                        childCount: historyJobs.length,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
  }

  void _onJobTap(Job job) {
    if (_isEmbedded) {
      widget.onJobSelected!(job.id);
    } else {
      // Standalone mode — push to detail screen (fallback).
    }
  }

  void _onCreateJob() {
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
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Queue started')),
      );
      jobQueueService.startProcessing().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _deleteJob(Job job) async {
    if (job.status == JobStatus.inProgress) return;

    final confirmed = await ConfirmationDialog.show(
      context: context,
      title: 'Remove Job',
      message: 'Remove this job from the queue?\n\n'
          '${job.sourcePath} → ${job.destinationPath}',
      confirmLabel: 'Remove',
      confirmColor: Theme.of(context).extension<StatusColors>()!.error,
    );

    if (confirmed) {
      await jobDao.deleteJob(job.id);
    }
  }

  Future<void> _retryJob(Job job) async {
    await jobDao.resetJobForRetry(job.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job re-queued for retry')),
      );
    }
  }

  Future<void> _exportHistory() async {
    final jobs = await jobDao.getCompletedJobsList();
    if (jobs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No history to export')),
        );
      }
      return;
    }

    // Generate CSV content.
    final buffer = StringBuffer();
    buffer.writeln('Date,Type,Source,Destination,Files,Size,Status,Duration,Operator');
    for (final job in jobs) {
      final date = job.completedAt?.toIso8601String().split('T').first ?? '';
      final duration = (job.startedAt != null && job.completedAt != null)
          ? formatDuration(job.completedAt!.difference(job.startedAt!))
          : '';
      final size = formatBytes(job.totalBytes);
      final operator = job.operatorName ?? '';
      buffer.writeln(
        '"$date","${job.type.label}","${job.sourcePath}","${job.destinationPath}",'
        '${job.totalFiles},"$size","${job.status.label}","$duration","$operator"',
      );
    }

    final now = DateTime.now();
    final defaultName = 'copiatorul3000-history-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.csv';

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export History',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (savePath == null) return;

    await File(savePath).writeAsString(buffer.toString());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('History exported to $savePath')),
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
/// Phase 3 (US1) ships only the Slack-misconfigured banner. Failed-jobs
/// banner (T065) and HandBrake-missing banner (T108) plug into this slot
/// in later phases without further structural changes.
class _WarningBannerSlot extends StatelessWidget {
  const _WarningBannerSlot();

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
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Slack notifications disabled — tap to configure',
                    style:
                        TextStyle(fontSize: 12, color: statusColors.warning),
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
