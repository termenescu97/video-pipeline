import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../database/tables.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Files tab inside the inline detail (Phase F). Implemented as a single
/// `ListView.builder` — index 0 is the filter chip row, indices 1..N are
/// the file rows. NO nested scrollers; the parent (`DetailTabs`, T055)
/// gives this widget a bounded height so the inner list virtualizes
/// properly even with hundreds of files (FR-015).
///
/// Per-row format (FR-016, FR-017):
///   [status icon]  filename (middle-ellipsis)  size  [✓ matches]?
///
/// Tapping the "✓ matches" badge opens the hash popover (T041).
///
/// **Files** is supplied by the parent (DetailTabs in Phase 7's review-fix
/// commit), avoiding redundant `watchFilesForJob` subscriptions across
/// multiple tabs of the same expanded card.
class FilesTab extends StatefulWidget {
  final List<JobFile> files;

  const FilesTab({super.key, required this.files});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  /// `null` = "All". Otherwise filters by the chosen FileStatus.
  FileStatus? _filter;

  @override
  Widget build(BuildContext context) {
    final all = widget.files;
    final files = _filter == null
        ? all
        : all.where((f) => f.status == _filter).toList();

    // index 0 = filter chip header; rest = file rows.
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: files.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _FilterChipRow(
            all: all,
            selected: _filter,
            onSelected: (s) => setState(() => _filter = s),
          );
        }
        final file = files[index - 1];
        return _FileRow(file: file);
      },
    );
  }
}

class _FilterChipRow extends StatelessWidget {
  final List<JobFile> all;
  final FileStatus? selected;
  final ValueChanged<FileStatus?> onSelected;

