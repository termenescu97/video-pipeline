import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Slim row variant for queued/paused jobs that are not next-up.
///
/// 64 px tall. State dot at the left edge, monochrome type glyph, source →
/// destination basenames, ⋯ overflow on the right. The visible ☰ drag
/// handle is added in US7 (T062) when [ReorderableDragStartListener] is
/// moved off the whole card body.
class JobCardQueued extends StatelessWidget {
  final Job job;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const JobCardQueued({
    super.key,
    required this.job,
    this.onTap,
    this.onDelete,
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
        child: InkWell(
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
                      Tooltip(
                        message:
                            '${job.sourcePath} → ${job.destinationPath}',
                        child: Text(
                          '$src → $dst',
                          style: AppTextStyles.body,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                Icon(Icons.drag_handle,
                    size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: Insets.xs),
              ],
            ),
          ),
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
