import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/tables.dart';

// 018 T013 (FR-009 + FR-010, US4, P2, SC-005): foreign-key
// enforcement + retroactive dangling-reference cleanup.
//
// The source change for this user story shipped in checkpoint 1
// (T001 — beforeOpen hook in lib/database/database.dart). This test
// pins the externally-observable contract:
//
//   1. Every AppDatabase open observably has PRAGMA foreign_keys=ON.
//   2. The same is true for AppDatabase.forTesting (research R2's
//      test-coverage requirement).
//   3. A pre-existing dangling parent_job_id (simulating an operator
//      who deleted a parent job during the era when the FK constraint
//      was dead code) is cleaned to NULL on first open after this
//      release. Idempotent — re-opens after cleanup remain a no-op.
//   4. After the pragma is on, attempting to insert a NEW dangling
//      reference is rejected by SQLite.
//   5. Deleting an existing parent that has a chained child observably
//      sets the child's parent_job_id to NULL (FK ON DELETE SET NULL
//      annotation now actually fires).
//
// To simulate (3) we open the SAME SQLite file via two AppDatabase
// instances. The first one runs beforeOpen (cleanup no-op on a
// fresh DB, then sets pragma=ON), then the test FLIPS the pragma
// off via `customStatement('PRAGMA foreign_keys = OFF')` for the
// remainder of that connection — SQLite's pragma is per-connection,
// so this is supported natively. With FK off we INSERT a parent +
// child and DELETE the parent, leaving the child with a dangling
// reference that mirrors what an operator's pre-release v8 database
// carries today. We close, re-open via a fresh AppDatabase. The
// second open's beforeOpen runs the dangling-FK cleanup BEFORE the
// pragma flip, so the child's parent_job_id is observably NULL
// after the open.
//
// Earlier draft of this test reached for `package:sqlite3` to do
// the FK-off seeding. That added a direct dev_dependency, pinned
// the test to an older sqlite3 (drift's transitive at the time
// only resolves to ^2.x), and required a `// ignore:
// deprecated_member_use` for `dispose()` instead of `close()`.
// Three smells stacked. Switched to per-connection PRAGMA toggle —
// zero extra dependencies, no ignore comments, fewer moving parts.

