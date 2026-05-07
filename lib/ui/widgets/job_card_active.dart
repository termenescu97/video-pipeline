import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/job_queue_service.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'detail_tabs.dart';
import 'progress_bar.dart';

/// Hero variant for the currently-running job.
///
/// Contains the dense progress display, a verification badge (FR-017),
/// a phase indicator strip for Transfer & Compress jobs (FR-010), and a
/// header action slot reserved for the Erase SD Card button (FR-018, wired
/// in US6 Phase 8).
class JobCardActive extends StatelessWidget {
  final Job job;
  final bool isExpanded;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const JobCardActive({
    super.key,
    required this.job,
    this.isExpanded = false,
    this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final dotColor = _resolveDotColor(statusColors);

    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onTap,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: dotColor, width: 4),
                  ),
                ),
                padding: const EdgeInsets.all(Insets.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(
                      dotColor: dotColor,
                      job: job,
                      onMenu: (pos) => _showContextMenu(context, pos),
                    ),
                    const SizedBox(height: Insets.m),
                    ValueListenableBuilder<ProgressData?>(
                      valueListenable: jobQueueService.progressNotifier,
                      builder: (context, progress, _) {
                        final liveForThisJob =
                            jobQueueService.currentJobId == job.id;
                        return PipelineProgressBar(
                          progress: job.totalFiles > 0
                              ? job.completedFiles / job.totalFiles
                              : 0,
                          label: job.type.label,
                          currentFileName: liveForThisJob
                              ? progress?.currentFileName
                              : null,
                          completedFiles: job.completedFiles,
                          totalFiles: job.totalFiles,
                          elapsed:
                              liveForThisJob ? progress?.elapsed : null,
                          eta: liveForThisJob ? progress?.eta : null,
                          speedBytesPerSec: liveForThisJob
                              ? progress?.speedBytesPerSec
                              : null,
                          fps: liveForThisJob ? progress?.fps : null,
                        );
                      },
                    ),
                    const SizedBox(height: Insets.s),
                    _StatsRow(job: job, scheme: scheme),
                    if (job.type == JobType.transferAndCompress) ...[
                      const SizedBox(height: Insets.s),
                      _PhaseIndicator(job: job, scheme: scheme),
                    ],
                  ],
                ),
              ),
            ),
            if (isExpanded)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: scheme.outlineVariant, width: 1),
                  ),
                ),
                height: 320,
                child: DetailTabs(job: job),
              ),
          ],
        ),
      ),
    );
  }

  Color _resolveDotColor(StatusColors c) => c.dotActive;

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'details', child: Text('View Details')),
        PopupMenuItem(value: 'stop', child: Text('Stop Queue')),
      ],
    ).then((value) {
      if (value == 'details') onTap?.call();
      if (value == 'stop') jobQueueService.stopProcessing();
    });
  }
}

class _Header extends StatelessWidget {
  final Color dotColor;
  final Job job;
  final ValueChanged<Offset> onMenu;

  const _Header({
    required this.dotColor,
    required this.job,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final src = p.basename(job.sourcePath.replaceAll(RegExp(r'[/\\]$'), ''));
    final dst =
        p.basename(job.destinationPath.replaceAll(RegExp(r'[/\\]$'), ''));

    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: Insets.s),
        Icon(_typeGlyph(job.type), size: 18, color: scheme.onSurface),
        const SizedBox(width: Insets.s),
        Expanded(
          child: Tooltip(
            message: '${job.sourcePath} → ${job.destinationPath}',
            child: Text(
              '$src → $dst',
              style: AppTextStyles.title,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // Reserved Erase header slot — wired in US6 (T057).
        Builder(
          builder: (btnContext) => IconButton(
            tooltip: 'More actions',
            icon: const Icon(Icons.more_horiz, size: 20),
            onPressed: () {
              final box = btnContext.findRenderObject() as RenderBox?;
              final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
              onMenu(pos);
            },
          ),
        ),
      ],
    );
  }

  static IconData _typeGlyph(JobType type) {
    switch (type) {
      case JobType.transfer:
        return Icons.file_copy_outlined;
      case JobType.compression:
        return Icons.compress;
      case JobType.transferAndCompress:
        return Icons.sync;
    }
  }
}

class _StatsRow extends StatelessWidget {
  final Job job;
  final ColorScheme scheme;

  const _StatsRow({required this.job, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final filesText = '${job.completedFiles}/${job.totalFiles} files';
    final bytesText = job.totalBytes > 0
        ? '${formatBytes(job.completedBytes)} / ${formatBytes(job.totalBytes)}'
        : null;

    return Row(
      children: [
        Text(filesText,
            style: AppTextStyles.caption
                .copyWith(color: scheme.onSurfaceVariant)),
        if (bytesText != null) ...[
          const SizedBox(width: Insets.m),
          Text(bytesText,
              style: AppTextStyles.caption
                  .copyWith(color: scheme.onSurfaceVariant)),
        ],
        const Spacer(),
        _VerificationBadge(mode: job.verificationMode),
      ],
    );
  }
}

class _VerificationBadge extends StatelessWidget {
  final VerificationMode mode;
  const _VerificationBadge({required this.mode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSha = mode == VerificationMode.sha256;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.s, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSha ? Icons.verified_user : Icons.speed,
            size: 12,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: Insets.xs),
          Text(
            isSha ? 'SHA-256 ✓' : 'Size-only',
            style: AppTextStyles.caption.copyWith(
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseIndicator extends StatelessWidget {
  final Job job;
  final ColorScheme scheme;

  const _PhaseIndicator({required this.job, required this.scheme});

  @override
  Widget build(BuildContext context) {
    // We approximate phase by job status + file completion. The queue service
    // chains compression after transfer; if any compression-output files are
    // pending we are in the Compress phase, otherwise Verify.
    // For now, render a simple three-step strip — a richer signal can be
    // wired in Polish (T093, FR-010).
    return Row(
      children: [
        _PhasePill(
            label: 'Transfer',
            done: job.completedFiles >= job.totalFiles && job.totalFiles > 0,
            scheme: scheme),
        const SizedBox(width: Insets.xs),
        _PhasePill(label: 'Compress', done: false, scheme: scheme),
        const SizedBox(width: Insets.xs),
        _PhasePill(label: 'Verify', done: false, scheme: scheme),
      ],
    );
  }
}

class _PhasePill extends StatelessWidget {
  final String label;
  final bool done;
  final ColorScheme scheme;

  const _PhasePill({
    required this.label,
    required this.done,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final color = done ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = done ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.s, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        done ? '✓ $label' : label,
        style: AppTextStyles.caption.copyWith(color: fg, fontSize: 11),
      ),
    );
  }
}
