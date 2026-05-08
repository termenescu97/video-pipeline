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
import 'erase_drive_action.dart';
import 'progress_bar.dart';

/// 017 (T036): tally of per-file verify outcomes computed once per
/// JobFile snapshot and shared by the second-line stats row AND the
/// verify-mismatch banner. Avoids re-walking the file list per widget.
class _VerifyTally {
  final int verified;
  final int unverified;
  final int mismatched;
  final List<int> mismatchedFileIds;

  const _VerifyTally({
    required this.verified,
    required this.unverified,
    required this.mismatched,
    required this.mismatchedFileIds,
  });

  static _VerifyTally from(List<JobFile> files) {
    var v = 0;
    var u = 0;
    var m = 0;
    final mismatchedIds = <int>[];
    for (final f in files) {
      switch (f.verifyStatus) {
        case VerifyStatus.verified:
          v++;
          break;
        case VerifyStatus.unverified:
          u++;
          break;
        case VerifyStatus.mismatch:
          m++;
          mismatchedIds.add(f.id);
          break;
        case VerifyStatus.pending:
          break;
      }
    }
    return _VerifyTally(
      verified: v,
      unverified: u,
      mismatched: m,
      mismatchedFileIds: mismatchedIds,
    );
  }
}

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
                    const SizedBox(height: Insets.s),
                    // 017 (T036b): phase indicator promoted to top of
                    // card. Visible for every job type so operators
                    // always know which phase they're in. The internal
                    // logic of _PhaseIndicator picks the right pill set
                    // per job.type.
                    _PhaseIndicator(job: job, scheme: scheme),
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
                    // 017 (T036c, T041): verify-axis stats + mismatch
                    // banner. Reads JobFile snapshots and computes tally
                    // once per build. Hidden for compression-only jobs
                    // (FR-017) — verify is a transfer-side concern.
                    if (job.type != JobType.compression)
                      StreamBuilder<List<JobFile>>(
                        stream: jobFileDao.watchFilesForJob(job.id),
                        builder: (context, snapshot) {
                          final files = snapshot.data ?? const <JobFile>[];
                          if (files.isEmpty) return const SizedBox.shrink();
                          final tally = _VerifyTally.from(files);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: Insets.xs),
                              _VerifyStatsRow(
                                tally: tally,
                                totalFiles: job.totalFiles,
                                scheme: scheme,
                              ),
                              if (tally.mismatched > 0) ...[
                                const SizedBox(height: Insets.s),
                                _VerifyMismatchBanner(
                                  tally: tally,
                                  onInvestigate: onTap,
                                ),
                              ],
                            ],
                          );
                        },
                      ),
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
        // Header action slot (FR-018): Erase SD Card always visible
        // for transfer-type jobs, disabled-with-reason until eligible.
        EraseDriveActionButton(job: job),
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

/// 017 (T036b): phase indicator promoted to the top of the active card
/// — operators see Transfer → Verify → Compress at a glance regardless
/// of where the job currently is in the pipeline.
///
/// Pill states:
///   - active = current phase, primary color
///   - done = past phase, muted (surfaceContainerHigh)
///   - upcoming = future phase, outlined only
class _PhaseIndicator extends StatelessWidget {
  final Job job;
  final ColorScheme scheme;

  const _PhaseIndicator({required this.job, required this.scheme});

  @override
  Widget build(BuildContext context) {
    // For pure compression, only the Compress pill is meaningful.
    if (job.type == JobType.compression) {
      return Row(
        children: [
          _PhasePill(
            label: 'Compress',
            state: job.status == JobStatus.completed
                ? _PillState.done
                : _PillState.active,
            scheme: scheme,
          ),
        ],
      );
    }

    final transferDone =
        job.completedFiles >= job.totalFiles && job.totalFiles > 0;
    // Verify is "done" only for SHA-256 jobs that have at least one
    // verified file AND no pending verifies remaining; size-mode jobs
    // never reach the verified state, so verify stays muted to indicate
    // it doesn't apply.
    final verifyApplies = job.verificationMode == VerificationMode.sha256;

    final pills = <Widget>[
      _PhasePill(
        label: 'Transfer',
        state: transferDone ? _PillState.done : _PillState.active,
        scheme: scheme,
      ),
      const SizedBox(width: Insets.xs),
      _PhasePill(
        label: 'Verify',
        state: !verifyApplies
            ? _PillState.muted
            : transferDone
                ? _PillState.active
                : _PillState.upcoming,
        scheme: scheme,
      ),
    ];

    if (job.type == JobType.transferAndCompress) {
      pills.add(const SizedBox(width: Insets.xs));
      pills.add(_PhasePill(
        label: 'Compress',
        state: _PillState.upcoming,
        scheme: scheme,
      ));
    }

    return Row(children: pills);
  }
}

