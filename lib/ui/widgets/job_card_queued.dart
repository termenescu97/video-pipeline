import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'detail_tabs.dart';

/// Slim row variant for queued/paused jobs that are not next-up.
///
/// 64 px tall. State dot at the left edge, monochrome type glyph, source →
/// destination basenames, ⋯ overflow + visible ☰ drag handle on the right.
/// When [isExpanded] is true, an inline [DetailTabs] panel renders below.
///
/// US7 (T062): the [ReorderableDragStartListener] now wraps ONLY the ☰
/// icon — not the whole card body. This way clicking the card text
/// expands the row inline (FR-007), while the drag affordance is visible
/// and scoped to the handle (FR-005). The host (home_screen) supplies
/// [reorderIndex]; pass `null` to render a static (non-draggable) row,
/// e.g. for cards rendered outside a [SliverReorderableList].
class JobCardQueued extends StatelessWidget {
  final Job job;
  final bool isExpanded;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  /// Index in the parent [SliverReorderableList]. When non-null, the ☰
  /// handle is wrapped in a [ReorderableDragStartListener]; when null,
  /// the row stays draggable-by-no-one (used for non-reorderable
  /// surfaces or in tests).
  final int? reorderIndex;

  const JobCardQueued({
    super.key,
    required this.job,
    this.isExpanded = false,
    this.onTap,
    this.onDelete,
    this.reorderIndex,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final dotColor = job.status == JobStatus.paused
        ? statusColors.dotWarning
        : statusColors.dotIdle;
    final src = p.basename(job.sourcePath.replaceAll(RegExp(r'[/\\]$'), ''));
    final dst =
        p.basename(job.destinationPath.replaceAll(RegExp(r'[/\\]$'), ''));

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
                height: 64,
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: dotColor, width: 4),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: Insets.l, vertical: Insets.s),
                child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: Insets.s),
                Icon(_typeGlyph(job.type),
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: Insets.s),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Tooltip(
                              message:
                                  '${job.sourcePath} → ${job.destinationPath}',
                              child: Text(
                                '$src → $dst',
                                style: AppTextStyles.body,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          // T109: recovery chip — visible while THIS
                          // process's recoverStaleJobs() rescued this
                          // job from a prior crash. Cleared when the
                          // operator acts on the job.
                          if (jobDao.recoveredJobIds.contains(job.id)) ...[
                            const SizedBox(width: Insets.s),
                            const _RecoveredChip(),
                          ],
                        ],
                      ),
                      Text(
                        '${job.type.label} · ${job.totalFiles} files',
                        style: AppTextStyles.caption
                            .copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (btnContext) => IconButton(
                    tooltip: 'More actions',
                    icon: const Icon(Icons.more_horiz, size: 20),
                    onPressed: () {
                      final box = btnContext.findRenderObject() as RenderBox?;
                      final pos = box?.localToGlobal(Offset.zero) ??
                          Offset.zero;
                      _showContextMenu(context, pos);
                    },
                  ),
                ),
                _DragHandle(
                  reorderIndex: reorderIndex,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
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

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'details', child: Text('View Details')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    ).then((value) {
      if (value == 'details') onTap?.call();
      if (value == 'delete') onDelete?.call();
    });
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

/// "Recovered after restart" chip rendered next to the title on
/// JobCardQueued and JobCardNextUp when the job was rescued from
/// in-progress by [JobDao.recoverStaleJobs] (T109, FR-051).
///
/// Reads from [jobDao.recoveredJobIds] (in-memory; resets on app
/// restart). The chip dismisses for that specific job when the
/// operator acts on it (resume / cancel / delete / retry handlers
/// call [JobDao.markRecoveryAcknowledged]).
class _RecoveredChip extends StatelessWidget {
  const _RecoveredChip();

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    return Tooltip(
      message: 'This job was rescued after a previous crash.\n'
          'Press Start when ready to resume.',
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Insets.s, vertical: 1),
        decoration: BoxDecoration(
          color: statusColors.warning.withValues(alpha: 0.15),
          border: Border.all(color: statusColors.warning),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 12, color: statusColors.warning),
            const SizedBox(width: Insets.xxs),
            Text('Recovered',
                style: AppTextStyles.caption
                    .copyWith(color: statusColors.warning)),
          ],
        ),
      ),
    );
  }
}

/// ☰ drag affordance scoped to itself (T062, FR-005). When [reorderIndex]
/// is non-null, taps on this widget start a reorder drag inside the
/// nearest [SliverReorderableList]; otherwise the icon is purely
/// decorative (rare — used when a card variant renders outside a
/// reorderable list).
///
/// Cursor is `grab` so operators see the affordance even before they
/// press. Tooltip exists so the discovery isn't purely visual.
class _DragHandle extends StatelessWidget {
  final int? reorderIndex;
  final Color color;

  const _DragHandle({required this.reorderIndex, required this.color});

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.drag_handle, size: 20, color: color);
    if (reorderIndex == null) return icon;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: ReorderableDragStartListener(
        index: reorderIndex!,
        child: Tooltip(
          message: 'Drag to reorder',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: icon,
          ),
        ),
      ),
    );
  }
}
