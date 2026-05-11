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
// Codex round-25 redesign: the only field that matters for a sweep
// decision is `host=`. The OS InstanceLock guarantees at most one
// Copiatorul3000 process per machine, and the sweep runs at cold
// start BEFORE any new staging dir is created, so every same-host
// marker found at sweep time is by definition orphaned.
//
// Cases:
//   1. Marker absent (same host implicit, no marker to skip) → removed.
//   2. Marker with this host + a dead PID → removed (the PID/exe
//      fields are diagnostic only; same-host = orphan).
//   3. Marker with a FOREIGN host → preserved (cross-machine NAS;
//      not our problem). Replaces the prior "self pid+exe" check.
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
      'case 2: marker with this host + dead PID + bogus exe path is removed',
      () async {
    final orphan = Directory(p.join(destRoot.path, '.tmp_robocopy_DEAD'))
      ..createSync();
    // Same-host marker. PID 99999 + nonsense exe are diagnostic-only
    // post-round-25; the sweep treats every same-host marker as
    // orphaned (single-instance lock + sweep-runs-first invariant).
    await File(p.join(orphan.path, '.live')).writeAsString(
      'host=${Platform.localHostname}\n'
      'pid=99999\n'
      'exe=/nonexistent/path/to/exe\n',
    );

    await sweepOrphanedStagingDirs(jobDao);

    expect(orphan.existsSync(), isFalse,
        reason: 'Same-host marker = orphan by definition. Single-'
            'instance lock guarantees no other Copiatorul3000 process '
            'on this machine, and sweep runs BEFORE we create any new '
            'markers ourselves, so anything found here MUST be from '
            'a crashed prior run.');
  });

  test(
      'case 3: marker with FOREIGN host is NOT removed — cross-'
      'machine NAS safety (Codex round-25 P1)', () async {
    final foreign =
        Directory(p.join(destRoot.path, '.tmp_robocopy_FOREIGN'))
          ..createSync();
    // A different machine wrote this marker (e.g. another video team
    // workstation on the same NAS). We MUST NOT delete it — the
    // other machine\'s transfer could be in-flight.
    await File(p.join(foreign.path, '.live')).writeAsString(
      'host=some-other-workstation\n'
      'pid=$pid\n'
      'exe=${Platform.resolvedExecutable}\n',
    );

    await sweepOrphanedStagingDirs(jobDao);

    expect(foreign.existsSync(), isTrue,
        reason: 'Cross-machine NAS scenario: another workstation\'s '
            'live marker on a shared destination MUST be silently '
            'preserved. PID + exe match this process by coincidence '
            'but host mismatch is the load-bearing decision.');
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
