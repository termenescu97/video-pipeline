import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/utils/process_runner.dart';
import 'package:video_pipeline/utils/ps_escape.dart';

void main() {
  group('argsForPowerShellInlineScript (FR-001 argv invariant)', () {
    test('always returns exactly 3 elements for any script', () {
      // The contract that closes the v2.4.0 root cause: PowerShell -Command
      // consumes exactly one argv element (the script string). Any 4th
      // element is silently dropped, so we never emit one.
      final shortArgs = argsForPowerShellInlineScript('1+1');
      expect(shortArgs.length, 3);

      final hashArgs = argsForPowerShellInlineScript(
        "(Get-FileHash -LiteralPath '${escapePsLiteral(r"E:\foo.mp4")}' -Algorithm SHA256).Hash",
      );
      expect(hashArgs.length, 3);

      final tinyArgs = argsForPowerShellInlineScript('');
      expect(tinyArgs.length, 3);
    });

    test('first arg is -NoProfile (locked invariant)', () {
      expect(argsForPowerShellInlineScript('1+1')[0], '-NoProfile');
    });

    test('second arg is -Command (locked invariant)', () {
      expect(argsForPowerShellInlineScript('1+1')[1], '-Command');
    });

    test('third arg is the script string verbatim', () {
      const script =
          "(Get-FileHash -LiteralPath 'foo.mp4' -Algorithm SHA256).Hash";
      expect(argsForPowerShellInlineScript(script)[2], script);
    });

    test('script with embedded spaces / quotes / specials passes through unchanged',
        () {
      const script =
          "(Get-FileHash -LiteralPath 'Tibi''s [reels] *.MP4' -Algorithm SHA256).Hash";
      final args = argsForPowerShellInlineScript(script);
      expect(args[2], script);
      // Critically: no splitting, no extra args, no quoting.
      expect(args.length, 3);
    });
  });

  group('ProcessRunner argv invariant defensive backstop', () {
    test('argsForPowerShellInlineScript output is the contract runPowerShellInline asserts on',
        () {
      // Indirect test: if argsForPowerShellInlineScript ever started returning
      // length != 3, ProcessRunner.runPowerShellInline would throw at runtime.
      for (final script in [
        '',
        '1+1',
        "(Get-FileHash -LiteralPath '' -Algorithm SHA256).Hash",
        'Get-PSDrive -Name E | Select-Object -ExpandProperty Free',
      ]) {
        final args = argsForPowerShellInlineScript(script);
        expect(args.length, 3,
            reason: 'FR-001 argv invariant violated for script: $script');
      }
    });
  });
}
