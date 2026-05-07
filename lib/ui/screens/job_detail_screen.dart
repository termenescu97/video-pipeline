import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/job_queue_service.dart';
import '../../utils/error_mapper.dart';
import '../../utils/format_utils.dart';
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
                        const SizedBox(height: 8),
                        _infoRow('Status', job.status.label),
                        _infoRow('Source', job.sourcePath),
                        _infoRow('Destination', job.destinationPath),
                        if (job.presetName != null)
                          _infoRow('Preset', job.presetName!),
                        if (job.operatorName != null && job.operatorName!.isNotEmpty)
                          _infoRow('Operator', job.operatorName!),
                        if (job.errorMessage != null) ...[
                          const SizedBox(height: 8),
                          // Human-friendly error message.
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ErrorMapper.getFriendlyMessage(
                                      job.errorMessage),
                                  style: const TextStyle(color: Colors.red),
                                ),
                                const SizedBox(height: 4),
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

                const SizedBox(height: 16),

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
                  const SizedBox(height: 16),
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
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                ],

                const SizedBox(height: 24),

                // File list.
                Text('Files',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                StreamBuilder<List<JobFile>>(
                  stream: jobFileDao.watchFilesForJob(widget.jobId),
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
                        final hasHash = file.sourceHash != null;
                        if (hasHash) {
                          return ExpansionTile(
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _fileStatusIcon(file.status),
                                const SizedBox(width: 4),
                                const Icon(Icons.verified_user,
                                    size: 16, color: Colors.blue),
                              ],
                            ),
                            title: Text(file.fileName),
                            subtitle: Text(formatBytes(file.fileSize)),
                            dense: true,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Source SHA-256:',
                                        style: TextStyle(
                                            fontSize: 11, fontWeight: FontWeight.bold)),
                                    Text(file.sourceHash ?? '—',
                                        style: const TextStyle(
                                            fontSize: 10, fontFamily: 'monospace')),
                                    const SizedBox(height: 4),
                                    const Text('Destination SHA-256:',
                                        style: TextStyle(
                                            fontSize: 11, fontWeight: FontWeight.bold)),
                                    Text(file.destinationHash ?? '—',
                                        style: const TextStyle(
                                            fontSize: 10, fontFamily: 'monospace')),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }
                        return ListTile(
                          leading: _fileStatusIcon(file.status),
                          title: Text(file.fileName),
                          subtitle: Text(formatBytes(file.fileSize)),
                          dense: true,
                        );
                      },
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Erase SD Card button — at the BOTTOM, after file list.
                if (job.status == JobStatus.completed &&
                    job.type != JobType.compression) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  StreamBuilder<List<JobFile>>(
                    stream: jobFileDao.watchFilesForJob(widget.jobId),
                    builder: (context, filesSnapshot) {
                      final files = filesSnapshot.data ?? [];
                      final allVerified = files.isNotEmpty &&
                          files.every((f) =>
                              f.status == FileStatus.completed && f.verified);

                      if (!allVerified) {
                        return const Text(
                          'Cannot erase — some files not verified',
                          style: TextStyle(color: Colors.orange, fontSize: 13),
                        );
                      }

                      return SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _eraseSourceDrive(job),
                          icon: const Icon(Icons.delete_forever,
                              color: Colors.red),
                          label: const Text('Erase SD Card'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
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

  Widget _fileStatusIcon(FileStatus status) {
    return Icon(status.icon, color: status.color);
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
    final drivePath = job.sourcePath;

    // Capture pre-dialog identity. Used to detect a card swap during the
    // confirmation window. Serial number is the strongest physical
    // identifier; label + totalBytes is the fallback when the card reader
    // doesn't expose serial.
    final preIdentity = await driveService.getDriveIdentity(drivePath);
    final identityDesc = preIdentity != null
        ? '${preIdentity.label} (${formatBytes(preIdentity.totalBytes)})'
        : drivePath;

    if (!mounted) return;
    final sizeOnly = job.verificationMode == VerificationMode.size;
    final confirmed = await _showEraseConfirmDialog(
      identityDesc: identityDesc,
      drivePath: drivePath,
      sizeOnlyVerification: sizeOnly,
    );
    if (!confirmed) return;

    // Re-verify identity AFTER the dialog returns. The card may have been
    // physically swapped during the confirmation window, or the drive
    // letter may have been reused for a different device.
    final postIdentity = await driveService.getDriveIdentity(drivePath);
    if (!_identityMatches(preIdentity, postIdentity)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Drive changed during confirmation — erase aborted for safety.',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final success = await driveService.eraseDrive(drivePath);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'SD card erased successfully'
              : 'Failed to erase SD card'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  /// Compare two [getDriveIdentity] results. Returns true if the same
  /// physical device is still mounted at the drive letter. Prefers serial
  /// number (factory-unique); falls back to label + totalBytes when serial
  /// is unavailable on either side.
  bool _identityMatches(
    ({String label, int totalBytes, String? serialNumber})? a,
    ({String label, int totalBytes, String? serialNumber})? b,
  ) {
    if (a == null || b == null) return false;
    if (a.serialNumber != null && b.serialNumber != null) {
      return a.serialNumber == b.serialNumber;
    }
    return a.label == b.label && a.totalBytes == b.totalBytes;
  }

  /// Show the erase confirmation dialog. Requires the operator to type
  /// the drive path to enable the Erase button. Surfaces a prominent
  /// warning when the job was verified by file size only (not SHA-256).
  Future<bool> _showEraseConfirmDialog({
    required String identityDesc,
    required String drivePath,
    required bool sizeOnlyVerification,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final typedMatches = controller.text.trim() == drivePath;
          return AlertDialog(
            title: const Text('Erase SD Card'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'This will permanently delete ALL files on:',
                    ),
                    const SizedBox(height: 8),
                    Text(identityDesc,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Path: $drivePath'),
                    const SizedBox(height: 12),
                    const Text(
                      'This action cannot be undone.',
                      style: TextStyle(color: Colors.red),
                    ),
                    if (sizeOnlyVerification) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          border: Border.all(color: Colors.orange),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber, color: Colors.orange),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Files were verified by size only, not content '
                                'hash. A corrupted file with the same byte size '
                                'as the source would have passed verification. '
                                'Proceed with caution.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Type "$drivePath" to confirm:',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText: drivePath,
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed:
                    typedMatches ? () => Navigator.pop(ctx, true) : null,
                child: const Text('Erase'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result ?? false;
  }
}
