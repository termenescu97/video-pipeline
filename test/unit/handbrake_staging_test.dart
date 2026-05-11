import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/services/compression_service.dart';
import 'package:video_pipeline/services/startup_sweep.dart';
import 'package:video_pipeline/utils/process_runner.dart';

// 019 T026 (FR-013 — FR-017, US5, P2): HandBrake compression staging.
//
// Closes F-5 (HandBrake compression has no staging dir / no partial
// cleanup). Compression now writes into a sibling directory
// `<dirname>/.tmp_handbrake_copiatorul3000_<tag>/<basename>`, atomic-
// renames to the final path on success, and deletes the staging dir
// on failure. Cold-start sweep extends to also walk compression-
// output directories and remove orphaned `.tmp_handbrake_copiatorul3000_*`
// whose marker is absent or foreign-host.
//
// Cases:
//   1. Successful encode → staging file is renamed to final path; no
//      `.tmp_handbrake_copiatorul3000_*` siblings remain.
//   2. Failed encode (non-zero exit) → final path absent; staging dir
//      removed.
//   3. Cold-start sweep removes orphan `.tmp_handbrake_copiatorul3000_OLD/`
//      with absent or same-host marker under a job's compressionOutputPath.
//   4. Cold-start sweep PRESERVES foreign-host `.tmp_handbrake_*`
//      orphan (cross-machine NAS guard from 018 round-25 still applies).

/// Stub ProcessRunner that simulates HandBrake without spawning a
/// real subprocess. The exit code is controllable; on simulated
/// success, the stub also writes a non-empty file at the staged
/// output path so the post-success rename has bytes to move.
class _StubProcessRunner extends ProcessRunner {
  final int exitCodeToReturn;
  _StubProcessRunner(this.exitCodeToReturn);

