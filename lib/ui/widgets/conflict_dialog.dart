import 'package:flutter/material.dart';

import '../../services/job_queue_service.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Modal dialog presenting destination-conflict resolution options when a
/// new transfer job's destination already contains some of the files it
/// would write. Returns the operator's chosen [ConflictResolution].
///
/// Options:
///   - **Skip**: Drop conflicting files from the job (transfer the rest).
///   - **Rename**: Append `_1`, `_2`, ... to conflicting destination
///     filenames so nothing is overwritten.
///   - **Choose new folder**: Cancel this job creation; caller picks a
///     fresh destination and re-attempts.
///   - **Overwrite**: Proceed and let robocopy overwrite. Requires the
///     operator to type "OVERWRITE" to confirm (per Constitution
///     Principle I — Human-in-the-Loop).
///   - **Cancel**: Abort job creation.
class ConflictResolutionDialog extends StatefulWidget {
  final List<ConflictEntry> conflicts;

  const ConflictResolutionDialog({
    super.key,
    required this.conflicts,
  });

  static Future<ConflictResolution?> show(
    BuildContext context,
    List<ConflictEntry> conflicts,
  ) {
    return showDialog<ConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ConflictResolutionDialog(conflicts: conflicts),
    );
  }

  @override
  State<ConflictResolutionDialog> createState() =>
      _ConflictResolutionDialogState();
}

class _ConflictResolutionDialogState extends State<ConflictResolutionDialog> {
  final _overwriteController = TextEditingController();
  bool _showOverwriteConfirm = false;

  @override
  void dispose() {
    _overwriteController.dispose();
    super.dispose();
  }

  bool get _overwriteTyped =>
      _overwriteController.text.trim().toUpperCase() == 'OVERWRITE';

  @override
  Widget build(BuildContext context) {
    final count = widget.conflicts.length;
    final preview = widget.conflicts.take(8).toList();
    final more = count - preview.length;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('$count file${count == 1 ? '' : 's'} already exist'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The destination already contains files that this job would '
                'write. Choose how to resolve the conflict:',
              ),
              const SizedBox(height: Insets.m),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final c in preview)
                      _ConflictRow(
                        entry: c,
                        statusColors: statusColors,
                        mutedColor: scheme.onSurfaceVariant,
                      ),
                    if (more > 0)
                      Text(
                        '... and $more more',
                        style: AppTextStyles.caption
                            .copyWith(fontSize: 11, color: Colors.grey),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Insets.l),
              if (_showOverwriteConfirm) ...[
                const Text(
                  'Type OVERWRITE to confirm replacing the existing files:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: Insets.s),
                TextField(
                  controller: _overwriteController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'OVERWRITE',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: Insets.s),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _showOverwriteConfirm = false;
                        _overwriteController.clear();
                      }),
                      child: const Text('Back'),
                    ),
                    const SizedBox(width: Insets.s),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: statusColors.error,
                      ),
                      onPressed: _overwriteTyped
                          ? () => Navigator.pop(
                              context, ConflictResolution.overwrite)
                          : null,
                      child: const Text('Overwrite'),
                    ),
                  ],
                ),
              ] else ...[
                _ResolutionTile(
                  icon: Icons.skip_next,
                  label: 'Skip existing',
                  description:
                      'Drop the conflicting files; transfer everything else.',
                  onTap: () =>
                      Navigator.pop(context, ConflictResolution.skip),
                ),
                _ResolutionTile(
                  icon: Icons.drive_file_rename_outline,
                  label: 'Rename',
                  description:
                      'Append _1, _2, ... to conflicting filenames so nothing '
                      'is overwritten.',
                  onTap: () =>
                      Navigator.pop(context, ConflictResolution.rename),
                ),
                _ResolutionTile(
                  icon: Icons.folder_open,
                  label: 'Choose new folder',
                  description:
                      'Cancel this job and pick a different destination.',
                  onTap: () =>
                      Navigator.pop(context, ConflictResolution.newFolder),
                ),
                _ResolutionTile(
                  icon: Icons.warning_amber,
                  iconColor: statusColors.error,
                  label: 'Overwrite',
                  description:
                      'Replace existing files. Requires typing OVERWRITE to '
                      'confirm.',
                  onTap: () =>
                      setState(() => _showOverwriteConfirm = true),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!_showOverwriteConfirm)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, ConflictResolution.cancel),
            child: const Text('Cancel'),
          ),
      ],
    );
  }
}

/// One row of the conflict preview list (T103, FR-046). Shows the
/// destination path on top and source ↔ destination sizes side by
/// side beneath, with a "(identical size)" / "(very different)"
/// hint to help operators spot placeholder vs real conflicts.
///
/// Heuristic: sizes within 1% of each other → "identical size".
/// Sizes differing by more than 50% → "very different". Anything
/// in between renders without a hint.
class _ConflictRow extends StatelessWidget {
  final ConflictEntry entry;
  final StatusColors statusColors;
  final Color mutedColor;

  const _ConflictRow({
    required this.entry,
    required this.statusColors,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    final src = entry.sourceBytes;
    final dst = entry.destinationBytes;

    final srcText = formatBytes(src);
    final dstText = dst != null ? formatBytes(dst) : '?';

    String? hint;
    Color hintColor = mutedColor;
    if (dst != null && dst > 0) {
      final ratio = src > dst ? src / dst : dst / src;
      if (ratio <= 1.01) {
        hint = '(identical size)';
        hintColor = mutedColor;
      } else if (ratio >= 1.5) {
        hint = '(very different)';
        hintColor = statusColors.warning;
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ${entry.destinationPath}',
            style: AppTextStyles.mono.copyWith(fontSize: 11),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: Insets.xxs),
            child: Row(
              children: [
                Text(
                  '$srcText ↔ $dstText',
                  style: AppTextStyles.mono.copyWith(
                    fontSize: 11,
                    color: mutedColor,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(width: Insets.s),
                  Text(
                    hint,
                    style: AppTextStyles.caption
                        .copyWith(fontSize: 11, color: hintColor),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResolutionTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _ResolutionTile({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: Insets.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: Insets.xxs),
                  Text(description,
                      style: AppTextStyles.caption.copyWith(color: Colors.grey)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
