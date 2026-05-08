# Quickstart: Executor Correctness (v2.5.0)

**Feature**: 017-executor-correctness | **Phase**: 1 (Design)
**Audience**: Developer joining mid-feature or maintaining post-merge
**Date**: 2026-05-08

## TL;DR

Four PowerShell call sites in `lib/services/` were broken because `Process.run` doesn't populate `$args[0]` from a trailing argv element. Fix uses single-quote escape inside the `-Command` script string. Progress counters used to gate on verification success; now they advance after copy and verify is a separate axis. Schema v8 adds `JobFile.verifyStatus`, `JobFile.failureKind`, `Job.unverifiedFiles`, `AppSettings.sourcesPanelCollapsed`. New `LogService` API takes named context params; old one-arg calls still work.

## How to call PowerShell from Dart correctly

**Old (broken):**
```dart
arguments: ['-NoProfile', '-Command', r'... $args[0] ...', filePath]
```
The trailing `filePath` is silently ignored. `$args[0]` is empty inside the script.

**New (correct):**
```dart
import 'package:copiatorul3000/utils/process_runner.dart';

final exitCode = await runner.runPowerShellInlineScript(
  script: "(Get-FileHash -LiteralPath '${escapePsLiteral(filePath)}' -Algorithm SHA256).Hash",
  tag: 'computeFileHash',
);
```

The helper asserts `arguments.length == 3` (a permanent invariant). If you find yourself adding a 4th argv element, you're back to the broken pattern — read this doc again.

`escapePsLiteral` lives in `lib/utils/ps_escape.dart` and is `s.replaceAll("'", "''")`. PS single-quoted strings + `-LiteralPath` make the path verbatim — no `$var`, no backtick, no wildcard interpretation.

## How to add a new logged event

```dart
logService.info(
  'Transfer phase complete',
  jobId: job.id,
  fileIndex: job.totalFiles,
  totalFiles: job.totalFiles,
  phase: LogPhase.transfer,
);
```

`LogPhase` enum: `enqueue`, `preflight`, `transfer`, `verify`, `compress`, `finalize`, `recover`, `shutdown`.

Format on disk: `[2026-05-08 14:23:45] [INFO] [job=1 file=27/27 phase=transfer] Transfer phase complete`.

If you have nothing to add as context, the old one-arg call still works:
```dart
logService.info('App started');
// → [2026-05-08 14:00:00] [INFO] App started
```

For errors with subprocess output, pass raw stderr via the `subprocessStderr` param — `LogService.error` handles single-line truncation to 200 chars internally (no per-call-site burden):
```dart
logService.error(
  'computeFileHash exit=$exitCode for "$path"',
  jobId: job.id,
  fileIndex: index,
  totalFiles: total,
  phase: LogPhase.verify,
  subprocessStderr: stderr,           // raw — LogService truncates
);
// → [..] [ERROR] [job=1 file=03/27 phase=verify] computeFileHash exit=1 for "...": <first line, ≤200 chars>…
```

Never log multi-line dumps yourself. If you find a call site doing manual truncation, migrate it to use `subprocessStderr`.

## How to query verify status

```dart
// Files in this job that need investigation:
final mismatched = await jobFileDao.getFilesByVerifyStatus(job.id, VerifyStatus.mismatch);
final unverified = await jobFileDao.getFilesByVerifyStatus(job.id, VerifyStatus.unverified);

// "Trustworthy" file count for the active job card header:
final completedFiles = job.completedFiles;       // includes unverified
final verifiedFiles = job.completedFiles - job.unverifiedFiles - mismatched.length;
```

**Note**: the pre-existing `JobFile.verified` boolean (v5) is preserved alongside the new `verifyStatus` enum. Old UI code (e.g. file-detail badges from feature 014) reads `verified`; new code reads `verifyStatus` for granular state. A v2.6 cleanup will remove the boolean once all readers migrate.

**Compression jobs** (`Job.type == JobType.compression`): `verifyStatus` stays at `pending` for these rows because no transfer occurs. Hide verify counters in the UI:

```dart
final showVerifyCounters = job.type != JobType.compression;
```

For `JobType.transferAndCompress`, `verifyStatus` describes the transfer-phase verification result and persists across the compression phase.

## How to handle operator-driven Retry on verify mismatch