  const _FilterChipRow({
    required this.all,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    int count(FileStatus? s) =>
        s == null ? all.length : all.where((f) => f.status == s).length;

    // 017B (FR-B05): horizontal-scroll instead of Wrap. The operator's
    // 2026-05-08 test had this row breaking to 3 lines at column
    // widths around 360 px; counts became unreadable. Scrolling
    // horizontally keeps every chip on a single line — the chip the
    // operator wants is at most a swipe away regardless of column
    // width.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
          Insets.s, Insets.s, Insets.s, Insets.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _chip(context, label: 'All (${count(null)})', value: null),
          const SizedBox(width: Insets.xs),
          _chip(context,
              label: 'Pending (${count(FileStatus.pending)})',
              value: FileStatus.pending),
          const SizedBox(width: Insets.xs),
          _chip(context,
              label: 'In progress (${count(FileStatus.inProgress)})',
              value: FileStatus.inProgress),
          const SizedBox(width: Insets.xs),
          _chip(context,
              label: 'Completed (${count(FileStatus.completed)})',
              value: FileStatus.completed),
          const SizedBox(width: Insets.xs),
          _chip(context,
              label: 'Failed (${count(FileStatus.failed)})',
              value: FileStatus.failed),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required FileStatus? value}) {
    return FilterChip(
      label: Text(label, style: AppTextStyles.caption),
      selected: selected == value,
      onSelected: (_) => onSelected(value),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _FileRow extends StatelessWidget {
  final JobFile file;
  const _FileRow({required this.file});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final iconColor = _statusIconColor(file.status, statusColors);
    final hasHashes =
        file.sourceHash != null && file.destinationHash != null;

    return InkWell(
      onTap: hasHashes ? () => _showHashPopover(context, file) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Insets.m, vertical: Insets.xs),
        child: Row(
          children: [
            Icon(file.status.icon, size: 16, color: iconColor),
            const SizedBox(width: Insets.s),
            Expanded(
              child: Tooltip(
                message: file.sourceFilePath,
                child: Text(
                  _middleEllipsis(file.fileName, maxLen: 48),
                  style: AppTextStyles.body,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
            const SizedBox(width: Insets.s),
            Text(
              formatBytes(file.fileSize),
              style: AppTextStyles.caption
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
            // 017 (T042): per-file verifyStatus chip. Renders only when
            // the file has reached a non-pending verify state — keeps
            // the row clean for files that haven't entered the verify
            // pipeline yet.
            if (file.verifyStatus != VerifyStatus.pending) ...[
              const SizedBox(width: Insets.s),
              _VerifyStatusChip(
                status: file.verifyStatus,
                onTap: hasHashes ? () => _showHashPopover(context, file) : null,
              ),
            ] else if (file.verified || hasHashes) ...[
              const SizedBox(width: Insets.s),
              _MatchesBadge(
                hasHashes: hasHashes,
                verified: file.verified,
                onTap: hasHashes ? () => _showHashPopover(context, file) : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusIconColor(FileStatus s, StatusColors c) {
    switch (s) {
      case FileStatus.pending:
        return c.dotIdle;
      case FileStatus.inProgress:
        return c.dotActive;
      case FileStatus.completed:
        return c.dotRecentDone;
      case FileStatus.failed:
        return c.dotAttention;
      case FileStatus.skipped:
        return c.dotWarning;
    }
  }

  /// Middle-ellipsis truncation that preserves the timecode tail of
  /// camera filenames (e.g. `A001_C012_…_05072B.MOV`).
  String _middleEllipsis(String s, {required int maxLen}) {
    if (s.length <= maxLen) return s;
    final keep = maxLen - 1;
    final left = (keep * 0.5).floor();
    final right = keep - left;
    return '${s.substring(0, left)}…${s.substring(s.length - right)}';
  }
}

class _MatchesBadge extends StatelessWidget {
  final bool hasHashes;
  final bool verified;
  final VoidCallback? onTap;

  const _MatchesBadge({
    required this.hasHashes,
    required this.verified,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final color = verified ? statusColors.success : scheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: Insets.s, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              verified ? Icons.check_circle : Icons.fingerprint,
              size: 12,
              color: color,
            ),
            const SizedBox(width: Insets.xs),
            Text(
              verified ? '✓ matches' : 'view hashes',
              style: AppTextStyles.caption.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 017 (T042, FR-005, FR-017): per-file verifyStatus chip. Distinct from
/// [_MatchesBadge] because the v8 verify axis is decoupled from the
/// legacy `verified` boolean — a file can be `verifyStatus=unverified`
/// (hash subsystem failed) while bytes are still on disk, and that
/// distinction needs to surface to operators.
class _VerifyStatusChip extends StatelessWidget {
  final VerifyStatus status;
  final VoidCallback? onTap;

  const _VerifyStatusChip({required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final (Color color, IconData icon, String label) = switch (status) {
      VerifyStatus.verified => (
          statusColors.success,
          Icons.check_circle,
          '✓ verified'
        ),
      VerifyStatus.unverified => (
          statusColors.warning,
          Icons.help_outline,
          '⚠ unverified'
        ),
      VerifyStatus.mismatch => (
          statusColors.error,
          Icons.cancel,
          '✗ mismatch'
        ),
      VerifyStatus.pending => (
          Theme.of(context).colorScheme.onSurfaceVariant,
          Icons.hourglass_empty,
          'pending'
        ),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: Insets.s, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: Insets.xs),
            Text(label, style: AppTextStyles.caption.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// T041 hash popover. Shows source + destination SHA-256 in JetBrains Mono
/// with a "Copy both" action that puts both hashes onto the clipboard,
/// labeled, on separate lines.
Future<void> _showHashPopover(BuildContext context, JobFile file) {
  final src = file.sourceHash ?? '';
  final dst = file.destinationHash ?? '';
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final statusColors = Theme.of(ctx).extension<StatusColors>()!;
      final matches = src.isNotEmpty && src == dst;
      return AlertDialog(
        title: Row(
          children: [
            Icon(
              matches ? Icons.check_circle : Icons.warning_amber,
              color: matches ? statusColors.success : statusColors.warning,
              size: 20,
            ),
            const SizedBox(width: Insets.s),
            Text(matches ? 'Hashes match' : 'Hashes differ'),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(file.fileName, style: AppTextStyles.title),
              const SizedBox(height: Insets.m),
              _HashBlock(label: 'Source SHA-256', hash: src, scheme: scheme),
              const SizedBox(height: Insets.s),
              _HashBlock(
                  label: 'Destination SHA-256', hash: dst, scheme: scheme),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy both'),
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text: 'Source: $src\nDestination: $dst',
              ));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Hashes copied to clipboard')),
              );
            },
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

class _HashBlock extends StatelessWidget {
  final String label;
  final String hash;
  final ColorScheme scheme;

  const _HashBlock(
      {required this.label, required this.hash, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Insets.xxs),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Insets.s),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            hash.isEmpty ? '—' : hash,
            style: AppTextStyles.mono,
          ),
        ),
      ],
    );
  }
}
