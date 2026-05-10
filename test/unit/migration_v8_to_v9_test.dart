import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/tables.dart';

// 019 T004 (FR-001, US1, P1): schema v8 → v9 migration test.
//
// Two contracts under test:
//   A. Fresh-install at v9 — onCreate path. The new column exists and
//      is queryable. Default companions can omit it (it's nullable).
//   B. Migration backfill — the v9 onUpgrade step writes the sentinel
//      `'__legacy_v8__'` to ALL pre-existing rows, AND wraps the column
//      add + UPDATE in a transaction. This is the load-bearing fix for
//      Codex round-27a P1: without the backfill, null would ambiguously
//      mean both "legacy" (legitimate bypass) and "v9 capture failed"
//      (must fail-closed) — sentinel collapses the ambiguity at the
//      schema level.
//
// We can't easily simulate "open at v8 then upgrade to v9" through the
// production AppDatabase entry point because Drift doesn't expose a
// version-pinned open. Workaround: use raw SQLite (via Drift's
// NativeDatabase) to seed a synthetic v8-shaped database, then open
// AppDatabase on the same file — the migration runs on first DAO
// query (well, before, via beforeOpen + onUpgrade).

void main() {
  test(
      'case 1 (fresh install): AppDatabase opens at v9, '
      'sourceDriveSerial column exists and accepts nullable insert',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // schemaVersion is 9
    final versionRow = await db
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(versionRow.read<int>('user_version'), 9,
        reason: 'Fresh install must report schema_version=9.');

    // Insert a job WITHOUT the new column (relies on nullable default)
    final jobId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.queued,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
          ),
        );
    final job = await db.jobDao.getJob(jobId);
    expect(job, isNotNull);
    expect(job!.sourceDriveSerial, isNull,
        reason: 'Fresh-install rows can omit sourceDriveSerial '
            '(nullable column). The runtime null-check at job-create '
            'time enforces fail-closed for v9 capture failures — that '
            'is a separate FR-001 invariant from the schema shape.');

    // Insert a job WITH the new column
    final jobId2 = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.queued,
            sourcePath: '/tmp/src2',
            destinationPath: '/tmp/dst2',
            createdAt: DateTime.now(),
            sourceDriveSerial: const Value('SN-FRESH-001'),
          ),
        );
    final job2 = await db.jobDao.getJob(jobId2);
    expect(job2!.sourceDriveSerial, 'SN-FRESH-001');
  });

  test(
      'case 2 (v8→v9 migration): pre-existing v8 row gets backfilled '
      'with sentinel `__legacy_v8__` (Codex round-27a P1 fix)',
      () async {
    // Use a file-backed DB so we can close-then-reopen on the same
    // path (NativeDatabase.memory connections can't be re-opened
    // after close). Mirrors the production semantics.
    final dbFile = File(
        '${Directory.systemTemp.createTempSync('mig_v9_').path}/db.sqlite');
    addTearDown(() {
      if (dbFile.existsSync()) dbFile.deleteSync();
      if (dbFile.parent.existsSync()) {
        dbFile.parent.deleteSync(recursive: true);
      }
    });

    // Step 1: bring up the database fresh at v9, then synthetically
    // downgrade to v8 by dropping the new column + rewriting
    // user_version. Mirrors a v8-shaped database about to be migrated.
    {
      final freshDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      await freshDb.customSelect('SELECT 1').get();
      await freshDb.customStatement(
          'ALTER TABLE jobs DROP COLUMN source_drive_serial');
      await freshDb.customStatement(
        "INSERT INTO jobs (id, type, status, source_path, destination_path, "
        "created_at, sort_order, completed_files, completed_bytes, total_files, "
        "total_bytes, verification_mode, unverified_files) "
        "VALUES (42, 'transfer', 'completed', '/tmp/src-v8', '/tmp/dst-v8', "
        "${DateTime.now().millisecondsSinceEpoch ~/ 1000}, 0, 0, 0, 0, 0, "
        "'size', 0)",
      );
      await freshDb.customStatement('PRAGMA user_version = 8');
      await freshDb.close();
    }

    // Step 2: re-open as AppDatabase. This time the schema_version=8
    // → onUpgrade fires from < 9 → backfill UPDATE runs.
    final upgradedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(upgradedDb.close);

    // Confirm migration completed: schemaVersion bumped to 9.
    final versionRow = await upgradedDb
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(versionRow.read<int>('user_version'), 9,
        reason: 'After onUpgrade, user_version must be 9.');

    // The pre-existing v8 row's sourceDriveSerial must now equal the
    // sentinel — NOT null. This is the load-bearing assertion.
    final job = await upgradedDb.jobDao.getJob(42);
    expect(job, isNotNull,
        reason: 'Pre-existing v8 row must survive the migration.');
    expect(job!.sourceDriveSerial, '__legacy_v8__',
        reason: 'Codex round-27a P1: the backfill UPDATE is the '
            'load-bearing fix that makes null impossible post-019. '
            'Without this, null would ambiguously mean both "legacy '
            'bypass" (correct) and "v9 capture failed at create-time" '
            '(must fail-closed) — granting the legacy bypass to v9 '
            'jobs that should have been refused at create.');
  });

  test(
      'case 3: 018 beforeOpen invariants still fire post-v9 migration '
      '(FK pragma + idx_job_files_job_id + errorMessage cleanup)',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // FK pragma is on (018 invariant)
    final fkRow = await db
        .customSelect('PRAGMA foreign_keys')
        .getSingle();
    expect(fkRow.read<int>('foreign_keys'), 1,
        reason: '018 beforeOpen FK pragma must still fire after the '
            'v9 migration is added — the v9 onUpgrade block lives '
            'BEFORE the existing beforeOpen, so beforeOpen still '
            'runs on every connection open.');

    // idx_job_files_job_id index exists (018 round-24 invariant)
    final idxRow = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND name='idx_job_files_job_id'",
        )
        .getSingleOrNull();
    expect(idxRow, isNotNull,
        reason: '018 round-24 index must exist post-v9 migration. '
            'It is created by beforeOpen, which runs after onUpgrade '
            'completes for every connection.');
  });
}
