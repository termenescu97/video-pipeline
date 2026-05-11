import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/services/transfer_service.dart';

// 019 T031 (FR-019, US7, P3): long-path SHA-256 hash prefix.
//
// Closes F-D6 (Opus-only LIKELY): PowerShell 5.1 cannot read paths
// > 260 chars without the `\\?\` long-path prefix. Without the prefix,
// `Get-FileHash` fails for those files, leaving the operator stuck in
// `verifyStatus=unverified` retry loop forever.
//
// Tests target [longPathPrefixed], the `@visibleForTesting` pure
// helper that the runtime `computeFileHash` delegates to. Pure-helper
// testing gives us deterministic shape verification without a real
// PowerShell subprocess (which we can't run on macOS dev).
//
// **Important caveat documented in test 4**: macOS shape-tests CANNOT
// verify that PS 5.1 actually accepts the prefixed path under
// `-LiteralPath` semantics. That requires a Windows-side manual
// verification step (operator T067 in RELEASE_NOTES adds: "create a
// > 260-char path on Windows, run a SHA-256 transfer, confirm the
// hash succeeds"). The macOS tests pin the Dart-side construction;
// the Windows acceptance pins the runtime contract.

void main() {
  test('case 1: short path (< 240 chars) is returned unchanged', () {
    const shortPath = r'C:\Users\Operator\Videos\IMG_001.MOV';
    expect(shortPath.length, lessThan(240));
    expect(longPathPrefixed(shortPath), shortPath,
        reason: 'Below the threshold the prefix is omitted to avoid '
            'changing path semantics that robocopy / HandBrake may not '
            'accept. The prefix is PowerShell-specific.');
  });

  test('case 2: path exactly at the 240-char threshold is unchanged', () {
    final atThreshold = 'C:\\${'a' * 237}'; // 240 chars total
    expect(atThreshold.length, 240);
    expect(longPathPrefixed(atThreshold), atThreshold,
        reason: 'Threshold is `> 240`, not `>=`; exactly 240 stays unchanged.');
  });

  test('case 3: path above the 240-char threshold gets `\\\\?\\` prefix', () {
    final longPath = 'C:\\${'a' * 250}'; // 253 chars
    expect(longPath.length, greaterThan(240));
    final prefixed = longPathPrefixed(longPath);
    expect(prefixed.startsWith(r'\\?\'), isTrue,
        reason: 'Above the threshold the prefix is added so PS 5.1 can '
            'open the file via Get-FileHash -LiteralPath.');
    expect(prefixed.length, longPath.length + 4,
        reason: 'Prefix adds exactly 4 chars (\\\\?\\) — no other shape change.');
    expect(prefixed.substring(4), longPath,
        reason: 'The original path is preserved verbatim after the prefix.');
  });

  test(
      'case 4: path well above the threshold (300 chars) gets the '
      'prefix without truncation', () {
    final longPath = 'C:\\${'b' * 297}'; // 300 chars
    expect(longPath.length, 300);
    final prefixed = longPathPrefixed(longPath);
    expect(prefixed, r'\\?\' + longPath,
        reason: 'No truncation, no escaping, no normalization — the '
            'helper is a single string concatenation.');
    // Document the Windows-acceptance gap inline so future readers
    // see WHY the macOS test isn't sufficient. The Codex round-27a
    // P2 verdict was: shape-test necessary but not sufficient.
    // Operator T067 adds the Windows-side runtime verification.
  });
}
