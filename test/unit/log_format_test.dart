import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/services/log_service.dart';

void main() {
  // Pinned timestamp for goldens. Real LogService inserts DateTime.now().
  const ts = '2026-05-08 14:23:45';

  group('formatEntry — backward-compat (Codex L8)', () {
    test('one-arg call (no context) produces bare line', () {
      // The crucial backward-compat case: `info('App started')` →
      // legacy bare format with no bracket. Existing v2.4.0 callers
      // (e.g. shell_screen.dart "App closed") must keep working.
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'INFO',
          message: 'App started',
        ),
        '[2026-05-08 14:23:45] [INFO] App started',
      );
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'WARN',
          message: 'something off',
        ),
        '[2026-05-08 14:23:45] [WARN] something off',
      );
    });
  });

  group('formatEntry — partial-context combinations (R-A6 8-case table)', () {
    test('jobId only', () {
      expect(
        LogService.formatEntry(
          timestamp: ts, level: 'INFO', message: 'Job created', jobId: 5,
        ),
        '[2026-05-08 14:23:45] [INFO] [job=5] Job created',
      );
    });

    test('phase only', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'INFO',
          message: 'Phase boundary',
          phase: LogPhase.transfer,
        ),
        '[2026-05-08 14:23:45] [INFO] [phase=transfer] Phase boundary',
      );
    });

    test('jobId + phase', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'INFO',
          message: 'Phase started',
          jobId: 1,
          phase: LogPhase.verify,
        ),
        '[2026-05-08 14:23:45] [INFO] [job=1 phase=verify] Phase started',
      );
    });

    test('jobId + fileIndex/totalFiles + phase (full context)', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'INFO',
          message: 'Copied IMG_001.MOV',
          jobId: 1,
          fileIndex: 3,
          totalFiles: 27,
          phase: LogPhase.transfer,
        ),
        '[2026-05-08 14:23:45] [INFO] [job=1 file=3/27 phase=transfer] Copied IMG_001.MOV',
      );
    });

    test('fileIndex without totalFiles is treated as missing both', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'INFO',
          message: 'msg',
          jobId: 1,
          fileIndex: 5,
          phase: LogPhase.transfer,
        ),
        '[2026-05-08 14:23:45] [INFO] [job=1 phase=transfer] msg',
      );
    });

    test('totalFiles without fileIndex is treated as missing both', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'INFO',
          message: 'msg',
          jobId: 1,
          totalFiles: 27,
          phase: LogPhase.transfer,
        ),
        '[2026-05-08 14:23:45] [INFO] [job=1 phase=transfer] msg',
      );
    });

    test('field order is fixed: job, file, phase', () {
      // Even if caller specifies in different order, formatter emits
      // job, file, phase. Test by passing all 4 — order in output
      // is determined by formatEntry.
      final line = LogService.formatEntry(
        timestamp: ts,
        level: 'INFO',
        message: 'msg',
        phase: LogPhase.compress, // last in args
        totalFiles: 10,
        fileIndex: 2,
        jobId: 7, // first in output
      );
      expect(line,
          '[2026-05-08 14:23:45] [INFO] [job=7 file=2/10 phase=compress] msg');
    });
  });

  group('formatEntry — stderr truncation (FR-012)', () {
    test('null stderr produces no colon tail', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'ERROR',
          message: 'failed',
        ),
        '[2026-05-08 14:23:45] [ERROR] failed',
      );
    });

    test('empty stderr produces no colon tail', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'ERROR',
          message: 'failed',
          subprocessStderr: '',
        ),
        '[2026-05-08 14:23:45] [ERROR] failed',
      );
    });

    test('multi-line stderr keeps only first line', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'ERROR',
          message: 'computeFileHash exit=1',
          subprocessStderr: 'first line\nsecond line\nthird line',
        ),
        '[2026-05-08 14:23:45] [ERROR] computeFileHash exit=1: first line',
      );
    });

    test('CRLF line endings handled by trim', () {
      expect(
        LogService.formatEntry(
          timestamp: ts,
          level: 'ERROR',
          message: 'msg',
          subprocessStderr: 'first\r\nsecond',
        ),
        '[2026-05-08 14:23:45] [ERROR] msg: first',
      );
    });

    test('stderr longer than 200 chars truncates with ellipsis', () {
      final longStderr = 'x' * 250;
      final line = LogService.formatEntry(
        timestamp: ts,
        level: 'ERROR',
        message: 'msg',
        subprocessStderr: longStderr,
      );
      // Tail should be 200 'x' chars + '…'.
      expect(line, '[2026-05-08 14:23:45] [ERROR] msg: ${'x' * 200}…');
    });

    test('emoji / surrogate pair stderr does not produce mojibake', () {
      const emoji = '\u{1F4F7}'; // 📷 — needs a surrogate pair in UTF-16
      // 199 graphemes of plain text + emoji = exactly 200 graphemes.
      final stderr = ('a' * 199) + emoji;
      final line = LogService.formatEntry(
        timestamp: ts,
        level: 'ERROR',
        message: 'msg',
        subprocessStderr: stderr,
      );
      // Tail should preserve all 200 graphemes (199 'a' + emoji), no
      // truncation, no replacement char.
      expect(line, '[2026-05-08 14:23:45] [ERROR] msg: ${'a' * 199}$emoji');
    });

    test('emoji at boundary truncates AT grapheme cluster, not mid-surrogate',
        () {
      const emoji = '\u{1F4F7}';
      // 200 'a' chars + emoji = 201 graphemes; truncated at 200.
      final stderr = ('a' * 200) + emoji;
      final line = LogService.formatEntry(
        timestamp: ts,
        level: 'ERROR',
        message: 'msg',
        subprocessStderr: stderr,
      );
      // The 201st grapheme (emoji) is dropped; ellipsis appended.
      // No mojibake — emoji is dropped intact, not split.
      expect(line, '[2026-05-08 14:23:45] [ERROR] msg: ${'a' * 200}…');
      expect(line.contains(emoji), isFalse);
    });
  });

  group('formatEntry — every (level × phase) combination', () {
    final levels = ['INFO', 'WARN', 'ERROR'];
    for (final level in levels) {
      for (final phase in LogPhase.values) {
        test('$level + ${phase.name}', () {
          final line = LogService.formatEntry(
            timestamp: ts,
            level: level,
            message: 'sample',
            phase: phase,
          );
          expect(line,
              '[2026-05-08 14:23:45] [$level] [phase=${phase.name}] sample');
        });
      }
    }
  });
}
