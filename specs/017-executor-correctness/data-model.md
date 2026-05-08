# Data Model: Executor Correctness (v2.5.0)

**Feature**: 017-executor-correctness | **Phase**: 1 (Design)
**Schema version**: v7 → **v8**
**Date**: 2026-05-08

## Schema diff

### `JobFile` — additions

Existing v7 columns (preserved unchanged): `id`, `jobId`, `sourceFilePath`, `destinationFilePath`, `fileName`, `fileSize`, `status` (textEnum<FileStatus>), **`verified`** (boolean — kept for backward-compat with existing UI), `errorMessage`, `startedAt`, `completedAt`, `sourceHash`, `destinationHash`, `wasOverwriteApproved` (v7).

```dart
class JobFiles extends Table {
  // ... v7 columns above ...

  /// NEW v8: Independent of `status` (which tracks copy state) and of the
  /// existing `verified` boolean (which `_processTransfer` sets after either
  /// size match OR SHA-256 match — granular semantics lost). The new enum
  /// surfaces 4 outcomes; `verified` boolean continues to mean "passed the
  /// configured verification mode" for legacy readers.
  ///
  ///   pending    — verification has not run or is in progress.
  ///   verified   — SHA-256 ran and source/dest hashes matched.
  ///   mismatch   — SHA-256 ran but bytes differ (real corruption — hard fail).
  ///   unverified — verification subsystem itself failed (PS broken, etc.) OR
  ///                size-only verification passed (no cryptographic trust).
  TextColumn get verifyStatus => textEnum<VerifyStatus>()
      .withDefault(const Constant('pending'))
      .named('verify_status')();

  /// NEW v8: Routes retry behavior. None for files that haven't failed.
  ///   copyError       — robocopy exited non-zero or threw IO error.
  ///   verifyMismatch  — SHA-256 mismatch (force re-copy on retry per FR-005).
  ///   verifyUnreliable — hash subsystem error (NOT a hard fail; warning state).
  TextColumn get failureKind => textEnum<FailureKind>()
      .withDefault(const Constant('none'))
      .named('failure_kind')();
}
```

**Why `textEnum` (not `intEnum`)**: matches existing schema convention (`status`, `type`, `verificationMode` are all `textEnum`). Migration backfill UPDATEs use string literals (`'verified'`, `'mismatch'`, etc.), which is required by Drift's text-encoded enum representation (it stores `enum.name`, not the ordinal index).

**Compression-only jobs** (`Job.type = JobType.compression`): `verifyStatus` stays at `pending` for these rows because no transfer occurs. UI hides verify-related counters when `Job.type == JobType.compression`. For `transferAndCompress` jobs, `verifyStatus` describes the TRANSFER-phase verification result and persists across compression — compression intentionally produces different bytes, so re-hashing the compressed output would never "verify" against the original source.

### `Job` — additions

Existing v7 columns (preserved unchanged): `id`, `type` (textEnum<JobType>), `status` (textEnum<JobStatus>), `sourcePath`, `destinationPath`, `compressionOutputPath`, `presetName`, `autoChain`, `createdAt`, `startedAt`, `completedAt`, `errorMessage`, `sortOrder`, `totalFiles`, `completedFiles`, `totalBytes`, `completedBytes`, `operatorName`, **`verificationMode`** (textEnum<VerificationMode> — `'size'` or `'sha256'`).

```dart
class Jobs extends Table {
  // ... v7 columns above ...

  /// NEW v8: Mirror of count of JobFile rows where verifyStatus = unverified.
  /// Re-derived on recovery (FR-007).
  IntColumn get unverifiedFiles => integer()
      .withDefault(const Constant(0))
      .named('unverified_files')();
}
```

### `AppSettings` — additions

```dart
class AppSettings extends Table {
  // ... existing v7 columns: id, slackWebhookUrl, operatorName, autoUpdateEnabled,
  //     defaultVerificationMode (v6), defaultConflictHandling (v6), ...

  /// NEW v8: Sources panel collapsed/expanded state.
  /// Consumed by feature 018 (UX restructuring); piggybacks on this migration.
  BoolColumn get sourcesPanelCollapsed => boolean()
      .withDefault(const Constant(false))
      .named('sources_panel_collapsed')();
}
```

## New enums

```dart
enum VerifyStatus { pending, verified, mismatch, unverified }
enum FailureKind { none, copyError, verifyMismatch, verifyUnreliable }
```

Both encoded as `textEnum` in Drift (Drift stores `enum.name`, so values are literal strings: `'pending'`, `'verified'`, etc.). This matches the existing schema convention (`status`, `type`, `verificationMode` are all `textEnum`). Adding new variants in future migrations is non-breaking — existing rows preserve their stored string and new readers see the deserialized enum value. Removing or reordering variants is breaking and requires a migration.

