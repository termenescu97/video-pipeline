import 'package:flutter/material.dart';

import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// US11 — Keyboard cheat-sheet modal (T084). Surfaced from `?` / `F1`
/// shortcuts (T091) and from the StatusBar `?` icon (T098). Dismisses
/// on `Esc` or outside-click.
///
/// Layout: a single modal dialog with shortcuts grouped into four
/// columns of intent-aligned categories so the operator can scan to
/// the row they need without reading every line:
///
///   Job Management        Queue Control
///   Navigation            Help / System
///
/// Each row pairs a [_KeyChip] (mono-font key cap) with a plain-text
/// description. The modal is the sole source of truth for operator-
/// facing shortcut names — when you wire a new shortcut in
/// shell_screen.dart, add the entry HERE first so discoverability
/// doesn't lag implementation.
class KeyboardCheatSheet extends StatelessWidget {
  const KeyboardCheatSheet({super.key});

  /// Opens the cheat sheet as a barrier-dismissible dialog. Returns
  /// after the modal closes; the caller doesn't need a result.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      // barrierDismissible:true is the default but state it for the
      // benefit of future readers — Esc and outside-click both
      // dismiss the modal (FR-049).
      builder: (_) => const KeyboardCheatSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.keyboard_outlined, color: scheme.primary),
          const SizedBox(width: Insets.s),
          const Text('Keyboard shortcuts'),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Wrap(
            spacing: Insets.xl,
            runSpacing: Insets.l,
            children: const [
              _ShortcutGroup(title: 'Job management', items: [
                ('Ctrl+N', 'New job'),
                ('Ctrl+Shift+C', 'Copy all detected cards'),
                ('Delete', 'Remove selected job (typed confirmation)'),
                ('Ctrl+R', 'Retry selected failed job'),
              ]),
              _ShortcutGroup(title: 'Queue control', items: [
                ('Ctrl+Enter', 'Pause / resume queue'),
                ('Ctrl+E', 'Export history to CSV'),
              ]),
              _ShortcutGroup(title: 'Navigation', items: [
                ('↑ / ↓', 'Move selection in queue'),
                ('Space', 'Expand / collapse selected card'),
                ('Ctrl+,', 'Open Settings'),
                ('Ctrl+L', 'Reveal log file in Explorer'),
              ]),
              _ShortcutGroup(title: 'Help', items: [
                ('? or F1', 'Show this cheat sheet'),
                ('Esc', 'Close cheat sheet / dialogs'),
              ]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// One titled column of (key, description) rows. Width is fixed at
/// 280px so the four groups tile predictably inside the 640px content
/// box (two per row before the wrap).
class _ShortcutGroup extends StatelessWidget {
  final String title;
  final List<(String, String)> items;

  const _ShortcutGroup({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: AppTextStyles.title
                  .copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Insets.s),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
              child: Row(
                children: [
                  _KeyChip(label: item.$1),
                  const SizedBox(width: Insets.m),
                  Expanded(
                    child: Text(item.$2, style: AppTextStyles.body),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Mono-font key cap chip. Matches the visual treatment of physical
/// key labels — bordered rounded-rect with the key name inside.
/// JetBrains Mono so multi-character chords (`Ctrl+Shift+C`) align
/// vertically across rows.
class _KeyChip extends StatelessWidget {
  final String label;
  const _KeyChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 110px width fits "Ctrl+Shift+C" at 12px JetBrains Mono with
    // horizontal padding to spare; the previous 100px ellipsized
    // that chord (Codex Phase 13 NIT).
    return Container(
      width: 110,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.s, vertical: Insets.xxs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono.copyWith(fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
