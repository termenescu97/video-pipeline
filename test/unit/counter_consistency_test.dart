import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/tables.dart';

// 018 T023 (FR-013, US5, P3, SC-008): counter consistency.
//
// Two contracts under test:
//
//   A. ATOMICITY (T020) — markFileUnverifiedAndIncrement runs the
//      file-row write + parent counter increment inside ONE
//      transaction. A throw inside the transaction must roll back
//      both writes; on commit, both observably land. This closes
//      the 0.6%-window FR-013 leak where a Phase-B drain landing
//      between the two prior `_safeWrite`s would persist the row
//      change without the counter increment, leaving
//      Job.unverifiedFiles permanently under-counted.
//
//   B. SELF-HEALING READ PATHS (T022) — the four operator-facing
//      reads (getJob, watchJob, watchAllJobs, watchCompletedJobs)
//      compute Job.unverifiedFiles via a per-job aggregate
//      sub-select against job_files, NOT from the persisted
//      jobs.unverified_files column. Drift in the persisted column
//      (in either direction) is invisible to the UI; getJob
//      additionally fires a fire-and-forget reconciliation that
//      writes the corrected value back so future write paths don't
//      propagate the drift.
//
// The drift seed pattern (raw SQL UPDATE on jobs to set
// unverified_files to a wrong value) deliberately bypasses the
// DAO's counter API to simulate a partially-shutdown state from
// before T020 shipped. Both directions of drift are exercised
// (under-count and over-count) so the JOIN doesn't have a hidden
// signedness assumption.

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);
  });

  tearDown(() async {
    await db.close();
  });

  // Seed a job + N file rows at the requested verify status. Returns
  // jobId. Inserted via DAO so the schema/companion is honored.
  Future<int> seedJob({
    required int unverifiedFileCount,
    JobStatus jobStatus = JobStatus.completed,
  }) async {
    final jobId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: jobStatus,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
            // completedAt set so watchCompletedJobs's ORDER BY has
            // something to order on (NULL completedAt sorts last in
            // SQLite, but the test only seeds completed jobs that
            // end up in this stream).
            completedAt: jobStatus == JobStatus.completed
                ? Value(DateTime.now())
                : const Value.absent(),
          ),
        );
    for (var i = 0; i < unverifiedFileCount; i++) {
      await db.into(db.jobFiles).insert(
            JobFilesCompanion.insert(
              jobId: jobId,
              sourceFilePath: '/tmp/src/IMG_$i.MP4',
              destinationFilePath: '/tmp/dst/IMG_$i.MP4',
              fileName: 'IMG_$i.MP4',
              fileSize: 1024,
              status: FileStatus.completed,
              verifyStatus: const Value(VerifyStatus.unverified),
              failureKind: const Value(FailureKind.verifyUnreliable),
            ),
          );
    }
    return jobId;
  }

  // Force the persisted Job.unverified_files column to a specific
  // value, bypassing the DAO. Used to seed a "drift" scenario
  // that mirrors a pre-T020 partially-shutdown state.
  Future<void> setStoredCounter(int jobId, int value) async {
    await db.customStatement(
      'UPDATE jobs SET unverified_files = ? WHERE id = ?',
      [value, jobId],
    );
  }

  Future<int> readStoredCounter(int jobId) async {
    final row = await db
        .customSelect(
          'SELECT unverified_files FROM jobs WHERE id = ?',
          variables: [Variable.withInt(jobId)],
        )
        .getSingle();
    return row.read<int>('unverified_files');
  }

  test(
      'case 1 (T020): markFileUnverifiedAndIncrement is atomic — '
      'a throw inside a wrapping transaction rolls back BOTH writes',
      () async {
    final jobId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.inProgress,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
          ),
        );
    final fileId = await db.into(db.jobFiles).insert(
          JobFilesCompanion.insert(
            jobId: jobId,
            sourceFilePath: '/tmp/src/IMG_0.MP4',
            destinationFilePath: '/tmp/dst/IMG_0.MP4',
            fileName: 'IMG_0.MP4',
            fileSize: 1024,
            status: FileStatus.completed,
            // Pre-call: file is at default pending verifyStatus.
          ),
        );
    final preCounter = await readStoredCounter(jobId);
    expect(preCounter, 0);

    // Drift's nested transaction model: when an outer transaction
    // throws after a nested transaction has "committed," the outer
    // rollback rolls back everything — including the nested writes.
    // This proves the markFileUnverifiedAndIncrement transaction's
    // writes participate in the outer atomicity boundary, which is
    // the contract the executor's _safeWrite wrapper depends on
    // (a thrown exception that escapes _safeWrite during a
    // shutdown window must not leave half-applied state behind).
    Object? caught;
    try {
      await db.transaction(() async {
        await db.jobFileDao.markFileUnverifiedAndIncrement(fileId);
        // Synthetic abort — same shape as a Phase-B-drain timeout
        // throwing out of _safeWrite mid-write.
        throw StateError('synthetic abort post-mark');
      });
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<StateError>(),
        reason: 'Outer transaction must propagate the synthetic abort.');

    // File row's verify_status is still at default 'pending' — the
    // nested write was rolled back by the outer abort.
    final fileRow = await db
        .customSelect('SELECT verify_status FROM job_files WHERE id = ?',
            variables: [Variable.withInt(fileId)])
        .getSingle();
    expect(fileRow.read<String>('verify_status'), 'pending',
        reason: 'File row write must roll back when the outer '
            'transaction aborts.');

    // Counter is still 0 — the increment was rolled back too.
    final postCounter = await readStoredCounter(jobId);
    expect(postCounter, 0,
        reason: 'Counter increment must roll back atomically with the '
            'file row write. This is the FR-013 contract: no half-'
            'applied state survives an abandoned shutdown.');
  });

  test(
      'case 1b (T020): on clean commit BOTH writes land — file row '
      'flips and counter increments by exactly 1', () async {
    final jobId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.inProgress,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
          ),
        );
    final fileId = await db.into(db.jobFiles).insert(
          JobFilesCompanion.insert(
            jobId: jobId,
            sourceFilePath: '/tmp/src/IMG_0.MP4',
            destinationFilePath: '/tmp/dst/IMG_0.MP4',
            fileName: 'IMG_0.MP4',
            fileSize: 1024,
            status: FileStatus.completed,
          ),
        );
    expect(await readStoredCounter(jobId), 0);

    await db.jobFileDao.markFileUnverifiedAndIncrement(fileId);

    final fileRow = await db
        .customSelect(
            'SELECT verify_status, failure_kind FROM job_files WHERE id = ?',
            variables: [Variable.withInt(fileId)])
        .getSingle();
    expect(fileRow.read<String>('verify_status'), 'unverified');
    expect(fileRow.read<String>('failure_kind'), 'verifyUnreliable');
    expect(await readStoredCounter(jobId), 1);
  });

  test(
      'case 2 (T022): getJob returns the JOIN-aggregated unverifiedFiles, '
      'not the (drift) persisted column — under-count direction', () async {
    final jobId = await seedJob(unverifiedFileCount: 2);
    // Drift the stored column LOW (mirrors the partial-shutdown
    // bug pre-T020: 2 file rows landed, 0 counter increments).
    await setStoredCounter(jobId, 0);

    final job = await db.jobDao.getJob(jobId);
    expect(job, isNotNull);
    expect(job!.unverifiedFiles, 2,
        reason: 'getJob must return the JOIN aggregate (2), not the '
            'stored column (0). The UI sees the truth even when the '
            'denormalized cache lags.');
  });

  test(
      'case 3 (T022): watchJob emits the JOIN-aggregated value', () async {
    final jobId = await seedJob(unverifiedFileCount: 3);
    await setStoredCounter(jobId, 0);

    final emitted = await db.jobDao.watchJob(jobId).first;
    expect(emitted, isNotNull);
    expect(emitted!.unverifiedFiles, 3,
        reason: 'watchJob stream must emit the JOIN aggregate, '
            'matching getJob.');
  });

  test(
      'case 4 (T022): watchAllJobs emits the JOIN-aggregated value '
      'on the high-traffic queue stream', () async {
    final jobId = await seedJob(
      unverifiedFileCount: 1,
      jobStatus: JobStatus.queued,
    );
    await setStoredCounter(jobId, 0);

    final list = await db.jobDao.watchAllJobs().first;
    final found = list.firstWhere((j) => j.id == jobId);
    expect(found.unverifiedFiles, 1,
        reason: 'watchAllJobs (the queue UI stream) must self-heal '
            'every emitted Job. A drifted card on the home screen '
            'would otherwise show stale verify counts on every '
            'subsequent emission until the operator restarts.');
  });

  test(
      'case 5 (T022): watchCompletedJobs emits the JOIN-aggregated '
      'value on the history stream', () async {
    final jobId = await seedJob(unverifiedFileCount: 4);
    await setStoredCounter(jobId, 0);

    final list = await db.jobDao.watchCompletedJobs().first;
    final found = list.firstWhere((j) => j.id == jobId);
    expect(found.unverifiedFiles, 4,
        reason: 'watchCompletedJobs (history) must also self-heal — '
            'the Diagnostics → Recent failures section reads through '
            'this stream and would lie about verify counts on drifted '
            'rows.');
  });

  test(
      'case 6 (T022): drift in the OPPOSITE direction (stored=5, '
      'actual=0) is also corrected', () async {
    // Job with NO unverified file rows.
    final jobId = await seedJob(unverifiedFileCount: 0);
    // Drift HIGH — the stored column over-counts.
    await setStoredCounter(jobId, 5);

    final job = await db.jobDao.getJob(jobId);
    expect(job!.unverifiedFiles, 0,
        reason: 'Self-healing aggregate must reflect ACTUAL row state '
            'in either drift direction. An over-counted stored value '
            'must be corrected just as readily as an under-counted one.');
  });

  test(
      'case 7 (T022): after getJob detects drift, the persisted '
      'jobs.unverified_files column is observably reconciled '
      '(fire-and-forget recomputeCountersFromFiles)', () async {
    final jobId = await seedJob(unverifiedFileCount: 2);
    await setStoredCounter(jobId, 0);
    expect(await readStoredCounter(jobId), 0);

    // Trigger the read path that detects drift and schedules
    // reconciliation.
    final readback = await db.jobDao.getJob(jobId);
    expect(readback!.unverifiedFiles, 2);

    // The reconciliation is fire-and-forget (unawaited). Yield the
    // event loop a few times so the scheduled microtask + DB write
    // observably commits before we assert. The reconciliation is
    // a single UPDATE statement, so a handful of microtask turns is
    // more than enough on the in-memory NativeDatabase.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(await readStoredCounter(jobId), 2,
        reason: 'getJob must schedule recomputeCountersFromFiles when '
            'it detects drift, so future write paths that read the '
            'persisted column (and bypass the self-healing reads) see '
            'the corrected baseline. Without this, drift could persist '
            'across restarts and bias new increments.');
  });

  test(
      'case 8 (T022): when stored == actual, getJob does NOT schedule '
      'a reconciliation write (no write storms on the hot path)',
      () async {
    // Steady-state job: stored counter and aggregate already agree.
    final jobId = await seedJob(unverifiedFileCount: 2);
    await setStoredCounter(jobId, 2);

    // Sanity check.
    final job = await db.jobDao.getJob(jobId);
    expect(job!.unverifiedFiles, 2);

    // The reconciliation guard is `if (stored != actual)`. We can't
    // directly assert "no write happened" without a write spy, but
    // we CAN assert the persisted column wasn't touched after
    // settling (`recomputeCountersFromFiles` would also rewrite
    // completed_files and completed_bytes; we observe one of those
    // as a proxy). Pre-set those to deliberately-wrong values; if
    // reconciliation fired they'd snap back to 0.
    await db.customStatement(
      'UPDATE jobs SET completed_files = 999, completed_bytes = 999 '
      'WHERE id = ?',
      [jobId],
    );
    final job2 = await db.jobDao.getJob(jobId);
    expect(job2!.unverifiedFiles, 2);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final probe = await db
        .customSelect(
          'SELECT completed_files FROM jobs WHERE id = ?',
          variables: [Variable.withInt(jobId)],
        )
        .getSingle();
    expect(probe.read<int>('completed_files'), 999,
        reason: 'No-drift reads must NOT schedule reconciliation. '
            'Otherwise every UI emission would rewrite the row, '
            'producing a write storm under the high-frequency '
            'progress notifier.');
  });
}