```dart
// In the active card's banner action handler:
Future<void> onRetryAfterMismatch(JobFile file) async {
  await jobQueueService.retryFile(file.id, forceDestDelete: true);
}
```

`forceDestDelete=true` threads through `_processTransfer` so the destination is deleted before robocopy regardless of size match — closes the infinite-loop where same-size corrupt destination is silently re-verified.

For non-mismatch retries (e.g. `failureKind=copyError`), use `forceDestDelete=false` (default). Robocopy `/Z` resumes; the existing delete predicate `wasOverwriteApproved || (everAttempted && isPartial)` handles legitimate partial cleanup.

## Schema v8 migration — running locally

Drop and recreate (development only):
```bash
rm -f ~/Library/Application\ Support/copiatorul3000/copiatorul3000.db    # macOS
rm -f %APPDATA%\copiatorul3000\copiatorul3000.db                           # Windows
```

Re-run the app; Drift bootstraps a fresh v8 DB.

To test the migration on a v7 dump:
```bash
cp ~/Documents/copiatorul3000-v2.4.0-prod.db /tmp/test.db
flutter run --dart-define=COPIATORUL_DB_PATH=/tmp/test.db
# Confirm v8 columns populated as expected via sqlite3 /tmp/test.db
```

Backfill rules are documented in [data-model.md](./data-model.md). Migration is wrapped in a single Drift `transaction` block — mid-migration crash leaves DB at v7.

## How to recover a job stuck in "copied + pending"

This case happens when shutdown fires between robocopy success and SHA-256 verification. On next launch, `JobQueueService.recoverStaleJobs` detects these rows and routes them to verify-only:

```dart
// In recoverStaleJobs (job_queue_service.dart):
final staleVerifyRows = await jobFileDao.getFilesByStateAndVerify(
  status: FileStatus.completed,
  verifyStatus: VerifyStatus.pending,
);

for (final file in staleVerifyRows) {
  if (await File(file.sourcePath).exists() && await File(file.destPath).exists()) {
    // Re-enter verify phase; do not re-copy
    await jobQueueService.queueVerifyOnly(file.id);
  } else {
    // Source or dest gone — mark unverified, surface to operator
    await jobFileDao.markFileUnverified(file.id, reason: 'source or destination missing on recovery');
    logService.warning(
      'Cannot verify recovered file (source or dest missing)',
      jobId: file.jobId,
      filename: file.sourcePath,
      phase: LogPhase.recover,
    );
  }
}

// Re-derive job counters from per-file state (FR-007)
await jobDao.recomputeCountersFromFiles(file.jobId);
```

## Test invariants

```bash
# 1. No remaining $args[0] usages — permanent CI guard
! grep -rn '\$args\[' lib/

# 2. Hash escape unit tests
flutter test test/unit/ps_escape_test.dart

# 3. PowerShell argv-shape regression test (works on macOS via Process.start mock)
flutter test test/unit/process_runner_argv_test.dart

# 4. Progress decoupling (mocks hash subprocess to fail)
flutter test test/unit/progress_decouple_test.dart

# 5. Recovery (status=copied + verifyStatus=pending → verify-only)
flutter test test/unit/recovery_test.dart

# 6. Case-only collision normalization
flutter test test/unit/collision_normalize_test.dart

# 7. Log format goldens (per level × phase)
flutter test test/unit/log_format_test.dart

# 8. _PlannedFile shape contract (consumed by JobQueueService AND CreateJobScreen)
flutter test test/contract/planned_file_contract_test.dart

# 9. Lint and analyze
flutter analyze
```

## Operator's Windows acceptance scenario (the SC-001/SC-002 test)

1. Insert SD card with 27 files / 161 GB containing paths with spaces and special characters.
2. Start a transferAndCompress job to `E:\Studio Termene\Brut - To compress\test\Canon_Reels_H`.
3. Watch the active job card during transfer phase: progress bar advances, file counter ticks `1/27 → 2/27 → …`, phase indicator says "Transfer".
4. After transfer phase, file counter resets to verify count: `1/27 verified` rises as each hash check passes.
5. Open the log: every phase boundary and per-file success is INFO-level with `[job=1 file=K/27 phase=…]` prefix.
6. No PowerShell parser errors anywhere in the log.

If steps 3–5 don't behave as described, this feature has regressed. File a bug citing this quickstart.
