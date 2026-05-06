import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/job_card.dart';

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
        }

        final isProcessing = jobQueueService.isProcessing;

        return Column(
          children: [
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
            // Active jobs.
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  ...activeJobs.map((job) => JobCard(
                        job: job,
                        onTap: () => _onJobTap(job),
                        onDelete: () => _deleteJob(job),
                      )),
                  // History section.
                  if (historyJobs.isNotEmpty) ...[
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text('History',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.grey)),
                    ),
                    ...historyJobs.map((job) => JobCard(
                          job: job,
                          onTap: () => _onJobTap(job),
                          onDelete: () => _deleteJob(job),
                        )),
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

    final destination = await FilePicker.platform.getDirectoryPath();
    if (destination == null) return;

    final result = await jobQueueService.createBatchTransferJobs(
      drives,
      destination,
    );

    if (mounted) {
      final msg = result.skipped > 0
          ? 'Created ${result.created} jobs — ${result.skipped} cards had no video files'
          : 'Created ${result.created} jobs';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }
}
