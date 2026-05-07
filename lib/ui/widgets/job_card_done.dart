import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Compact dimmed variant for completed/failed jobs (history).
///
/// 48 px tall. State dot communicates success vs failure; type glyph stays
/// monochrome (color reserved for state per FR-009). Only ⋯ overflow is
/// surfaced — primary actions (Retry, View Details) live in the menu.
class JobCardDone extends StatelessWidget {
  final Job job;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  const JobCardDone({
    super.key,
    required this.job,
    this.onTap,
    this.onDelete,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final dotColor = job.status == JobStatus.failed
        ? statusColors.dotAttention
        : statusColors.dotRecentDone;
    final src = p.basename(job.sourcePath.replaceAll(RegExp(r'[/\\]$'), ''));
    final dst =
        p.basename(job.destinationPath.replaceAll(RegExp(r'[/\\]$'), ''));
    final completedSuffix = job.completedAt != null
        ? ' · ${formatRelativeTime(job.completedAt!)}'
        : '';

    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Card(
        clipBehavior: Clip.antiAlias,
        // Use a slightly muted surface for the "dimmed" look.
        color: scheme.surfaceContainerLowest,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: dotColor, width: 4),
              ),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: Insets.l, vertical: Insets.xs),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: Insets.s),
                Icon(_typeGlyph(job.type),
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Insets.s),
                Expanded(
                  child: Tooltip(
                    message:
                        '${job.sourcePath} → ${job.destinationPath}',
                    child: Text(
                      '$src → $dst$completedSuffix',
                      style: AppTextStyles.caption
                          .copyWith(color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                Builder(
                  builder: (btnContext) => IconButton(
                    tooltip: 'More actions',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final box = btnContext.findRenderObject() as RenderBox?;
                      final pos = box?.localToGlobal(Offset.zero) ??
                          Offset.zero;
                      _showContextMenu(context, pos);
                    },
                  ),
                ),
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
      items: [
        const PopupMenuItem(value: 'details', child: Text('View Details')),
        if (job.status == JobStatus.failed)
          const PopupMenuItem(value: 'retry', child: Text('Retry')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    ).then((value) {
      if (value == 'details') onTap?.call();
      if (value == 'retry') onRetry?.call();
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