enum _PillState { active, done, upcoming, muted }

class _PhasePill extends StatelessWidget {
  final String label;
  final _PillState state;
  final ColorScheme scheme;

  const _PhasePill({
    required this.label,
    required this.state,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Border? border;
    switch (state) {
      case _PillState.active:
        bg = scheme.primary;
        fg = scheme.onPrimary;
        border = null;
        break;
      case _PillState.done:
        bg = scheme.surfaceContainerHigh;
        fg = scheme.onSurfaceVariant;
        border = null;
        break;
      case _PillState.upcoming:
        bg = Colors.transparent;
        fg = scheme.onSurfaceVariant;
        border = Border.all(color: scheme.outlineVariant, width: 1);
        break;
      case _PillState.muted:
        bg = scheme.surfaceContainerHighest;
        fg = scheme.onSurfaceVariant.withValues(alpha: 0.6);
        border = null;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.s, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border,
      ),
      child: Text(
        state == _PillState.done ? '✓ $label' : label,
        style: AppTextStyles.caption.copyWith(color: fg, fontSize: 11),
      ),
    );
  }
}

/// 017 (T036c, FR-017): verify-axis stats line under the bytes counter.
/// Format: `9 / 27 verified · 3 unverified` with warning color when
/// either unverified > 0 or mismatched > 0. Tabular figures (inherited
/// from AppTextStyles.caption) so digit changes don't reflow.
class _VerifyStatsRow extends StatelessWidget {
  final _VerifyTally tally;
  final int totalFiles;
  final ColorScheme scheme;

  const _VerifyStatsRow({
    required this.tally,
    required this.totalFiles,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final hasWarning = tally.unverified > 0 || tally.mismatched > 0;
    final mainColor =
        hasWarning ? statusColors.warning : scheme.onSurfaceVariant;

    final segments = <String>['${tally.verified} / $totalFiles verified'];
    if (tally.unverified > 0) {
      segments.add('${tally.unverified} unverified');
    }
    if (tally.mismatched > 0) {
      segments.add('${tally.mismatched} mismatch');
    }

    return Text(
      segments.join(' · '),
      style: AppTextStyles.caption.copyWith(color: mainColor),
    );
  }
}

/// 017 (T041, FR-005): verify-mismatch banner. The bytes are on disk
/// but SHA-256 caught corruption — operator decides whether to retry
/// (forces dest delete via Codex H2 closure), investigate (opens detail
/// tabs), or skip the row.
class _VerifyMismatchBanner extends StatelessWidget {
  final _VerifyTally tally;
  final VoidCallback? onInvestigate;

  const _VerifyMismatchBanner({
    required this.tally,
    required this.onInvestigate,
  });

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final fg = statusColors.error;

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.m, vertical: Insets.s),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: fg),
          const SizedBox(width: Insets.s),
          Expanded(
            child: Text(
              '${tally.mismatched} file(s) failed SHA-256 verification — '
              'bytes on disk differ from source.',
              style: AppTextStyles.caption.copyWith(color: scheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: onInvestigate,
            child: const Text('Investigate'),
          ),
          TextButton(
            onPressed: () => _retryAll(context, tally.mismatchedFileIds),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _retryAll(BuildContext context, List<int> fileIds) async {
    for (final id in fileIds) {
      await jobQueueService.retryFile(id, forceDestDelete: true);
    }
    await jobQueueService.startProcessing();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Retrying ${fileIds.length} file(s) with forced dest delete'),
        ),
      );
    }
  }
}