## Migration v7 → v8 (transactional)

**IMPORTANT**: This migration uses the actual v7 schema names from `lib/database/tables.dart`. Pay attention to:
- `Jobs.verificationMode` is a `textEnum<VerificationMode>` storing literal strings `'size'` or `'sha256'`. There is NO `requireHashVerification` boolean column — that name was wrong in earlier draft.
- `JobFiles.status` is a `textEnum<FileStatus>` storing literal strings (`'pending'`, `'inProgress'`, `'completed'`, `'failed'`, `'skipped'`). NOT integer ordinal.
- `JobFiles.verified` is a pre-existing v5 boolean (set when verification — size or SHA-256 — passed). Backfill READS this to disambiguate `verified` vs `unverified` for completed rows.

```dart
@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (Migrator m) async { /* unchanged */ },
  onUpgrade: (Migrator m, int from, int to) async {
    // ... existing v2..v7 cases ...

    if (from < 8) {
      // Wrap column adds + backfill in one transaction so a mid-migration
      // crash leaves the DB at v7 cleanly (Codex M5).
      await transaction(() async {
        // ─── Phase 1: column adds ────────────────────────────────────────
        await m.addColumn(jobFiles, jobFiles.verifyStatus);   // default 'pending'
        await m.addColumn(jobFiles, jobFiles.failureKind);    // default 'none'
        await m.addColumn(jobs, jobs.unverifiedFiles);        // default 0
        await m.addColumn(appSettings, appSettings.sourcesPanelCollapsed); // default false

        // ─── Phase 2: backfill verifyStatus for completed rows ──────────
        // Completed + verified=true + parent verificationMode='sha256'
        //   → verifyStatus='verified' (cryptographic trust established).
        await customStatement('''
          UPDATE job_files
          SET verify_status = 'verified'
          WHERE status = 'completed'
            AND verified = 1
            AND job_id IN (
              SELECT id FROM jobs WHERE verification_mode = 'sha256'
            )
        ''');
        // Completed + verified=true + parent verificationMode='size'
        //   → verifyStatus='unverified' (size-only is NOT cryptographic trust).
        // Codex M5: do NOT mark these as 'verified'.
        await customStatement('''
          UPDATE job_files
          SET verify_status = 'unverified'
          WHERE status = 'completed'
            AND verified = 1
            AND job_id IN (
              SELECT id FROM jobs WHERE verification_mode = 'size'
            )
        ''');
        // Completed + verified=false: rare (recovery rescued a row?). Leave at
        // 'pending' so the next access re-verifies. Default already covers this.

        // ─── Phase 3: backfill mismatch from narrow errorMessage patterns ─
        // Codex H2: '%SHA-256%' alone is too broad — it matches both real
        // mismatches AND subsystem failures. Match the actual error text used
        // by job_queue_service.dart line 503 ('SHA-256 hash mismatch') and
        // line 506 ('SHA-256 MISMATCH').
        await customStatement('''
          UPDATE job_files
          SET verify_status = 'mismatch',
              failure_kind = 'verifyMismatch'
          WHERE status = 'failed'
            AND (
              error_message LIKE '%SHA-256 hash mismatch%' OR
              error_message LIKE '%SHA-256 MISMATCH%' OR
              error_message LIKE '%hash mismatch%'
            )
        ''');

        // ─── Phase 4: backfill unverified subsystem failures ────────────
        // Match the actual subsystem-failure messages from
        //   job_queue_service.dart:490 'SHA-256 verification failed: could not compute hash'
        //   transfer_service.dart:117  'computeFileHash exit=…'
        //   transfer_service.dart:126  'computeFileHash returned malformed output'
        //   transfer_service.dart:137  'computeFileHash threw for'
        await customStatement('''
          UPDATE job_files
          SET verify_status = 'unverified',
              failure_kind = 'verifyUnreliable'
          WHERE status = 'failed'
            AND failure_kind = 'none'
            AND (
              error_message LIKE '%could not compute hash%' OR
              error_message LIKE '%hash computation failed%' OR
              error_message LIKE '%computeFileHash exit=%' OR
              error_message LIKE '%computeFileHash returned malformed output%' OR
              error_message LIKE '%computeFileHash threw%'
            )
        ''');

        // ─── Phase 5: remaining failed rows are copy errors ─────────────
        await customStatement('''
          UPDATE job_files
          SET failure_kind = 'copyError'
          WHERE status = 'failed' AND failure_kind = 'none'
        ''');

        // ─── Phase 6: re-derive Job.unverifiedFiles from per-row state ──
        await customStatement('''
          UPDATE jobs
          SET unverified_files = (
            SELECT COUNT(*) FROM job_files
            WHERE job_files.job_id = jobs.id
              AND job_files.verify_status = 'unverified'
          )
        ''');
      });
    }
  },
);
```

