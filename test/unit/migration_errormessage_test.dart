import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/tables.dart';

// 018 T019 (FR-012, US5, P3, SC-007): stale-errorMessage cleanup on
// jobs whose status was lifted from `failed` to `completed` because
// their only failed children were hash-only failures.
//
// Two paths produce the cleanup, both running the SAME SQL:
//   - Migration Phase 7 (T017): runs once during v7→v8 migration.
//     Extends the existing Phase 7 SET clause (`status='completed'`)
//     to also write `error_message=NULL`.
//   - Connection-open hook (T018): runs on every AppDatabase open,
//     idempotent. Catches existing-v8 testers retroactively (the
//     migration itself is `from < 8` so it doesn't re-fire for them).
//
// We test the SHARED SQL via the connection-open path because:
//   - It's the path that actually exercises in production for any
//     v8-pre-this-feature operator.
//   - Phase 7 uses the same SET clause + WHERE clause as the
//     connection-open statement; if the SQL is correct in one path
//     it's correct in the other.
//   - Testing Phase 7 directly would require simulating a v7 schema
//     (separate codegen + manual migration plumbing), and the
//     coverage gain over the shared-SQL test is zero.
//
// Cases:
//   1. Job that matches the lift criteria (status=completed already,
//      file rows show mismatch/unverified verify states, no
//      status=failed file rows) AND has a stale error_message:
//      re-opening AppDatabase observably nulls error_message.
//   2. Job that does NOT match the lift criteria (e.g. has a
//      status=failed file row in addition to mismatch verify states):
//      error_message must NOT be cleared. The cleanup is scoped.
//   3. Idempotency: re-opening a third time after the cleanup is a
//      no-op (no spurious writes; row stays clean).

void main() {
  late File dbFile;

  setUp(() {
    dbFile = File(
        '${Directory.systemTemp.createTempSync('migration_errmsg_').path}/db.sqlite');
  });

  tearDown(() {
    if (dbFile.existsSync()) dbFile.deleteSync();
    if (dbFile.parent.existsSync()) {
      dbFile.parent.deleteSync(recursive: true);
    }
  });

  // Seed a job + file row(s) directly (bypassing DAO guards). All
  // inserts happen within the FIRST AppDatabase open; we then close
  // and re-open to trigger the beforeOpen cleanup on the populated
  // database.
  Future<int> seedLiftedJobWithStaleMessage(
    AppDatabase db, {
    required List<VerifyStatus> fileVerifyStatuses,
    required List<FileStatus> fileStatuses,
    String staleMessage = '5/10 files transferred, 5 failed copy',
  }) async {
    assert(fileVerifyStatuses.length == fileStatuses.length);

    // Insert the job in the post-Phase-7-lift shape: status=completed
    // but error_message still populated (the bug being fixed).
    final jobId = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.completed,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
            errorMessage: Value(staleMessage),
          ),
        );

    for (var i = 0; i < fileStatuses.length; i++) {
      await db.into(db.jobFiles).insert(
            JobFilesCompanion.insert(
              jobId: jobId,
              sourceFilePath: '/tmp/src/IMG_$i.MP4',
              destinationFilePath: '/tmp/dst/IMG_$i.MP4',
              fileName: 'IMG_$i.MP4',
              fileSize: 1024,
              status: fileStatuses[i],
              verifyStatus: Value(fileVerifyStatuses[i]),
            ),
          );
    }
    return jobId;
  }

  test(
      'case 1: job matching lift criteria with stale error_message gets '
      'cleared on re-open (T017 + T018 shared SQL)', () async {
    int jobId;
    {
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      jobId = await seedLiftedJobWithStaleMessage(
        db,
        // 5 files at mismatch (post-SHA-256-mismatch state).
        fileVerifyStatuses: List.filled(5, VerifyStatus.mismatch),
        fileStatuses: List.filled(5, FileStatus.completed),
      );
      // Sanity: pre-cleanup the message is present.
      final pre = await db
          .customSelect('SELECT error_message FROM jobs WHERE id = ?',
              variables: [Variable.withInt(jobId)])
          .getSingle();
      expect(pre.read<String?>('error_message'),
          '5/10 files transferred, 5 failed copy');
      await db.close();
    }

    // Re-open. beforeOpen runs the cleanup statement.
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    final post = await db
        .customSelect('SELECT error_message FROM jobs WHERE id = ?',
            variables: [Variable.withInt(jobId)])
        .getSingle();
    expect(post.read<String?>('error_message'), isNull,
        reason: 'beforeOpen cleanup must NULL error_message on jobs '
            'that match the Phase-7 lift criteria. UI surfaces reading '
            'this field MUST NOT show stale "X failed copy" text on a '
            'job marked as completed.');
  });

  test(
      'case 2: job NOT matching lift criteria (has a failed file row) '
      'keeps its error_message intact', () async {
    int jobId;
    {
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      jobId = await seedLiftedJobWithStaleMessage(
        db,
        // 1 mismatch (verify warning) + 1 status=failed (real copy
        // failure). The cleanup MUST NOT touch this row because the
        // failed file row means the job is genuinely a failure case
        // — Phase 7's lift criteria specifically excludes jobs with
        // status=failed children.
        fileVerifyStatuses: const [
          VerifyStatus.mismatch,
          VerifyStatus.pending,
        ],
        fileStatuses: const [
          FileStatus.completed,
          FileStatus.failed,
        ],
        staleMessage: '1 file failed to copy',
      );
      await db.close();
    }

    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    final post = await db
        .customSelect('SELECT error_message FROM jobs WHERE id = ?',
            variables: [Variable.withInt(jobId)])
        .getSingle();
    expect(post.read<String?>('error_message'), '1 file failed to copy',
        reason: 'Cleanup is scoped to lift-criteria-matching jobs. A '
            'job with a status=failed file row is genuinely failed and '
            'its error_message must be preserved.');
  });

  test(
      'case 3: idempotency — a second re-open after cleanup is a no-op',
      () async {
    int jobId;
    {
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      jobId = await seedLiftedJobWithStaleMessage(
        db,
        fileVerifyStatuses: const [VerifyStatus.unverified],
        fileStatuses: const [FileStatus.completed],
      );
      await db.close();
    }

    // First re-open clears the message.
    {
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      final cleared = await db
          .customSelect('SELECT error_message FROM jobs WHERE id = ?',
              variables: [Variable.withInt(jobId)])
          .getSingle();
      expect(cleared.read<String?>('error_message'), isNull);
      await db.close();
    }

    // Second re-open: the row is already clean. The cleanup statement
    // has `error_message IS NOT NULL` in its WHERE clause, so it
    // matches zero rows and writes nothing.
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    final stillClean = await db
        .customSelect('SELECT error_message FROM jobs WHERE id = ?',
            variables: [Variable.withInt(jobId)])
        .getSingle();
    expect(stillClean.read<String?>('error_message'), isNull,
        reason: 'Second re-open should be a no-op; the row stays '
            'in its post-cleanup state.');
  });
}