void main() {
  late File dbFile;

  setUp(() {
    dbFile = File(
        '${Directory.systemTemp.createTempSync('fk_pragma_').path}/db.sqlite');
  });

  tearDown(() {
    if (dbFile.existsSync()) dbFile.deleteSync();
    if (dbFile.parent.existsSync()) {
      dbFile.parent.deleteSync(recursive: true);
    }
  });

  Future<int> readPragmaForeignKeys(AppDatabase db) async {
    final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
    return row.read<int>('foreign_keys');
  }

  test('case 1: fresh AppDatabase open has PRAGMA foreign_keys = 1',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(await readPragmaForeignKeys(db), 1,
        reason: 'beforeOpen hook (T001) must enable FK enforcement on '
            'every connection-open, including via NativeDatabase + a '
            'real file.');
  });

  test(
      'case 2: AppDatabase.forTesting via in-memory connection ALSO has '
      'pragma enabled (research R2 test-coverage requirement)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(await readPragmaForeignKeys(db), 1,
        reason: 'In-memory test-only connections must respect the same '
            'beforeOpen contract as production.');
  });

  test(
      'case 3: pre-existing dangling parent_job_id is cleaned to NULL on '
      'first open after this release (idempotent on subsequent opens)',
      () async {
    // Phase 1: open AppDatabase to create the schema. beforeOpen
    // sets pragma=ON. Then flip the pragma off FOR THIS CONNECTION
    // via customStatement (SQLite supports per-connection pragmas
    // natively), insert parent + child, DELETE the parent — child
    // now carries a dangling reference. This mirrors the pre-release
    // state of an operator's database where the FK constraint
    // annotation existed but enforcement was never on.
    {
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.customStatement(
        "INSERT INTO jobs (id, type, status, source_path, "
        "destination_path, created_at, sort_order, completed_files, "
        "completed_bytes, total_files, total_bytes, verification_mode, "
        "unverified_files) "
        "VALUES (100, 'transferAndCompress', 'completed', '/tmp/src', "
        "'/tmp/dst', ${DateTime.now().millisecondsSinceEpoch ~/ 1000}, "
        "0, 0, 0, 0, 0, 'size', 0)",
      );
      await db.customStatement(
        "INSERT INTO jobs (id, type, status, source_path, "
        "destination_path, created_at, sort_order, completed_files, "
        "completed_bytes, total_files, total_bytes, verification_mode, "
        "unverified_files, parent_job_id) "
        "VALUES (200, 'compression', 'queued', '/tmp/dst', '/tmp/out', "
        "${DateTime.now().millisecondsSinceEpoch ~/ 1000}, 1, 0, 0, 0, "
        "0, 'size', 0, 100)",
      );
      await db.customStatement('DELETE FROM jobs WHERE id = 100');
      // Sanity check the dangling state pre-cleanup.
      final danglingRow = await db
          .customSelect('SELECT parent_job_id FROM jobs WHERE id = 200')
          .getSingle();
      expect(danglingRow.read<int?>('parent_job_id'), 100,
          reason: 'Pre-cleanup the child still references the deleted '
              'parent (FK was off for this connection).');
      await db.close();
    }

    // Phase 2: re-open via a fresh AppDatabase. beforeOpen runs the
    // dangling-FK cleanup BEFORE the pragma flip — child's
    // parent_job_id should be NULL.
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    final cleanedRow = await db
        .customSelect('SELECT parent_job_id FROM jobs WHERE id = 200')
        .getSingle();
    expect(cleanedRow.read<int?>('parent_job_id'), isNull,
        reason: 'beforeOpen cleanup must NULL the dangling reference '
            'before the FK pragma is flipped, so the operator never sees '
            'a deferred constraint failure.');
    expect(await readPragmaForeignKeys(db), 1,
        reason: 'After the cleanup, the pragma is on and stays on.');

    // Idempotency: a second open should also succeed cleanly with no
    // additional state changes (the cleanup statement is a no-op now).
    await db.close();
    final db2 = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db2.close);
    final stillCleanRow = await db2
        .customSelect('SELECT parent_job_id FROM jobs WHERE id = 200')
        .getSingle();
    expect(stillCleanRow.read<int?>('parent_job_id'), isNull);
    expect(await readPragmaForeignKeys(db2), 1);
  });

  test(
      'case 4: with pragma on, inserting a new dangling reference is '
      'rejected by SQLite', () async {
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    // No parent exists; attempt to insert a child that references id=99999.
    await expectLater(
      db.customStatement(
        "INSERT INTO jobs (id, type, status, source_path, destination_path, "
        "created_at, sort_order, completed_files, completed_bytes, total_files, "
        "total_bytes, verification_mode, unverified_files, parent_job_id) "
        "VALUES (300, 'compression', 'queued', '/tmp/src', '/tmp/dst', "
        "${DateTime.now().millisecondsSinceEpoch ~/ 1000}, 0, 0, 0, 0, 0, "
        "'size', 0, 99999)",
      ),
      throwsA(predicate((e) =>
          e.toString().toLowerCase().contains('foreign key') ||
          e.toString().toLowerCase().contains('constraint'))),
      reason: 'With FK pragma on, SQLite must reject any INSERT that '
          'creates a dangling parent_job_id reference.',
    );
  });

  test(
      'case 5: deleting an existing parent observably nulls the child '
      'parent_job_id (FK ON DELETE SET NULL fires)', () async {
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // Insert parent + child directly (bypassing the DAO's zero-files
    // guard which would reject parents with no JobFiles).
    final parentId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transferAndCompress,
            status: JobStatus.completed,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            compressionOutputPath: const Value('/tmp/out'),
            createdAt: DateTime.now(),
          ),
        );
    final childId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.compression,
            status: JobStatus.queued,
            sourcePath: '/tmp/dst',
            destinationPath: '/tmp/out',
            createdAt: DateTime.now(),
            parentJobId: Value(parentId),
          ),
        );

    // Confirm the link exists pre-delete.
    expect((await db.jobDao.getJob(childId))!.parentJobId, parentId);

    // Delete the parent. With pragma on AND ON DELETE SET NULL on the
    // FK annotation, the child's parent_job_id should observably
    // become NULL.
    await (db.delete(db.jobs)..where((t) => t.id.equals(parentId))).go();

    final child = await db.jobDao.getJob(childId);
    expect(child, isNotNull,
        reason: 'Child job is NOT deleted by ON DELETE SET NULL — only '
            'its FK column is nulled.');
    expect(child!.parentJobId, isNull,
        reason: 'FR-010: ON DELETE SET NULL must observably fire when '
            'the parent is deleted. This is the live-FK assertion that '
            'depends on T001 enabling the pragma.');
  });
}