### Migration safety

- Wrapped in single transaction (Codex M5): a mid-migration crash leaves the DB at v7 with no partial state. Drift writes `schemaVersion` only after `onUpgrade` returns successfully, so a retry on next launch starts cleanly.
- **Backfill is conservative on ambiguity**: a row that doesn't match any narrow pattern keeps the column default (`pending` / `none` / `0` / `false`). Better to under-classify than misclassify a hash-subsystem failure as real corruption (which would trigger `forceDestDelete=true` retry semantics).
- **Compression-only jobs** (`Job.type='compression'`): backfill leaves `verifyStatus='pending'` for their `JobFile` rows. UI gates verify counters on `Job.type` to avoid surfacing them.
- **Pre-feature-011 rows** (jobs created before SHA-256 was a concept): they default to `verificationMode='size'` per the v5 migration default, so they backfill to `verifyStatus='unverified'` — the safe choice (cryptographic trust was never established).

## State transition tables

### `JobFile` lifecycle (v8)

The `FileStatus` enum is **`pending, inProgress, completed, failed, skipped`** (defined in `tables.dart:10`; no `copying` or `copied` values). In v8, `status=completed` means "bytes on disk after robocopy success" — independent of `verifyStatus`. Legacy readers reading `status=completed` continue to see "transfer-side done"; the verify axis is read separately by new code.

| Trigger | `status` change | `verifyStatus` change | `failureKind` change |
|---------|-----------------|------------------------|----------------------|
| Job starts copy | `pending` → `inProgress` | `pending` (unchanged) | `none` (unchanged) |
| Robocopy success | `inProgress` → `completed` (bytes on disk) | `pending` (unchanged) | `none` (unchanged) |
| Robocopy fail | `inProgress` → `failed` | `pending` (unchanged) | `none` → `copyError` |
| Hash matches | `completed` (unchanged) | `pending` → `verified` | `none` (unchanged) |
| Hash mismatch | `completed` (unchanged — bytes still on disk) | `pending` → `mismatch` | `none` → `verifyMismatch` |
| Hash subsystem error | `completed` (unchanged) | `pending` → `unverified` | `none` → `verifyUnreliable` |
| Operator clicks Retry on `mismatch` | `completed` → `pending` (file scheduled for re-copy with `forceDestDelete=true`) | `mismatch` → `pending` | `verifyMismatch` (unchanged until next attempt resolves) |
| Operator clicks Retry on `copyError` | `failed` → `pending` | `pending` (unchanged) | `copyError` (unchanged until next attempt resolves) |
| Recovery — `status=completed && verifyStatus=pending` (FR-006) | unchanged | unchanged (re-enters verify-only phase) | unchanged |
| Recovery — same as above + source missing | unchanged | `pending` → `unverified` | `none` → `verifyUnreliable` |
| Recovery — `status=inProgress` | `inProgress` → `pending` (existing v2.4.0 behavior; robocopy `/Z` resumes on retry) | `pending` (unchanged) | `none` (unchanged) |

### `Job` aggregate counters (v8)

`Job.completedFiles`, `Job.completedBytes`, `Job.totalFiles`, `Job.totalBytes`, `Job.unverifiedFiles` are derived from `JobFile` rows. Recovery re-derives them all (FR-007). Live updates during execution are incremental (per `_safeWrite` calls in `JobQueueService`).

There is no `verifiedFiles` column on `Job` because it equals `completedFiles - unverifiedFiles - (failed-but-still-copied count)` and re-deriving on demand keeps the schema slim. UI computes it on read.

## Load-bearing v7 invariants preserved

| Invariant (from CLAUDE.md) | v8 status |
|----------------------------|-----------|
| `_safeWrite` wrapper required for all DAO writes inside processing loop | Preserved — new mark/increment methods called inside `_safeWrite`. |
| `JobFile.startedAt` preserved across resets | Preserved — `markFileCompleted(verified: false)` (the v8 post-robocopy call) does NOT touch it; `resetFileToPending` continues to leave it. |
| `JobFile.wasOverwriteApproved` set only at preflight, survives retry, never cleared | Preserved — A4 changes do not modify this field. |
| `Job.createdAt` mtime cutoff baseline never modified on retry/resume | Preserved — A4/A7 do not touch `createdAt`. |
| `robocopyFlags` includes `/XN /XC /XO` | Preserved — A5's `forceDestDelete=true` deletes the dest file BEFORE robocopy, so `/XO`'s "skip on size match" doesn't fire. |
| Phased shutdown structure A/B/C unchanged | Preserved — A6 logging changes are call-site-only; phase ordering is in `shell_screen.dart`. |
| `_PlannedFile` duplication | **Resolved** in A9 — single shared definition in `lib/database/planned_file.dart`. |
