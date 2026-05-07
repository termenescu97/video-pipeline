import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/job_queue_service.dart';
import '../../utils/format_utils.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/conflict_dialog.dart';
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
        // Split into active and completed/failed.
        final activeJobs = jobs
            .where((j) =>
                j.status != JobStatus.completed && j.status != JobStatus.failed)
            .toList();
        final historyJobs = jobs
            .where((j) =>
                j.status == JobStatus.completed || j.status == JobStatus.failed)
            .toList();

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

              // Normal empty state (first run already completed).
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
        }

        final isProcessing = jobQueueService.isProcessing;

        return Column(
          children: [
            // Slack webhook banner.
            StreamBuilder<AppSetting?>(
              stream: settingsDao.watchSettings(),
              builder: (context, settingsSnapshot) {
                final settings = settingsSnapshot.data;
                if (settings == null || settings.slackWebhookUrl.isEmpty) {
                  return GestureDetector(
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const SettingsScreen())),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      color: Colors.orange.withValues(alpha: 0.15),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Slack notifications disabled — tap to configure',
                              style: TextStyle(fontSize: 12, color: Colors.orange),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Colors.orange, size: 18),
                        ],
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            // Start/Stop + batch buttons.
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
                              backgroundColor: Colors.red.shade700)
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
      },
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
      confirmColor: Colors.red,
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
    final drives = await driveService.getRemovableDrives();
    if (drives.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No removable drives detected')),
        );
      }
      return;
    }

    // Ask for verification mode.
    var verificationMode = VerificationMode.size;
    if (mounted) {
      final selected = await showDialog<VerificationMode>(
        context: context,
        builder: (context) {
          var mode = VerificationMode.size;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('Copy All Cards'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Verification mode:'),
                  const SizedBox(height: 8),
                  SegmentedButton<VerificationMode>(
                    segments: const [
                      ButtonSegment(
                        value: VerificationMode.size,
                        label: Text('Quick'),
                        icon: Icon(Icons.speed),
                      ),
                      ButtonSegment(
                        value: VerificationMode.sha256,
                        label: Text('SHA-256'),
                        icon: Icon(Icons.verified_user),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) =>
                        setDialogState(() => mode = s.first),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, mode),
                  child: const Text('Continue'),
                ),
              ],
            ),
          );
        },
      );
      if (selected == null) return;
      verificationMode = selected;
    }

    var destination = await FilePicker.platform.getDirectoryPath();
    if (destination == null) return;

    // Loop until the operator either lets a non-empty batch through, picks
    // a fresh folder, or cancels via the conflict dialog.
    while (true) {
      ConflictResolution? lastChoice;
      final result = await jobQueueService.createBatchTransferJobs(
        drives,
        destination!,
        verificationMode: verificationMode,
        onConflict: (conflicts) async {
          if (!mounted) return ConflictResolution.cancel;
          final choice =
              await ConflictResolutionDialog.show(context, conflicts);
          lastChoice = choice ?? ConflictResolution.cancel;
          return lastChoice!;
        },
      );

      if (lastChoice == ConflictResolution.newFolder) {
        final newDest = await FilePicker.platform.getDirectoryPath();
        if (newDest == null) return;
        destination = newDest;
        continue; // re-attempt with the new folder
      }

      if (lastChoice == ConflictResolution.cancel) {
        return; // operator aborted
      }

      if (result.created > 0) {
        settingsDao.setFirstRunCompleted(true);
      }

      if (mounted) {
        final String msg;
        if (result.created == 0 && result.conflicts.isNotEmpty) {
          msg = 'All files already exist at destination — no jobs created.';
        } else if (result.skipped > 0) {
          msg =
              'Created ${result.created} jobs — ${result.skipped} cards had no new files';
        } else {
          msg = 'Created ${result.created} jobs';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      break;
    }
  }
}
