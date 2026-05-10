import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/database/database.dart';
import 'package:video_pipeline/database/tables.dart';
import 'package:video_pipeline/services/slack_service.dart';

// 018 T016 (FR-014, US5, P3, SC-009): Slack truthfulness on size-mode
// transfers.
//
// The bug closed by T014 + T015 + T024: a clean default size-mode
// transfer (every file at verifyStatus=notVerified, 0 SHA-256-verified)
// rendered the bare-zero passed-label "Verification: Size — Passed"
// with the body line "Verified: 0 · Unverified: 0 · Mismatch: 0" —
// operator-confusing wording that visually reads like nothing got
// verified when in fact every file passed the size-only check.
//
// Tests target [SlackService.formatTransferCompletedBody], the
// `@visibleForTesting` pure static that the runtime
// [notifyTransferCompleted] delegates to. Pure-static testing avoids
// booting the global LogService singleton and the Dio mock dance, and
// is a sharper assertion of the contract under test (the wording).

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<Job> seedJob({
    required VerificationMode mode,
    int totalFiles = 5,
  }) async {
    final id = await db.into(db.jobs).insert(
          JobsCompanion.insert(
            type: JobType.transfer,
            status: JobStatus.completed,
            sourcePath: '/tmp/src',
            destinationPath: '/tmp/dst',
            createdAt: DateTime.now(),
            startedAt: Value(DateTime.now()),
            verificationMode: Value(mode),
            totalFiles: Value(totalFiles),
            totalBytes: Value(totalFiles * 1024),
          ),
        );
    return (await db.jobDao.getJob(id))!;
  }

  test(
      'case 1: clean size-mode transfer (5 files, all notVerified) — '
      'body uses "5 size-verified · Passed" wording', () async {
    final job = await seedJob(mode: VerificationMode.size);
    final body = SlackService.formatTransferCompletedBody(
      job: job,
      completedFiles: 5,
      verifiedFiles: 0,
      unverifiedFiles: 0,
      mismatchedFiles: 0,
      notVerifiedFiles: 5,
    );

    expect(body.contains('5 size-verified · Passed'), isTrue,
        reason: 'Clean size-mode transfer must use the round-20-mirror '
            'passed-label phrasing. Without this fix the body would '
            'render "Verification: Size — Passed" with a "Verified: 0" '
            'body line — operator-confusing.');
    expect(body.contains('Size-only: 5'), isTrue,
        reason: 'Body counter line must surface the size-only count '
            'distinctly so the operator can audit the verify-axis '
            'breakdown.');
    expect(body.startsWith('✅'), isTrue,
        reason: 'Clean run uses ✅, not ⚠.');
  });

  test(
      'case 2: clean SHA-256 transfer (5 files, all verified) — body '
      'preserves "5 verified · Passed" (round-20 regression check)',
      () async {
    final job = await seedJob(mode: VerificationMode.sha256);
    final body = SlackService.formatTransferCompletedBody(
      job: job,
      completedFiles: 5,
      verifiedFiles: 5,
      unverifiedFiles: 0,
      mismatchedFiles: 0,
      notVerifiedFiles: 0,
    );

    expect(body.contains('5 verified · Passed'), isTrue,
        reason: 'Pure SHA-256 transfers must keep the established '
            'round-20 phrasing. The T014 signature change must NOT '
            'regress this.');
    // Codex round-24 P3: case-sensitive check. The body field is
    // "Size-only" (capitalized); the prior `body.contains('size-only')`
    // assertion was a false negative because it asked for the
    // lowercase form. The field is omitted entirely when the count is
    // zero, so a pure SHA-256 run must contain neither variant.
    expect(body.contains('Size-only'), isFalse,
        reason: 'No size-only count on a pure SHA-256 run. The '
            'Size-only field is omitted entirely (not rendered as '
            '"Size-only: 0") to preserve the "behavior unchanged for '
            'SHA-256-only transfers" promise.');
    expect(body.toLowerCase().contains('size-only'), isFalse,
        reason: 'Belt-and-braces lowercase check.');
  });

  test(
      'case 3: mixed history (3 verified + 2 size-only) — body shows '
      'BOTH counts in "A verified + B size-only · Passed" form', () async {
    final job = await seedJob(mode: VerificationMode.sha256, totalFiles: 5);
    final body = SlackService.formatTransferCompletedBody(
      job: job,
      completedFiles: 5,
      verifiedFiles: 3,
      unverifiedFiles: 0,
      mismatchedFiles: 0,
      notVerifiedFiles: 2,
    );

    expect(body.contains('3 verified + 2 size-only · Passed'), isTrue,
        reason: 'Mixed-history runs (e.g., a resumed job that crossed a '
            'verification-mode change) must surface both axes so the '
            'operator can audit which files have cryptographic trust '
            'and which only have size-only trust.');
  });

  test(
      'case 4: warning state still surfaces correctly (regression — '
      'mismatchedFiles > 0 takes priority over passed-label)', () async {
    final job = await seedJob(mode: VerificationMode.sha256);
    final body = SlackService.formatTransferCompletedBody(
      job: job,
      completedFiles: 5,
      verifiedFiles: 4,
      unverifiedFiles: 0,
      mismatchedFiles: 1,
      notVerifiedFiles: 0,
    );

    expect(body.startsWith('⚠'), isTrue,
        reason: 'Warning emoji must fire when mismatchedFiles > 0 '
            'regardless of how the passed-label would have rendered. '
            'This is the T014 invariant that the new passed-label '
            'logic does NOT reach when in warning state.');
    expect(body.contains('1 file(s) FAILED verification'), isTrue);
    expect(body.contains('Passed'), isFalse,
        reason: 'No "Passed" wording when verification failed.');
  });
}
