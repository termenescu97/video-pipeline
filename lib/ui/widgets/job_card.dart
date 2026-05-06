import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../utils/format_utils.dart';

/// Displays a job's status in the queue.
class JobCard extends StatelessWidget {
  final Job job;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  const JobCard({super.key, required this.job, this.onTap, this.onDelete, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Card(
        child: ListTile(
        leading: _buildStatusIcon(),
        title: Text(_jobTitle()),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tooltip(
              message: _fullPathSubtitle(),
              child: Text(_jobSubtitle()),
            ),
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onDelete != null && job.status != JobStatus.inProgress)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onDelete,
                tooltip: 'Remove from queue',
              ),
            _buildStatusBadge(context),
          ],
        ),
        onTap: onTap,
        isThreeLine: true,
      ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: 'details', child: Text('View Details')),
        if (job.status != JobStatus.inProgress)
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        if (job.status == JobStatus.failed)
          const PopupMenuItem(value: 'retry', child: Text('Retry')),
      ],
    ).then((value) {
      if (value == 'details') onTap?.call();
      if (value == 'delete') onDelete?.call();
      if (value == 'retry') onRetry?.call();
    });
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
    return Chip(
      label: Text(job.status.label, style: const TextStyle(fontSize: 11)),
      backgroundColor: job.status.color.withValues(alpha: 0.15),
      side: BorderSide.none,
      padding: EdgeInsets.zero,
    );
  }

  String _jobTitle() => job.type.label;

  String _jobSubtitle() {
    final src = p.basename(job.sourcePath.replaceAll(RegExp(r'[/\\]$'), ''));
    final dst = p.basename(job.destinationPath.replaceAll(RegExp(r'[/\\]$'), ''));
    final base = '$src → $dst';
    if (job.completedAt != null &&
        (job.status == JobStatus.completed || job.status == JobStatus.failed)) {
      return '$base · ${formatRelativeTime(job.completedAt!)}';
    }
    return base;
  }

  String _fullPathSubtitle() {
    return '${job.sourcePath} → ${job.destinationPath}';
  }
}
