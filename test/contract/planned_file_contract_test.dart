import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/services/planned_file.dart';

// 017 (T027, R-A9, Codex M4 + M7): contract test for the consolidated
// PlannedFile shape. Both `JobQueueService.createBatchTransferJobs` /
// `_applyResolution` AND `CreateJobScreen._applyResolution` (via direct
// import in v8+) consume this class. A future divergence in either
// consumer's expected shape fails fast here.
//
// Imports (verifying both consumers compile against this shape):
// ignore: unused_import
import 'package:video_pipeline/services/job_queue_service.dart' as executor;
// ignore: unused_import
import 'package:video_pipeline/ui/screens/create_job_screen.dart' as ui;

void main() {
  group('PlannedFile contract — full population', () {
    test('all 5 required + 1 optional fields construct cleanly', () {
      const file = PlannedFile(
        sourcePath: r'H:\DCIM\154_0430\MVI_0089.MP4',
        destinationPath:
            r'E:\Studio Termene\Brut\test\Canon_H\DCIM\154_0430\MVI_0089.MP4',
        fileName: 'MVI_0089.MP4',
        fileSize: 4_400_000_000,
        wasOverwriteApproved: true,
      );
      expect(file.sourcePath, contains('MVI_0089.MP4'));
      expect(file.destinationPath, contains('Canon_H'));
      expect(file.fileName, 'MVI_0089.MP4');
      expect(file.fileSize, 4_400_000_000);
      expect(file.wasOverwriteApproved, isTrue);
    });
  });

  group('PlannedFile contract — default wasOverwriteApproved=false', () {
    test('omitted optional flag defaults to safe baseline', () {
      const file = PlannedFile(
        sourcePath: 'a',
        destinationPath: 'b',
        fileName: 'c',
        fileSize: 1,
      );
      expect(file.wasOverwriteApproved, isFalse,
          reason:
              'Default must be false; the executor-side delete predicate '
              'depends on this safe baseline.');
    });
  });

  group('PlannedFile contract — overwrite-approved=true', () {
    test('represents the post-preflight stamping correctly', () {
      const file = PlannedFile(
        sourcePath: 'a',
        destinationPath: 'b',
        fileName: 'c',
        fileSize: 1,
        wasOverwriteApproved: true,
      );
      expect(file.wasOverwriteApproved, isTrue);
    });
  });

  group('PlannedFile contract — copyWith preserves untouched fields', () {
    test('rename via copyWith(destinationPath: ...) keeps all other fields',
        () {
      const original = PlannedFile(
        sourcePath: '/src/foo.mov',
        destinationPath: '/dest/foo.mov',
        fileName: 'foo.mov',
        fileSize: 100,
        wasOverwriteApproved: true,
      );
      final renamed = original.copyWith(destinationPath: '/dest/foo (1).mov');
      expect(renamed.sourcePath, '/src/foo.mov');
      expect(renamed.destinationPath, '/dest/foo (1).mov');
      expect(renamed.fileName, 'foo.mov',
          reason: 'fileName must NOT change on rename — display name '
              'is from source basename, not destination.');
      expect(renamed.fileSize, 100);
      expect(renamed.wasOverwriteApproved, isTrue,
          reason:
              'wasOverwriteApproved must survive rename — operator approval '
              'persists per file across the suffix-generation step.');
    });

    test('overwrite stamp via copyWith(wasOverwriteApproved: true) keeps path',
        () {
      const original = PlannedFile(
        sourcePath: '/src/foo.mov',
        destinationPath: '/dest/foo.mov',
        fileName: 'foo.mov',
        fileSize: 100,
      );
      final stamped = original.copyWith(wasOverwriteApproved: true);
      expect(stamped.destinationPath, '/dest/foo.mov',
          reason: 'destinationPath must NOT change on overwrite stamp.');
      expect(stamped.wasOverwriteApproved, isTrue);
    });

    test('copyWith with no args returns equal-by-value instance', () {
      const original = PlannedFile(
        sourcePath: '/a',
        destinationPath: '/b',
        fileName: 'c',
        fileSize: 1,
        wasOverwriteApproved: true,
      );
      final clone = original.copyWith();
      expect(clone, original,
          reason: 'PlannedFile must implement value equality for stable '
              'set semantics in collision detection (T058 / FR-008).');
      expect(clone.hashCode, original.hashCode);
    });
  });

  group('PlannedFile contract — skip resolution', () {
    test('a "skipped" file is OMITTED from the planned set, not represented',
        () {
      // Skip semantics: the resolver removes the entry from the list
      // entirely; downstream consumers never see it. PlannedFile has
      // no "skipped" state itself — that's the by-design semantic.
      // This test documents the contract: any future field like `skipped:
      // bool` would break batch creation's assumption that every entry
      // in the list maps to a robocopy invocation.
      final files = [
        const PlannedFile(
          sourcePath: '/a', destinationPath: '/b', fileName: 'c', fileSize: 1,
        ),
        const PlannedFile(
          sourcePath: '/x', destinationPath: '/y', fileName: 'z', fileSize: 2,
        ),
      ];
      // After "skip" resolution, the list shrinks — not the entries.
      final afterSkip = files.where((f) => f.fileName != 'c').toList();
      expect(afterSkip.length, 1);
      expect(afterSkip.single.fileName, 'z');
    });
  });

  group('PlannedFile contract — value equality + hashCode', () {
    test('two identical-field instances are equal', () {
      const a = PlannedFile(
        sourcePath: '/s',
        destinationPath: '/d',
        fileName: 'f',
        fileSize: 1,
        wasOverwriteApproved: true,
      );
      const b = PlannedFile(
        sourcePath: '/s',
        destinationPath: '/d',
        fileName: 'f',
        fileSize: 1,
        wasOverwriteApproved: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing wasOverwriteApproved breaks equality', () {
      const a = PlannedFile(
        sourcePath: '/s', destinationPath: '/d', fileName: 'f', fileSize: 1,
        wasOverwriteApproved: false,
      );
      const b = PlannedFile(
        sourcePath: '/s', destinationPath: '/d', fileName: 'f', fileSize: 1,
        wasOverwriteApproved: true,
      );
      expect(a, isNot(b));
    });
  });

  group('PlannedFile contract — toString includes all fields for debug', () {
    test('toString surfaces every field name and value', () {
      const file = PlannedFile(
        sourcePath: '/s',
        destinationPath: '/d',
        fileName: 'f',
        fileSize: 42,
        wasOverwriteApproved: true,
      );
      final s = file.toString();
      expect(s, contains('source=/s'));
      expect(s, contains('dest=/d'));
      expect(s, contains('fileName=f'));
      expect(s, contains('size=42'));
      expect(s, contains('overwriteApproved=true'));
    });
  });
}
