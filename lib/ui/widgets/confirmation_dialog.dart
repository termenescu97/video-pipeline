import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Severity tier for [ConfirmationDialog] (T101). Affects visual
/// treatment (icon, accent color) — NOT whether typed confirmation
/// is required. Typed confirmation is MANDATORY for every destructive
/// flow (Constitution Principle I, FR-047).
enum ConfirmationSeverity {
  /// Reversible action that still warrants pause (e.g., "Clear
  /// search filters"). Currently unused — reserved for future
  /// non-destructive but consequential flows.
  info,

  /// Standard destructive: removing a queue row, clearing history,
  /// re-running a job that overwrites prior output. Recoverable in
  /// principle (the source files survive) but the operator should
  /// have intent.
  destructive,

  /// Catastrophic: erases an SD card, force-overwrites unverified
  /// destination files. Unrecoverable. Requires the longest typed
  /// confirmation string (typically the literal target identifier).
  critical,
}

/// Reusable confirmation dialog for destructive actions (T101 rewrite).
///
/// Constitution Principle I (FR-047): non-conflict destructive actions
/// MUST require typed confirmation. The operator types a short string
/// to prove intent; the Confirm button is disabled until the typed
/// text matches exactly.
///
/// API:
///   - [show]            — non-typed; ONLY for non-destructive prompts
///                         (severity: info). Use sparingly.
///   - [showDestructive] — typed gate, destructive severity (orange).
///   - [showCritical]    — typed gate, critical severity (red).
///
/// All variants return `true` on confirm, `false` on cancel.
class ConfirmationDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final ConfirmationSeverity severity;

  /// Typed-confirmation requirement. When non-null, the operator
  /// must type this string exactly to enable the Confirm button.
  /// `null` for [show] (non-destructive); always non-null for
  /// [showDestructive] / [showCritical].
  final String? typedConfirmation;

  const ConfirmationDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.severity = ConfirmationSeverity.info,
    this.typedConfirmation,
  });

  /// Non-destructive prompt — no typed gate. Use only when the action
  /// is safely reversible. For destructive ops, use [showDestructive]
  /// or [showCritical].
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    @Deprecated('Use showDestructive/showCritical for destructive flows; '
        'severity is no longer settable on the non-typed path')
    Color? confirmColor,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConfirmationDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        severity: ConfirmationSeverity.info,
      ),
    );
    return result ?? false;
  }

  /// Destructive action with mandatory typed gate. Default expected
  /// string is `'delete'` — short enough to type quickly but long
  /// enough to defeat muscle-memory click-through.
  static Future<bool> showDestructive({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Delete',
    String cancelLabel = 'Cancel',
    String typedConfirmation = 'delete',
  }) async {
    assert(typedConfirmation.isNotEmpty,
        'Destructive ConfirmationDialog requires non-empty typed gate');
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConfirmationDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        severity: ConfirmationSeverity.destructive,
        typedConfirmation: typedConfirmation,
      ),
    );
    return result ?? false;
  }

  /// Catastrophic action with mandatory typed gate. Caller MUST
  /// supply [typedConfirmation] — typically the literal target
  /// identifier (e.g., the drive path for an SD erase).
  static Future<bool> showCritical({
    required BuildContext context,
    required String title,
    required String message,
    required String typedConfirmation,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
  }) async {
    assert(typedConfirmation.isNotEmpty,
        'Critical ConfirmationDialog requires non-empty typed gate');
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConfirmationDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        severity: ConfirmationSeverity.critical,
        typedConfirmation: typedConfirmation,
      ),
    );
    return result ?? false;
  }

  @override
  State<ConfirmationDialog> createState() => _ConfirmationDialogState();
}

class _ConfirmationDialogState extends State<ConfirmationDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;

    final accent = switch (widget.severity) {
      ConfirmationSeverity.info => scheme.primary,
      ConfirmationSeverity.destructive => statusColors.warning,
      ConfirmationSeverity.critical => statusColors.error,
    };
    final icon = switch (widget.severity) {
      ConfirmationSeverity.info => Icons.info_outline,
      ConfirmationSeverity.destructive => Icons.warning_amber,
      ConfirmationSeverity.critical => Icons.dangerous_outlined,
    };

    final typedRequired = widget.typedConfirmation;
    final typedMatches =
        typedRequired == null || _controller.text.trim() == typedRequired;

    return AlertDialog(
      title: Row(
        children: [
          Icon(icon, color: accent),
          const SizedBox(width: Insets.s),
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.message),
            if (typedRequired != null) ...[
              const SizedBox(height: Insets.l),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Type '),
                    TextSpan(
                      text: '"$typedRequired"',
                      style:
                          AppTextStyles.mono.copyWith(color: accent),
                    ),
                    const TextSpan(text: ' to confirm:'),
                  ],
                ),
                style: AppTextStyles.body
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: Insets.s),
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: typedRequired,
                  hintStyle: AppTextStyles.mono
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
                style: AppTextStyles.mono,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed:
              typedMatches ? () => Navigator.of(context).pop(true) : null,
          style: widget.severity == ConfirmationSeverity.info
              ? null
              : FilledButton.styleFrom(backgroundColor: accent),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
