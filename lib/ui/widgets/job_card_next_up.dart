import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'detail_tabs.dart';

/// Hero variant for the first queued job when nothing is currently running.
///
/// Same height as [JobCardActive], no progress bar, "Press Start to begin"
/// hint instead of stats. Pressing Start activates the queue (FR-005a — the
/// in-place transition to Active variant happens when the queue starts and
/// the job's status flips to inProgress; the router upgrades the variant).
/// When [isExpanded] is true, an inline [DetailTabs] panel renders below.
///
/// US7 (T063): Next-up is reorderable. Only [JobCardActive] is positionally
/// fixed (FR-006); dragging another card above this one promotes it to the
/// new Next-up. The drag handle (☰) renders in the title row when the host
/// supplies [reorderIndex]; pass `null` to render a static row.
class JobCardNextUp extends StatelessWidget {
  final Job job;
  final bool isExpanded;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  /// Index in the parent [SliverReorderableList]. When non-null, the ☰
  /// handle is wrapped in a [ReorderableDragStartListener].
  final int? reorderIndex;

  const JobCardNextUp({
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
    final dotColor = statusColors.dotIdle;
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
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: scheme.primary, width: 4),
                  ),
                ),
                padding: const EdgeInsets.all(Insets.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: Insets.s),
                    Icon(_typeGlyph(job.type),
                        size: 18, color: scheme.onSurface),
                    const SizedBox(width: Insets.s),
                    Expanded(
                      child: Tooltip(
                        message:
                            '${job.sourcePath} → ${job.destinationPath}',
                        child: Text(
                          '$src → $dst',
                          style: AppTextStyles.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Insets.s, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'Next up',
                        style: AppTextStyles.caption.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.s),
                    _DragHandle(
                      reorderIndex: reorderIndex,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: Insets.m),
                Text(
                  'Press Start to begin',
                  style: AppTextStyles.body
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Insets.m),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => jobQueueService.startProcessing(),
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Start'),
                    ),
                    const SizedBox(width: Insets.s),
                    TextButton.icon(
                      onPressed: onDelete,
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Cancel'),
                    ),
                    const Spacer(),
                    Builder(
                      builder: (btnContext) => IconButton(
                        tooltip: 'More actions',
                        icon: const Icon(Icons.more_horiz, size: 20),
                        onPressed: () {
                          final box =
                              btnContext.findRenderObject() as RenderBox?;
                          final pos = box?.localToGlobal(Offset.zero) ??
                              Offset.zero;
                          _showContextMenu(context, pos);
                        },
                      ),
                    ),
                  ],
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

/// ☰ drag affordance scoped to itself (T063, FR-005). See JobCardQueued's
/// _DragHandle for rationale; duplicated here to avoid a cross-widget
/// import cycle and keep each card variant self-contained.
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
