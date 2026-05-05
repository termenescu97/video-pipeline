import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/daos/job_dao.dart';
import '../../database/daos/job_file_dao.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../widgets/progress_bar.dart';

/// Per-job detail view showing file list and progress.
class JobDetailScreen extends StatefulWidget {
  final int jobId;

  const JobDetailScreen({super.key, required this.jobId});

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  late final JobDao _jobDao;
  late final JobFileDao _jobFileDao;

  @override
  void initState() {
    super.initState();
    _jobDao = JobDao(database);
    _jobFileDao = JobFileDao(database);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Job Details')),
      body: StreamBuilder<Job?>(
        stream: _jobDao.watchAllJobs().map(
              (jobs) => jobs.where((j) => j.id == widget.jobId).firstOrNull,
            ),
        builder: (context, jobSnapshot) {
          final job = jobSnapshot.data;
          if (job == null) {
            return const Center(child: Text('Job not found'));
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Job summary card.
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _jobTypeLabel(job.type),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        _infoRow('Status', _statusLabel(job.status)),
                        _infoRow('Source', job.sourcePath),
                        _infoRow('Destination', job.destinationPath),
                        if (job.presetName != null)
                          _infoRow('Preset', job.presetName!),
                        if (job.errorMessage != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              job.errorMessage!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Progress.
                if (job.status == JobStatus.inProgress)
                  PipelineProgressBar(
                    progress: job.totalFiles > 0
                        ? job.completedFiles / job.totalFiles
                        : 0,
                    label: _jobTypeLabel(job.type),
                    completedFiles: job.completedFiles,
                    totalFiles: job.totalFiles,
                  ),

                const SizedBox(height: 24),

                // File list.
                Text('Files',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                StreamBuilder<List<JobFile>>(
                  stream: _jobFileDao.watchFilesForJob(widget.jobId),
                  builder: (context, filesSnapshot) {
                    final files = filesSnapshot.data ?? [];
                    if (files.isEmpty) {
                      return const Text('No files recorded yet');
                    }

                    return ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                        final file = files[index];
                        return ListTile(
                          leading: _fileStatusIcon(file.status),
                          title: Text(file.fileName),
                          subtitle: Text(
                            '${(file.fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB',
                          ),
                          dense: true,
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _fileStatusIcon(FileStatus status) {
    return switch (status) {
      FileStatus.pending => const Icon(Icons.schedule, color: Colors.grey),
      FileStatus.inProgress =>
        const Icon(Icons.sync, color: Colors.blue),
      FileStatus.completed =>
        const Icon(Icons.check_circle, color: Colors.green),
      FileStatus.failed => const Icon(Icons.error, color: Colors.red),
      FileStatus.skipped =>
        const Icon(Icons.skip_next, color: Colors.orange),
    };
  }

  String _jobTypeLabel(JobType type) => switch (type) {
        JobType.transfer => 'Transfer',
        JobType.compression => 'Compression',
        JobType.transferAndCompress => 'Transfer + Compress',
      };

  String _statusLabel(JobStatus status) => switch (status) {
        JobStatus.queued => 'Queued',
        JobStatus.inProgress => 'In Progress',
        JobStatus.completed => 'Completed',
        JobStatus.failed => 'Failed',
        JobStatus.paused => 'Paused',
      };
}
