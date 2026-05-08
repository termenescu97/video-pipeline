import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/job_queue_service.dart';
import '../../utils/error_mapper.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import '../widgets/erase_drive_action.dart';
import '../widgets/files_tab.dart';
import '../widgets/progress_bar.dart';

/// Per-job detail view showing file list and progress.
class JobDetailScreen extends StatefulWidget {
  final int jobId;

  const JobDetailScreen({super.key, required this.jobId});

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Job?>(
        stream: jobDao.watchJob(widget.jobId),
        builder: (context, jobSnapshot) {
          final job = jobSnapshot.data;
          if (job == null) {
            return const Center(child: Text('Job not found'));
          }
          final statusColors = Theme.of(context).extension<StatusColors>()!;

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
                          job.type.label,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: Insets.s),
                        _infoRow('Status', job.status.label),
                        _infoRow('Source', job.sourcePath),
                        _infoRow('Destination', job.destinationPath),
                        if (job.presetName != null)
                          _infoRow('Preset', job.presetName!),
                        if (job.operatorName != null && job.operatorName!.isNotEmpty)
                          _infoRow('Operator', job.operatorName!),
                        if (job.errorMessage != null) ...[
                          const SizedBox(height: Insets.s),
                          // Human-friendly error message.
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: statusColors.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ErrorMapper.getFriendlyMessage(
                                      job.errorMessage),
                                  style: TextStyle(color: statusColors.error),
                                ),
                                const SizedBox(height: Insets.xs),
                                ExpansionTile(
                                  title: const Text(
                                    'Technical Details',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey),
                                  ),
                                  tilePadding: EdgeInsets.zero,
                                  childrenPadding: EdgeInsets.zero,
                                  children: [
                                    Text(
                                      job.errorMessage!,
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: Insets.l),

                // Retry button for failed jobs.
                if (job.status == JobStatus.failed) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _retryJob(job.id),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ),
                  const SizedBox(height: Insets.l),
                ],

                // Progress.
                if (job.status == JobStatus.inProgress) ...[
                  ValueListenableBuilder<ProgressData?>(
                    valueListenable: jobQueueService.progressNotifier,
                    builder: (context, progress, _) {
                      return PipelineProgressBar(
                        progress: job.totalFiles > 0
                            ? job.completedFiles / job.totalFiles
                            : 0,
                        label: job.type.label,
                        completedFiles: job.completedFiles,
                        totalFiles: job.totalFiles,
                        currentFileName: progress?.currentFileName,
                        speedBytesPerSec: progress?.speedBytesPerSec,
                        eta: progress?.eta,
                        elapsed: progress?.elapsed,
                        fps: progress?.fps,
                      );
                    },
                  ),
                  if (job.type == JobType.compression ||
                      job.type == JobType.transferAndCompress)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Preset: ${job.presetName ?? "default"}',
                        style: AppTextStyles.caption
                            .copyWith(color: Colors.grey),
                      ),
                    ),
                ],

                const SizedBox(height: Insets.xl),

                // File list. As of US5 (T048), inline `DetailTabs`
                // expansion in the queue panel is the primary path.
                // JobDetailScreen remains as a backwards-compat route
                // for deep-links / programmatic navigation; FilesTab
                // here gives it the same per-row UX (matches badge,
                // hash popover) as the inline tab.
                Text('Files',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Insets.s),
                SizedBox(
                  height: 360,
                  child: StreamBuilder<List<JobFile>>(
                    stream: jobFileDao.watchFilesForJob(widget.jobId),
                    builder: (context, fs) =>
                        FilesTab(files: fs.data ?? const <JobFile>[]),
                  ),
                ),

                const SizedBox(height: Insets.xl),

                // Erase SD Card button — at the BOTTOM, after file list.
                if (job.status == JobStatus.completed &&
                    job.type != JobType.compression) ...[
                  const Divider(),
                  const SizedBox(height: Insets.s),
                  StreamBuilder<List<JobFile>>(
                    stream: jobFileDao.watchFilesForJob(widget.jobId),
                    builder: (context, filesSnapshot) {
                      final files = filesSnapshot.data ?? [];
                      final allVerified = files.isNotEmpty &&
                          files.every((f) =>
                              f.status == FileStatus.completed && f.verified);

                      if (!allVerified) {
                        return Text(
                          'Cannot erase — some files not verified',
                          style: AppTextStyles.body
                              .copyWith(color: statusColors.warning),
                        );
                      }

                      return SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _eraseSourceDrive(job),
                          icon: Icon(Icons.delete_forever,
                              color: statusColors.error),
                          label: const Text('Erase SD Card'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: statusColors.error,
                            side: BorderSide(color: statusColors.error),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          );
        },
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

  Future<void> _retryJob(int jobId) async {
    await jobDao.resetJobForRetry(jobId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job re-queued for retry')),
      );
    }
  }

  Future<void> _eraseSourceDrive(Job job) async {
    // Delegates to the shared helper extracted in US6 (T056).
    // JobDetailScreen is now legacy fallback (deep-links only); the
    // primary erase entry point is EraseDriveActionButton in the
    // active job's card header.
    await eraseSourceDrive(context, job);
  }
}