  @override
  Future<int> run({
    required String executable,
    required List<String> arguments,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    if (exitCodeToReturn == 0) {
      // Pull `-o <path>` out of the argv so we can write a fake output
      // file at the staging path (mirrors HandBrake's behavior).
      final outIdx = arguments.indexOf('-o');
      if (outIdx >= 0 && outIdx + 1 < arguments.length) {
        await File(arguments[outIdx + 1]).writeAsBytes([0x00, 0x01, 0x02]);
      }
    }
    return exitCodeToReturn;
  }
}

void main() {
  late Directory destDir;

  setUp(() {
    destDir = Directory.systemTemp.createTempSync('handbrake_staging_');
  });

  tearDown(() {
    if (destDir.existsSync()) destDir.deleteSync(recursive: true);
  });

  test(
      'case 1: successful encode → staging file renamed to final '
      'path; no .tmp_handbrake_copiatorul3000_* siblings remain',
      () async {
    final svc = CompressionService(processRunner: _StubProcessRunner(0));
    final outputFile = p.join(destDir.path, 'encoded.mp4');

    final ok = await svc.compressFile(
      inputFile: '/tmp/in.mp4',
      outputFile: outputFile,
      presetName: 'Fast 1080p30',
    );

    expect(ok, isTrue, reason: 'Stub returned 0 → compressFile reports success.');
    expect(File(outputFile).existsSync(), isTrue,
        reason: 'Final output exists at the expected path post-rename.');
    final siblings = destDir.listSync().map((e) => p.basename(e.path)).toList();
    final stagingSiblings = siblings
        .where((n) => n.startsWith('.tmp_handbrake_copiatorul3000_'))
        .toList();
    expect(stagingSiblings, isEmpty,
        reason: 'Best-effort staging dir cleanup ran post-success — '
            'no orphan staging dir left behind.');
  });

  test(
      'case 2: failed encode (non-zero exit) → final path absent; '
      'staging dir removed', () async {
    final svc = CompressionService(processRunner: _StubProcessRunner(2));
    final outputFile = p.join(destDir.path, 'encoded.mp4');

    final ok = await svc.compressFile(
      inputFile: '/tmp/in.mp4',
      outputFile: outputFile,
      presetName: 'Fast 1080p30',
    );

    expect(ok, isFalse, reason: 'Non-zero exit → compressFile reports failure.');
    expect(File(outputFile).existsSync(), isFalse,
        reason: 'F-5 fix: operator MUST NOT see a partial .mp4 at the '
            'destination after a failed encode.');
    final siblings = destDir.listSync().map((e) => p.basename(e.path)).toList();
    final stagingSiblings = siblings
        .where((n) => n.startsWith('.tmp_handbrake_copiatorul3000_'))
        .toList();
    expect(stagingSiblings, isEmpty,
        reason: 'Failure-path staging dir cleanup must run.');
  });

  test(
      'case 3: cold-start sweep removes orphan staging dir under a '
      'job\'s compressionOutputPath (same-host marker = orphan)',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // Seed a job whose compressionOutputPath points at our temp dir.
    await db.jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transferAndCompress,
        status: JobStatus.completed,
        sourcePath: '/tmp/src',
        destinationPath: '/tmp/dst',
        compressionOutputPath: Value(destDir.path),
        createdAt: DateTime.now(),
        completedAt: Value(DateTime.now()),
        sourceDriveSerial: const Value('SN-TEST'),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '/tmp/src/IMG.MP4',
          destinationFilePath: '/tmp/dst/IMG.MP4',
          fileName: 'IMG.MP4',
          fileSize: 1024,
          status: FileStatus.completed,
          verified: const Value(true),
          verifyStatus: const Value(VerifyStatus.notVerified),
        ),
      ],
      totalBytes: 1024,
    );
    // Seed an orphan staging dir with same-host marker (= our crashed
    // prior run, safe to delete).
    final orphan = Directory(
      p.join(destDir.path, '.tmp_handbrake_copiatorul3000_OLD'),
    )..createSync();
    await File(p.join(orphan.path, '.live')).writeAsString(
      'host=${Platform.localHostname}\npid=99999\nexe=/dev/null\n',
    );

    await sweepOrphanedStagingDirs(db.jobDao);

    expect(orphan.existsSync(), isFalse,
        reason: 'Sweep extended to compressionOutputPath roots AND to '
            'the new prefix matcher. Same-host marker = orphan by '
            'definition (per 018 round-25 InstanceLock invariant).');
  });

  test(
      'case 4: cold-start sweep PRESERVES foreign-host orphan staging '
      'dir (cross-machine NAS guard still applies)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transferAndCompress,
        status: JobStatus.completed,
        sourcePath: '/tmp/src',
        destinationPath: '/tmp/dst',
        compressionOutputPath: Value(destDir.path),
        createdAt: DateTime.now(),
        completedAt: Value(DateTime.now()),
        sourceDriveSerial: const Value('SN-TEST'),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '/tmp/src/IMG.MP4',
          destinationFilePath: '/tmp/dst/IMG.MP4',
          fileName: 'IMG.MP4',
          fileSize: 1024,
          status: FileStatus.completed,
          verified: const Value(true),
          verifyStatus: const Value(VerifyStatus.notVerified),
        ),
      ],
      totalBytes: 1024,
    );
    // Foreign-host marker → another machine's staging on a shared NAS.
    final foreign = Directory(
      p.join(destDir.path, '.tmp_handbrake_copiatorul3000_FOREIGN'),
    )..createSync();
    await File(p.join(foreign.path, '.live')).writeAsString(
      'host=some-other-workstation\npid=$pid\nexe=${Platform.resolvedExecutable}\n',
    );

    await sweepOrphanedStagingDirs(db.jobDao);

    expect(foreign.existsSync(), isTrue,
        reason: 'Cross-machine NAS guard from 018 round-25 carries to '
            'the compression-staging matcher unchanged: foreign-host '
            'marker → silent skip, never delete another machine\'s '
            'in-flight encode.');
  });
}
