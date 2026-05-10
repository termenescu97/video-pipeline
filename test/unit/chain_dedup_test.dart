import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/daos/job_dao.dart';
import 'package:video_pipeline/database/daos/job_file_dao.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/services/compression_service.dart';
import 'package:video_pipeline/services/drive_service.dart';
import 'package:video_pipeline/services/job_queue_service.dart';
import 'package:video_pipeline/services/slack_service.dart';
import 'package:video_pipeline/services/transfer_service.dart';

// 018 T011 (FR-007, US3, P2, SC-003): chain-creation dedup under
// concurrent invocations.
//
// `createChainedCompressionJobIfAbsent` wraps `hasChainedChild` +
// the validation gate + the chained-job INSERT in a single Drift
// transaction. Two paired-fire calls against the same parent (the
// realistic operator pattern: clicks Accept-mismatched then
// Accept-unverified before the first handler completes) MUST
// produce exactly ONE chained child.
//
// The test seeds a transferAndCompress parent in JobStatus.completed
// with all files at clean verify states (verified or notVerified),
// then dispatches N concurrent gate calls and asserts the final
// child count is 1.

void main() {
  late AppDatabase db;
  late JobDao jobDao;
  late JobFileDao jobFileDao;
  late JobQueueService queue;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    jobDao = db.jobDao;
    jobFileDao = db.jobFileDao;
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(), mode: InsertMode.insertOrIgnore);

    queue = JobQueueService(
      jobDao: jobDao,
      jobFileDao: jobFileDao,
      slackService: SlackService(settingsDao: db.settingsDao),
      transferService: TransferService(),
      compressionService: CompressionService(),
      driveService: DriveService(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedReadyParent() async {
    // transferAndCompress parent in JobStatus.completed with one file
    // at status=completed + verifyStatus=notVerified (size-mode
    // baseline). All gate predicates pass.
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transferAndCompress,
        status: JobStatus.completed,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        compressionOutputPath: const Value(r'E:\compressed'),
        presetName: const Value('Fast 1080p30'),
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.size),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_001.MP4',
          destinationFilePath: r'E:\dest\IMG_001.MP4',
          fileName: 'IMG_001.MP4',
          fileSize: 1_000_000_000,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1_000_000_000,
    );

    // Walk the file row to a clean size-mode-completed state.
    final fileId = (await jobFileDao.getFilesForJob(jobId)).single.id;
    await jobFileDao.markFileStarted(fileId);
    await jobFileDao.markFileSizeOnlyVerified(fileId);

    return jobId;
  }

  test(
      'two paired-fire calls produce exactly ONE chained child '
      '(SC-003 baseline)', () async {
    final parentId = await seedReadyParent();

    // Fire BOTH calls back-to-back without awaiting either. They both
    // enter the gate concurrently. SQLite's BEGIN IMMEDIATE serializes
    // the transactions; the second one's `hasChainedChild` check
    // observes the first's INSERT and bails.
    final results = await Future.wait([
      queue.createChainedCompressionJobIfAbsent(parentId),
      queue.createChainedCompressionJobIfAbsent(parentId),
    ]);

    final children = await (db.select(db.jobs)
          ..where((t) => t.parentJobId.equals(parentId)))
        .get();
    expect(children.length, 1,
        reason: 'Exactly one chained compression child must be '
            'created, regardless of paired-fire timing.');

    // Exactly one of the two calls should have returned a non-null id;
    // the other should have observed the first's insert and returned
    // null (dedup hit inside the transaction).
    final nonNull = results.where((r) => r != null).toList();
    expect(nonNull.length, 1,
        reason: 'One of the two paired calls returns the new child id; '
            'the other returns null on dedup hit.');
    expect(nonNull.single, children.single.id);
  });

  test(
      'N=10 paired calls still produce exactly ONE chained child '
      '(stress matrix)', () async {
    final parentId = await seedReadyParent();

    final results = await Future.wait(List.generate(
        10, (_) => queue.createChainedCompressionJobIfAbsent(parentId)));

    final children = await (db.select(db.jobs)
          ..where((t) => t.parentJobId.equals(parentId)))
        .get();
    expect(children.length, 1,
        reason: 'N=10 concurrent calls must dedup to a single child.');
    expect(results.where((r) => r != null).length, 1);
  });

  test(
      'subsequent call after the first commit also returns null '
      '(dedup persists across non-concurrent invocations)', () async {
    final parentId = await seedReadyParent();

    final first = await queue.createChainedCompressionJobIfAbsent(parentId);
    expect(first, isNotNull);

    final second =
        await queue.createChainedCompressionJobIfAbsent(parentId);
    expect(second, isNull,
        reason: 'A serialized second call sees the persisted child '
            'and returns null without creating a duplicate.');

    final children = await (db.select(db.jobs)
          ..where((t) => t.parentJobId.equals(parentId)))
        .get();
    expect(children.length, 1);
  });

  test(
      'gate refuses to chain when the parent has unresolved verify '
      'warnings (defense-in-depth check inside transaction)', () async {
    // Same parent, but one file is at verifyStatus=mismatch. The gate
    // must return null even though `hasChainedChild` is false.
    final jobId = await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: JobType.transferAndCompress,
        status: JobStatus.completed,
        sourcePath: r'H:\',
        destinationPath: r'E:\dest',
        compressionOutputPath: const Value(r'E:\compressed'),
        presetName: const Value('Fast 1080p30'),
        createdAt: DateTime.now(),
        verificationMode: const Value(VerificationMode.sha256),
      ),
      buildFiles: (jId) => [
        JobFilesCompanion.insert(
          jobId: jId,
          sourceFilePath: r'H:\DCIM\IMG_002.MP4',
          destinationFilePath: r'E:\dest\IMG_002.MP4',
          fileName: 'IMG_002.MP4',
          fileSize: 1_000_000_000,
          status: FileStatus.pending,
        ),
      ],
      totalBytes: 1_000_000_000,
    );
    final fileId = (await jobFileDao.getFilesForJob(jobId)).single.id;
    await jobFileDao.markFileStarted(fileId);
    await jobFileDao.markFileCompleted(fileId, verified: false);
    await jobFileDao.markFileVerifyMismatch(
      fileId,
      sourceHash: 'a' * 64,
      destHash: 'b' * 64,
    );

    final result = await queue.createChainedCompressionJobIfAbsent(jobId);
    expect(result, isNull);

    final children = await (db.select(db.jobs)
          ..where((t) => t.parentJobId.equals(jobId)))
        .get();
    expect(children, isEmpty);
  });
}
