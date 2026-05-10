import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/ui/widgets/erase_drive_action.dart';

// 019 T014 (FR-005 — FR-007, US2, P1): erase-time card-content
// reconciliation refusal logic.
//
// Closes F-2 (convergent P1, both auditors CERTAIN): the operator
// queues a batch, the camera flushes one more clip 30s later, the
// batch runs, the operator clicks Erase — the new clip is destroyed
// because the existing eligibility check only verified PLANNED files,
// not what's currently on the card. This is the most likely real-
// world data-loss vector flagged by the holistic audit.
//
// Tests target [unplannedFilesRefusalMessage], the
// `@visibleForTesting` pure function the runtime erase flow delegates
// to. Pure-function testing avoids the WidgetTester dance and keeps
// the assertion focused on the load-bearing diff: which paths in
// the current card scan are NOT in the planned set.
//
// Cases:
//   1. Planned set == current scan → null (proceed).
//   2. Current scan has 1 unplanned file → refusal message includes
//      the count + filename.
//   3. Current scan has fewer files than planned (operator deleted)
//      → null (operator-driven deletion is permitted; missing files'
//      destinations are already verified).
//   4. Current scan has 8 unplanned files → refusal message lists
//      first 5 with "..." truncation.
//   5. Case-insensitive normalization: planned 'IMG_001.MOV', card
//      'img_001.mov' → null (NTFS/exFAT name-collapse → same file).
//   6. Empty planned + empty current → null (no false positive).

void main() {
  test('case 1: planned == current → null (eligibility passes)', () {
    const planned = [
      r'H:\DCIM\IMG_001.MOV',
      r'H:\DCIM\IMG_002.MOV',
      r'H:\DCIM\IMG_003.MOV',
    ];
    const current = [
      r'H:\DCIM\IMG_001.MOV',
      r'H:\DCIM\IMG_002.MOV',
      r'H:\DCIM\IMG_003.MOV',
    ];
    expect(
      unplannedFilesRefusalMessage(
        plannedSourcePaths: planned,
        currentFiles: current,
      ),
      isNull,
      reason: 'Identical sets → no refusal. Happy path.',
    );
  });

  test(
      'case 2: 1 unplanned file → refusal message names count + filename',
      () {
    const planned = [r'H:\DCIM\IMG_001.MOV', r'H:\DCIM\IMG_002.MOV'];
    const current = [
      r'H:\DCIM\IMG_001.MOV',
      r'H:\DCIM\IMG_002.MOV',
      r'H:\DCIM\EXTRA.MOV',
    ];
    final msg = unplannedFilesRefusalMessage(
      plannedSourcePaths: planned,
      currentFiles: current,
    );
    expect(msg, isNotNull, reason: 'F-2 fix: unplanned file → refuse.');
    expect(msg, contains('1 file(s) added'));
    expect(msg, contains('EXTRA.MOV'),
        reason: 'Operator must see WHICH file blocked the erase so '
            'they can either delete it or re-create the job.');
  });

  test(
      'case 3: planned has more than current (operator deleted some) '
      '→ null (operator-driven deletion is permitted)', () {
    const planned = [
      r'H:\DCIM\IMG_001.MOV',
      r'H:\DCIM\IMG_002.MOV',
      r'H:\DCIM\IMG_003.MOV',
    ];
    const current = [r'H:\DCIM\IMG_001.MOV']; // operator deleted 2
    expect(
      unplannedFilesRefusalMessage(
        plannedSourcePaths: planned,
        currentFiles: current,
      ),
      isNull,
      reason: 'Files MISSING from the card are NOT a refusal — the '
          'operator may have manually deleted them; their destinations '
          'are already verified per the existing eligibility synch '
          'gate. The diff is one-way: card-superset triggers refusal, '
          'card-subset does not.',
    );
  });

  test(
      'case 4: 8 unplanned files → refusal message lists 5 + "..." '
      'truncation marker (scannable SnackBar)', () {
    const planned = [r'H:\DCIM\IMG_001.MOV'];
    const current = [
      r'H:\DCIM\IMG_001.MOV',
      r'H:\DCIM\NEW_01.MOV',
      r'H:\DCIM\NEW_02.MOV',
      r'H:\DCIM\NEW_03.MOV',
      r'H:\DCIM\NEW_04.MOV',
      r'H:\DCIM\NEW_05.MOV',
      r'H:\DCIM\NEW_06.MOV',
      r'H:\DCIM\NEW_07.MOV',
      r'H:\DCIM\NEW_08.MOV',
    ];
    final msg = unplannedFilesRefusalMessage(
      plannedSourcePaths: planned,
      currentFiles: current,
    );
    expect(msg, contains('8 file(s) added'));
    expect(msg, contains('NEW_01.MOV'));
    expect(msg, contains('NEW_05.MOV'));
    expect(msg, contains('...'),
        reason: 'Sample truncates at 5 with ellipsis to keep the '
            'SnackBar readable.');
    expect(msg!.contains('NEW_06.MOV'), isFalse,
        reason: 'Files beyond the sample-of-5 are absent (operator '
            'sees count + sample, not the full list).');
  });

  test(
      'case 5: case-insensitive normalization — planned "IMG_001.MOV", '
      'card "img_001.mov" → null (NTFS/exFAT same-file)', () {
    const planned = [r'H:\DCIM\IMG_001.MOV'];
    const current = [r'H:\dcim\img_001.mov'];
    expect(
      unplannedFilesRefusalMessage(
        plannedSourcePaths: planned,
        currentFiles: current,
      ),
      isNull,
      reason: 'NTFS is case-insensitive. exFAT cards may be touched '
          'by case-sensitive tools that produce mixed-case filenames; '
          'the refusal logic normalizes via canonicalize+toLowerCase '
          'so cosmetic case differences do not trigger false refusals.',
    );
  });

  test('case 6: empty planned + empty current → null (no false positive)',
      () {
    expect(
      unplannedFilesRefusalMessage(
        plannedSourcePaths: const [],
        currentFiles: const [],
      ),
      isNull,
    );
  });
}
