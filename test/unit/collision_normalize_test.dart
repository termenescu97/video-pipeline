import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/services/compression_service.dart';
import 'package:video_pipeline/services/drive_service.dart';
import 'package:video_pipeline/services/job_queue_service.dart';
import 'package:video_pipeline/services/planned_file.dart';
import 'package:video_pipeline/services/slack_service.dart';
import 'package:video_pipeline/services/transfer_service.dart';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';

// 017 (T060, FR-008, Codex H3): unit test for the case-only NTFS
// collision detector. Even though source paths can be case-distinct
// (exFAT, Linux/macOS network shares, recursive listings under the
// hood), NTFS folds them to the same key — the second write silently
// overwrites the first. We catch the collision at preflight by walking
// the planned set with a case-insensitive Set and rerouting later
// occurrences through the suffixed-rename pattern.

void main() {
  late AppDatabase db;
  late JobQueueService queue;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);
    queue = JobQueueService(
      jobDao: db.jobDao,
      jobFileDao: db.jobFileDao,
      slackService: SlackService(settingsDao: db.settingsDao),
      transferService: TransferService(),
      compressionService: CompressionService(),
      driveService: DriveService(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test(
      'two case-only-conflicting destinations within one plan are renamed '
      'to distinct NTFS keys', () {
    final files = <PlannedFile>[
      const PlannedFile(
        sourcePath: r'H:\DCIM\IMG_001.MOV',
        destinationPath: r'E:\dest\IMG_001.MOV',
        fileName: 'IMG_001.MOV',
        fileSize: 100,
      ),
      const PlannedFile(
        sourcePath: r'H:\subdir\img_001.mov',
        destinationPath: r'E:\dest\img_001.mov',
        fileName: 'img_001.mov',
        fileSize: 200,
      ),
    ];

    final renames = <(String, String)>[];
    queue.normalizeCaseCollisions(
      [files],
      onRename: (orig, renamed) => renames.add((orig, renamed)),
    );

    expect(renames.length, 1,
        reason: 'Exactly one rewrite — the first occurrence keeps its '
            'path, the second is rerouted.');
    expect(renames.single.$1, r'E:\dest\img_001.mov');
    expect(renames.single.$2.toLowerCase(), isNot(r'e:\dest\img_001.mov'),
        reason: 'Renamed destination must be a NEW NTFS key.');

    final lowerKeys =
        files.map((f) => f.destinationPath.toLowerCase()).toSet();
    expect(lowerKeys.length, 2,
        reason: 'Both files now land at distinct case-folded keys.');

    expect(files[0].destinationPath, r'E:\dest\IMG_001.MOV',
        reason: 'First occurrence is untouched.');
    expect(files[1].destinationPath, isNot(r'E:\dest\img_001.mov'));
    expect(files[1].fileSize, 200,
        reason: 'Rename via copyWith preserves untouched fields.');
  });

  test(
      'collisions across separate plans (multi-card) are still detected '
      'because they share the same destination drive root', () {
    final cardA = <PlannedFile>[
      const PlannedFile(
        sourcePath: r'H:\DCIM\Movie.MOV',
        destinationPath: r'E:\dest\CardA\DCIM\Movie.MOV',
        fileName: 'Movie.MOV',
        fileSize: 1,
      ),
    ];
    final cardB = <PlannedFile>[
      const PlannedFile(
        sourcePath: r'I:\DCIM\Movie.mov',
        destinationPath: r'E:\dest\carda\dcim\movie.mov',
        fileName: 'movie.mov',
        fileSize: 2,
      ),
    ];

    queue.normalizeCaseCollisions([cardA, cardB]);

    final allKeys = <String>{
      cardA.first.destinationPath.toLowerCase(),
      cardB.first.destinationPath.toLowerCase(),
    };
    expect(allKeys.length, 2,
        reason: 'Cross-plan case-only collision must also be broken — '
            'two cards with same label-letter folder name plus '
            'case-different sub-paths cannot collapse silently.');
  });

  test('three-way case-only collision generates three distinct keys',
      () {
    final files = <PlannedFile>[
      const PlannedFile(
        sourcePath: 'a',
        destinationPath: r'E:\dest\IMG_001.MOV',
        fileName: 'IMG_001.MOV',
        fileSize: 1,
      ),
      const PlannedFile(
        sourcePath: 'b',
        destinationPath: r'E:\dest\img_001.mov',
        fileName: 'img_001.mov',
        fileSize: 2,
      ),
      const PlannedFile(
        sourcePath: 'c',
        destinationPath: r'E:\dest\Img_001.Mov',
        fileName: 'Img_001.Mov',
        fileSize: 3,
      ),
    ];

    queue.normalizeCaseCollisions([files]);

    final lowerKeys =
        files.map((f) => f.destinationPath.toLowerCase()).toSet();
    expect(lowerKeys.length, 3,
        reason: 'All three must end at distinct case-folded keys.');
    expect(files[0].destinationPath, r'E:\dest\IMG_001.MOV',
        reason: 'First occurrence is preserved.');
  });

  test('no collision means no renames', () {
    final files = <PlannedFile>[
      const PlannedFile(
        sourcePath: 'a',
        destinationPath: r'E:\dest\IMG_001.MOV',
        fileName: 'IMG_001.MOV',
        fileSize: 1,
      ),
      const PlannedFile(
        sourcePath: 'b',
        destinationPath: r'E:\dest\IMG_002.MOV',
        fileName: 'IMG_002.MOV',
        fileSize: 2,
      ),
    ];
    final renames = <String>[];
    queue.normalizeCaseCollisions(
      [files],
      onRename: (orig, renamed) => renames.add(orig),
    );
    expect(renames, isEmpty);
    expect(files[0].destinationPath, r'E:\dest\IMG_001.MOV');
    expect(files[1].destinationPath, r'E:\dest\IMG_002.MOV');
  });
}
