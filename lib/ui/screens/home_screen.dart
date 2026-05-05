import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/daos/job_dao.dart';
import '../../main.dart';
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

  @override
  void initState() {
    super.initState();
    _jobDao = JobDao(database);
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

          return ListView.builder(
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
              );
            },
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

  void _navigateToCreateJob() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreateJobScreen()),
    );
  }
}
