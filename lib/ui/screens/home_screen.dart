import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/daos/job_dao.dart';
import '../../database/daos/job_file_dao.dart';
import '../../database/daos/settings_dao.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/compression_service.dart';
import '../../services/job_queue_service.dart';
import '../../services/slack_service.dart';
import '../../services/transfer_service.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/job_card.dart';
import 'create_job_screen.dart';
import 'job_detail_screen.dart';
import 'settings_screen.dart';

/// Main screen showing the job queue with real-time updates.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final JobDao _jobDao;
  late final JobQueueService _jobQueueService;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _jobDao = JobDao(database);
    final jobFileDao = JobFileDao(database);
    final settingsDao = SettingsDao(database);
    _jobQueueService = JobQueueService(
      jobDao: _jobDao,
      jobFileDao: jobFileDao,
      slackService: SlackService(settingsDao: settingsDao),
      transferService: TransferService(),
      compressionService: CompressionService(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
      body: StreamBuilder<List<Job>>(
        stream: _jobDao.watchAllJobs(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final jobs = snapshot.data ?? [];

          if (jobs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.queue, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No jobs in queue'),
                  const SizedBox(height: 8),
                  const Text(
                    'Create a job to start transferring or compressing files',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _navigateToCreateJob,
                    icon: const Icon(Icons.add),
                    label: const Text('Create Job'),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              // Start/Stop bar.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _toggleProcessing,
                    icon: Icon(_isProcessing ? Icons.stop : Icons.play_arrow),
                    label: Text(_isProcessing ? 'Stop Queue' : 'Start Queue'),
                    style: _isProcessing
                        ? FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                          )
                        : null,
                  ),
                ),
              ),
              // Job list.
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: jobs.length,
                  itemBuilder: (context, index) {
                    final job = jobs[index];
                    return JobCard(
                      job: job,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => JobDetailScreen(jobId: job.id),
                        ),
                      ),
                      onDelete: () => _deleteJob(job),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToCreateJob,
        icon: const Icon(Icons.add),
        label: const Text('New Job'),
      ),
    );
  }

  void _toggleProcessing() {
    setState(() {
      _isProcessing = !_isProcessing;
    });
    if (_isProcessing) {
      _jobQueueService.startProcessing().then((_) {
        if (mounted) setState(() => _isProcessing = false);
      });
    } else {
      _jobQueueService.stopProcessing();
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
      await _jobDao.deleteJob(job.id);
    }
  }

  void _navigateToCreateJob() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreateJobScreen()),
    ).then((result) {
      if (result == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job added to queue')),
        );
      }
    });
  }
}
