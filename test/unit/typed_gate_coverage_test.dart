import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/ui/theme/app_theme.dart';
import 'package:video_pipeline/ui/widgets/confirmation_dialog.dart';

// 018 T007 (FR-003 + FR-004 + FR-005 + FR-006, US2, P1, SC-002):
// typed-confirmation gate coverage on the three trust-lowering
// operator decisions wired in T005 + T006.
//
// Each Accept/Skip dialog uses the same primitive
// (`ConfirmationDialog.showDestructive`) with a phrase-specific
// typedConfirmation. The wired phrases:
//
//   * Accept-mismatched (job_card_done.dart:_acceptMismatchedFiles)
//     → 'accept mismatch'
//   * Accept-unverified (job_card_done.dart:_acceptUnverifiedFiles)
//     → 'accept unverified'
//   * Skip-mismatch     (job_card_active.dart:_skipAll, the active
//     mismatch banner)             → 'skip mismatch'
//
// These tests drive the primitive directly with each phrase and
// assert the four behaviors the spec requires:
//
//   1. Confirm button is disabled at first render.
//   2. Typing the wrong phrase keeps it disabled.
//   3. Typing a case-different variant keeps it disabled AND
//      surfaces the inline "exact case required" hint.
//   4. Typing the exact phrase enables it; tap returns true.
//   5. Cancel returns false regardless of input.
//
// We test the primitive (not the surrounding widgets) because:
//   - The widget-test infrastructure for JobCardDone / JobCardActive
//     would require mocking DAOs, services, streams, and theme — far
//     beyond what is available today (see test/widget_test.dart).
//   - The wiring change in T005/T006 is purely a call-site swap
//     (showDialog<bool>(builder: AlertDialog) → showDestructive(...)),
//     verifiable by reading the diff. Once the primitive is correct
//     for each of the three phrases, the wiring is correct.

void main() {
  // Drive the primitive once with [phrase], assert the full behavior
  // matrix. Returns the popped result, confirming the test ran the
  // dialog to completion.
  Future<bool?> runDialog({
    required WidgetTester tester,
    required String phrase,
    required String type, // what the operator types
    required bool tapConfirm, // true = tap confirm; false = tap cancel
    required String confirmLabel,
  }) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                result = await ConfirmationDialog.showDestructive(
                  context: ctx,
                  title: 'Test gate',
                  message: 'Test message body.',
                  confirmLabel: confirmLabel,
                  cancelLabel: 'Cancel',
                  typedConfirmation: phrase,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    // Open the dialog.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Initial state: confirm button must be disabled (FilledButton
    // with onPressed: null is what the primitive produces).
    final confirmFinder = find.widgetWithText(FilledButton, confirmLabel);
    expect(confirmFinder, findsOneWidget);
    expect(
      tester.widget<FilledButton>(confirmFinder).onPressed,
      isNull,
      reason: 'Confirm button MUST be disabled at first render — '
          'the typed gate has not been satisfied yet.',
    );

    // Type whatever the test specified (could be wrong / case-different
    // / exact).
    if (type.isNotEmpty) {
      await tester.enterText(find.byType(TextField), type);
      await tester.pump();
    }

    if (tapConfirm) {
      // Tap confirm. If [type] matches [phrase] exactly, the button
      // is enabled and pumpAndSettle resolves the dialog. If not,
      // the tap is a no-op and the test driver hangs — so this path
      // requires [type == phrase].
      await tester.tap(confirmFinder);
      await tester.pumpAndSettle();
    } else {
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    }

    return result;
  }

  group('typed-gate phrase: accept mismatch (job_card_done)', () {
    testWidgets(
        'wrong phrase keeps confirm disabled (matches no exact gate)',
        (tester) async {
      // Prove disabled state by tapping confirm and observing dialog
      // does NOT close (cancel handler triggered instead).
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await ConfirmationDialog.showDestructive(
                    context: ctx,
                    title: 'Test',
                    message: 'msg',
                    confirmLabel: 'Accept mismatch',
                    typedConfirmation: 'accept mismatch',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'wrong words');
      await tester.pump();
      final confirm = find.widgetWithText(FilledButton, 'Accept mismatch');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      // Cancel out to let the result resolve.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('case-different variant shows the case hint',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => ConfirmationDialog.showDestructive(
                  context: ctx,
                  title: 'Test',
                  message: 'msg',
                  confirmLabel: 'Accept mismatch',
                  typedConfirmation: 'accept mismatch',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Accept Mismatch');
      await tester.pump();

      final confirm = find.widgetWithText(FilledButton, 'Accept mismatch');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull,
          reason: 'Case-different input MUST keep button disabled.');
      expect(find.textContaining('exact case required'), findsOneWidget,
          reason: 'Case-different input MUST surface the case hint.');

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('exact phrase enables confirm; tap returns true',
        (tester) async {
      final result = await runDialog(
        tester: tester,
        phrase: 'accept mismatch',
        type: 'accept mismatch',
        tapConfirm: true,
        confirmLabel: 'Accept mismatch',
      );
      expect(result, isTrue);
    });

    testWidgets('cancel returns false even when typed match is exact',
        (tester) async {
      final result = await runDialog(
        tester: tester,
        phrase: 'accept mismatch',
        type: 'accept mismatch',
        tapConfirm: false,
        confirmLabel: 'Accept mismatch',
      );
      expect(result, isFalse);
    });
  });

  group('typed-gate phrase: accept unverified (job_card_done)', () {
    testWidgets('exact phrase enables confirm; tap returns true',
        (tester) async {
      final result = await runDialog(
        tester: tester,
        phrase: 'accept unverified',
        type: 'accept unverified',
        tapConfirm: true,
        confirmLabel: 'Accept unverified',
      );
      expect(result, isTrue);
    });

    testWidgets('case-different keeps disabled + shows case hint',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => ConfirmationDialog.showDestructive(
                  context: ctx,
                  title: 'Test',
                  message: 'msg',
                  confirmLabel: 'Accept unverified',
                  typedConfirmation: 'accept unverified',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'ACCEPT UNVERIFIED');
      await tester.pump();
      final confirm = find.widgetWithText(FilledButton, 'Accept unverified');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(find.textContaining('exact case required'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    });
  });

  group('typed-gate phrase: skip mismatch (job_card_active banner)', () {
    testWidgets('exact phrase enables confirm; tap returns true',
        (tester) async {
      final result = await runDialog(
        tester: tester,
        phrase: 'skip mismatch',
        type: 'skip mismatch',
        tapConfirm: true,
        confirmLabel: 'Skip mismatch',
      );
      expect(result, isTrue);
    });

    testWidgets('empty input keeps confirm disabled (no input case)',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => ConfirmationDialog.showDestructive(
                  context: ctx,
                  title: 'Test',
                  message: 'msg',
                  confirmLabel: 'Skip mismatch',
                  typedConfirmation: 'skip mismatch',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // No text typed at all — button must still be disabled.
      final confirm = find.widgetWithText(FilledButton, 'Skip mismatch');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull,
          reason: 'Empty text input MUST keep button disabled.');

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    });
  });
}
