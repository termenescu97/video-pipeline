import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:video_pipeline/services/drive_service.dart';

// 019 T018 (FR-008 + FR-009, US3, P1): source-side symlink guard.
//
// Closes F-3 (convergent: Opus P1 LIKELY, Codex P2 SPECULATIVE):
// 017B added DEST-side `FileSystemEntity.type(..., followLinks: false)`
// checks; the SOURCE-side mirror was never added. SD cards from
// non-Windows formatters (rare in honest workflows but possible) can
// host symlinks/junctions. A junction at source pointing into the
// destination tree creates an enumeration cycle; a symlink to an
// unrelated path silently expands the planned set outside the SD card.
//
// Tests target `DriveService.listVideoFiles` (the load-bearing
// enumeration entry point used by both create_job_screen and
// startup_sweep adjacent paths). The same followLinks: false +
// per-entry FileSystemEntity.type check pattern is mirrored in
// `JobQueueService.createBatchTransferJobs` (T016) and
// `DriveService.prepTestCards` (T017) — those follow the same
// invariant and would be tested transitively if needed.
//
// Cases:
//   1. No-symlinks happy path — identical to v2.4.0 behavior.
//   2. Symlink in source dir → skipped, listed entries excludes it.
//   3. Cyclic junction (link pointing back into itself) → enumeration
//      completes in bounded time (no infinite loop).
//
// Note: case 3 uses Dart's symlink (not a true Windows junction) since
// macOS dev can't construct junctions natively. The followLinks: false
// flag treats both identically; the per-entry type check confirms.

void main() {
  late Directory tempSrc;
  late DriveService driveService;

  setUp(() {
    tempSrc = Directory.systemTemp.createTempSync('symlink_guard_');
    driveService = DriveService();
  });

  tearDown(() {
    if (tempSrc.existsSync()) tempSrc.deleteSync(recursive: true);
  });

  test('case 1 (happy path): 3 regular .MOV files enumerate as 3 entries',
      () async {
    for (var i = 0; i < 3; i++) {
      await File(p.join(tempSrc.path, 'IMG_$i.MOV'))
          .writeAsBytes(List<int>.filled(1024, 0));
    }

    final result = await driveService.listVideoFiles(tempSrc.path);

    expect(result.files.length, 3,
        reason: 'No-symlinks case must behave identically to v2.4.0 — '
            'no false positives, no skipped legitimate files.');
    expect(result.skippedPaths, isEmpty);
  });

  test(
      'case 2: symlink in source dir → SKIPPED from the planned set, '
      'NOT followed (closes F-3)', () async {
    // Three real .MOV files
    for (var i = 0; i < 3; i++) {
      await File(p.join(tempSrc.path, 'IMG_$i.MOV'))
          .writeAsBytes(List<int>.filled(1024, 0));
    }
    // A separate dir containing files that should NOT be transferred
    // (it's outside the SD-card scope; a symlink into it would
    // exfiltrate them into the planned set).
    final outsideDir = Directory.systemTemp.createTempSync('outside_');
    addTearDown(() {
      if (outsideDir.existsSync()) outsideDir.deleteSync(recursive: true);
    });
    await File(p.join(outsideDir.path, 'SECRET.MOV'))
        .writeAsBytes(List<int>.filled(1024, 0));
    // Create a symlink inside tempSrc pointing at outsideDir.
    await Link(p.join(tempSrc.path, 'leak_link'))
        .create(outsideDir.path);

    final result = await driveService.listVideoFiles(tempSrc.path);

    expect(result.files.length, 3,
        reason: 'Only the 3 real source files. The symlink-target '
            'SECRET.MOV must NOT appear — that would expand the '
            'planned set outside the SD card.');
    final names = result.files.map((f) => p.basename(f.path)).toSet();
    expect(names, {'IMG_0.MOV', 'IMG_1.MOV', 'IMG_2.MOV'});
    expect(names.contains('SECRET.MOV'), isFalse);
  });

  test(
      'case 3: cyclic symlink (pointing back into source) → '
      'enumeration completes in bounded time (no infinite loop)',
      () async {
    await File(p.join(tempSrc.path, 'IMG_REAL.MOV'))
        .writeAsBytes(List<int>.filled(1024, 0));
    // Create a symlink inside tempSrc pointing back at tempSrc itself.
    // Without followLinks: false, recursive listing would loop forever
    // (no cycle detection in dart:io).
    await Link(p.join(tempSrc.path, 'cycle_link')).create(tempSrc.path);

    // Use a generous bound (1 s) — the enumeration should complete
    // near-instantly. If it loops, the timeout will trip.
    final result = await driveService
        .listVideoFiles(tempSrc.path)
        .timeout(const Duration(seconds: 1));

    expect(result.files.length, 1,
        reason: 'Only IMG_REAL.MOV — the cycle symlink is skipped + '
            'logged. Without followLinks: false, dart:io has no cycle '
            'detection and would walk forever.');
  });
}
