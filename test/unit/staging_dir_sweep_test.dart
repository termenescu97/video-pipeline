import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/services/startup_sweep.dart';

// 018 T028 (FR-016, US6, P3, SC-010): startup-sweep behavior matrix.
//
// The sweep removes any `.tmp_robocopy_*` staging dir under a known
// destination root whose `.live` marker is absent or stale (PID dead
// OR PID's exe path doesn't match this process's resolvedExecutable).
//
// Cases:
//   1. Marker absent → removed.
//   2. Marker references a nonexistent PID + bogus exe path → removed.
//   3. Marker references THIS process's PID + exe → NOT removed
//      (live, would-be self-cleanup).
//   4. Destination root path doesn't exist (drive ejected before
//      launch) → no error, no removal attempt.
//   5. Wall-clock latency for a 3-root sweep with sample staging dirs
//      stays under 500 ms (SC-010 perf target).

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late Directory destRoot;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    destRoot = Directory.systemTemp.createTempSync('staging_sweep_');
    // Seed a queued job whose destinationPath is destRoot so the
    // sweep collects it as a known root.
    await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.queued,
        sourcePath: '/tmp/src',
        destinationPath: destRoot.path,
        createdAt: DateTime.now(),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '/tmp/src/IMG.MP4',
          destinationFilePath: '${destRoot.path}/IMG.MP4',
          fileName: 'IMG.MP4',
          fileSize: 1024,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1024,
    );
  });

  tearDown(() async {
    await db.close();
    if (destRoot.existsSync()) destRoot.deleteSync(recursive: true);
  });

  test('case 1: orphan staging dir with NO marker is removed', () async {
    final orphan = Directory(p.join(destRoot.path, '.tmp_robocopy_NOMARKER'))
      ..createSync();
    // Add a sentinel file inside so the dir is non-empty (mirrors
    // the real-world post-crash state with partially-copied bytes).
    await File(p.join(orphan.path, 'partial.MP4')).writeAsBytes([0, 0]);

    await sweepOrphanedStagingDirs(jobDao);

    expect(orphan.existsSync(), isFalse,
        reason: 'A `.tmp_robocopy_*` dir without a `.live` marker is '
            'unconditionally orphaned and must be removed — the '
            'process that created it crashed before writing the '
            'marker, or wrote nothing at all.');
  });

  test(
      'case 2: marker with dead PID + bogus exe path is removed',
      () async {
    final orphan = Directory(p.join(destRoot.path, '.tmp_robocopy_DEAD'))
      ..createSync();
    // PID 99999 is essentially never alive on a fresh test runner.
    // The exe path is intentionally absurd; either the PID-alive or
    // the exe-match check should fail and trigger removal.
    await File(p.join(orphan.path, '.live'))
        .writeAsString('pid=99999\nexe=/nonexistent/path/to/exe\n');

    await sweepOrphanedStagingDirs(jobDao);

    expect(orphan.existsSync(), isFalse,
        reason: 'A marker referencing a dead/foreign PID must NOT '
            'shield the dir from sweep. The two-axis check (PID alive '
            'AND exe matches) is the load-bearing safety against '
            'Windows PID recycling — a coincidental notepad.exe at '
            'the recorded PID must not block recovery.');
  });

  test(
      'case 3: marker references THIS process — dir is NOT removed',
      () async {
    final live = Directory(p.join(destRoot.path, '.tmp_robocopy_LIVE'))
      ..createSync();
    await File(p.join(live.path, '.live')).writeAsString(
      'pid=$pid\nexe=${Platform.resolvedExecutable}\n',
    );

    await sweepOrphanedStagingDirs(jobDao);

    expect(live.existsSync(), isTrue,
        reason: 'A staging dir whose marker matches OUR pid+exe is '
            'this process\'s own active staging — the sweep MUST NOT '
            'delete it. Self-deletion mid-transfer would corrupt an '
            'in-flight robocopy.');
  });

  test(
      'case 4: destination root that no longer exists is skipped silently',
      () async {
    // Seed a SECOND job pointing at a path we delete before sweep.
    final ghostRoot = Directory.systemTemp.createTempSync('ghost_root_');
    await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transfer,
        status: JobStatus.queued,
        sourcePath: '/tmp/src',
        destinationPath: ghostRoot.path,
        createdAt: DateTime.now(),
        sortOrder: const Value(1),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: '/tmp/src/IMG.MP4',
          destinationFilePath: '${ghostRoot.path}/IMG.MP4',
          fileName: 'IMG.MP4',
          fileSize: 1024,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1024,
    );
    ghostRoot.deleteSync();

    // No throw, no observable side-effect on the present root.
    await expectLater(sweepOrphanedStagingDirs(jobDao), completes,
        reason: 'Unmounted destination root must be a silent skip — '
            'an operator may intentionally have the drive disconnected. '
            'A noisy launch-time error every cold start would drown '
            'out signal.');
  });

  test(
      'case 5 (SC-010): 3-root sweep with sample dirs completes under '
      '500 ms', () async {
    // Add 2 more roots + an orphan dir per root to give the sweep
    // real work. We measure wall-clock time end-to-end.
    final roots = <Directory>[destRoot];
    for (var i = 0; i < 2; i++) {
      final extra = Directory.systemTemp.createTempSync('staging_perf_${i}_');
      roots.add(extra);
      await jobDao.createJobWithFiles(
        job: JobsCompanion.insert(
          type: JobType.transfer,
          status: JobStatus.queued,
          sourcePath: '/tmp/src',
          destinationPath: extra.path,
          createdAt: DateTime.now(),
          sortOrder: Value(i + 10),
        ),
        buildFiles: (jId) => [
          JobFilesCompanion.insert(
            jobId: jId,
            sourceFilePath: '/tmp/src/IMG.MP4',
            destinationFilePath: '${extra.path}/IMG.MP4',
            fileName: 'IMG.MP4',
            fileSize: 1024,
            status: FileStatus.pending,
          ),
        ],
        totalBytes: 1024,
      );
    }
    // One orphan per root.
    for (final r in roots) {
      Directory(p.join(r.path, '.tmp_robocopy_PERF')).createSync();
    }

    final sw = Stopwatch()..start();
    await sweepOrphanedStagingDirs(jobDao);
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(500),
        reason: 'SC-010: cold-start sweep latency budget is 500 ms for '
            'a 3-root set. Operators perceive launch sluggishness '
            'above ~1 s, so the sweep gets half of that budget.');

    // Cleanup extras.
    for (final r in roots.skip(1)) {
      if (r.existsSync()) r.deleteSync(recursive: true);
    }
  });
}
