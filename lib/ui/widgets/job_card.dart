import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';

/// Displays a job's status in the queue.
class JobCard extends StatelessWidget {
  final Job job;
  final VoidCallback? onTap;

  const JobCard({super.key, required this.job, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: _buildStatusIcon(),
        title: Text(_jobTitle()),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_jobSubtitle()),
            if (job.status == JobStatus.inProgress) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: job.totalFiles > 0
                    ? job.completedFiles / job.totalFiles
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                '${job.completedFiles}/${job.totalFiles} files',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
        trailing: _buildStatusBadge(context),
        onTap: onTap,
        isThreeLine: true,
      ),
    );
  }

  Widget _buildStatusIcon() {
    switch (job.type) {
      case JobType.transfer:
        return const Icon(Icons.file_copy, color: Colors.blue);
      case JobType.compression:
        return const Icon(Icons.compress, color: Colors.orange);
      case JobType.transferAndCompress:
        return const Icon(Icons.sync, color: Colors.purple);
    }
  }

  Widget _buildStatusBadge(BuildContext context) {
    final (color, label) = switch (job.status) {
      JobStatus.queued => (Colors.grey, 'Queued'),
      JobStatus.inProgress => (Colors.blue, 'Running'),
      JobStatus.completed => (Colors.green, 'Done'),
      JobStatus.failed => (Colors.red, 'Failed'),
      JobStatus.paused => (Colors.orange, 'Paused'),
    };

    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide.none,
      padding: EdgeInsets.zero,
    );
  }

  String _jobTitle() {
    return switch (job.type) {
      JobType.transfer => 'Transfer',
      JobType.compression => 'Compression',
      JobType.transferAndCompress => 'Transfer + Compress',
    };
  }

  String _jobSubtitle() {
    return '${job.sourcePath} → ${job.destinationPath}';
  }
}
