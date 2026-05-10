import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/services/drive_service.dart';

// 019 T034 (FR-020, US8, P3): runtime length-3 argv invariant guard
// in DriveService._runPowerShell.
//
// Closes F-D7 (Opus-only): the 017A length-3 argv assertion lives in
// `process_runner.dart::runPowerShellInline`, but `drive_service.dart`
// calls `Process.run('powershell', [...])` directly via its own
// `_runPowerShell` helper. A future refactor that adds a 4th argv
// element to ANY of getRemovableDrives, getDiskFreeSpace,
// getDriveIdentity, eraseDrive would silently re-open the v2.4.0
// `$args[0]`-silently-dropped root cause for those helpers — the
// shipped fix narrows to `runPowerShellInline` only.
//
// **Codex round-27a P2 fix**: the runtime guard uses `if (...) throw
// StateError(...)`, NOT `assert(...)`. Dart `assert` is stripped from
// `flutter build windows --release`, so a debug-only assert would
// provide zero production protection. We test that the throw fires in
// the test environment (which is debug-mode equivalent) AND verify
// the message names the helper that's broken so post-mortem can
// trace it.

void main() {
  test('case 1: valid argv shape passes guard without throwing', () {
    // The exact shape `_runPowerShell` expects.
    expect(
      () => DriveService.checkPsArgvShape(
        ['-Command', '(Get-PSDrive).Name'],
        'getRemovableDrives',
      ),
      returnsNormally,
      reason: 'Length-3 argv ([-NoProfile, -Command, script]) is the '
          'load-bearing invariant; valid shape MUST pass.',
    );
  });

  test('case 2: extra positional arg throws StateError', () {
    expect(
      () => DriveService.checkPsArgvShape(
        ['-Command', 'script', 'extra-positional'],
        'eraseDrive',
      ),
      throwsA(isA<StateError>()),
      reason: 'A 4th argv element (after -NoProfile becomes the 5th '
          'overall) silently drops trailing elements past `-Command` '
          'in PowerShell — the 017A v2.4.0 root cause. The runtime '
          'throw fires in production builds (NOT a debug-only assert) '
          'so the operator never ships a broken helper.',
    );
  });

  test('case 3: wrong first arg (not -Command) throws StateError', () {
    expect(
      () => DriveService.checkPsArgvShape(
        ['-File', 'script.ps1'],
        'getDriveIdentity',
      ),
      throwsA(isA<StateError>()),
      reason: 'The invariant fixes args[0] == "-Command" — `-File` (or '
          'any other PS entry mode) bypasses the inline-script pattern '
          'that the helpers all rely on.',
    );
  });

  test('case 4: error message names the helper tag for triage', () {
    try {
      DriveService.checkPsArgvShape(
        ['-Command', 'script', 'extra'],
        'getDriveIdentity',
      );
      fail('Expected StateError');
    } on StateError catch (e) {
      expect(e.message, contains('getDriveIdentity'),
          reason: 'The thrown message MUST contain the helper tag so '
              'post-mortem on a production crash points directly at '
              'the broken caller.');
      expect(e.message, contains('017A length-3 argv invariant'),
          reason: 'Cross-references the load-bearing convention so a '
              'reader hitting the throw can find the rationale.');
    }
  });

  test('case 5: empty argv throws (defensive)', () {
    expect(
      () => DriveService.checkPsArgvShape([], 'unknown'),
      throwsA(isA<StateError>()),
      reason: 'Empty argv is never valid; defensive throw matches the '
          'principle "fail-closed on shape violation".',
    );
  });
}
