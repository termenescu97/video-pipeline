# Data Model: Pre-Tag Hardening (v2.5.0)

**Phase 1 output for plan.md.** No new entities. No schema bump (FR-009 cleanup is a connection-open statement, not a numbered migration step). This document captures the BEHAVIORAL changes to the existing `Job` and `JobFile` state machines and the FK semantics around `Job.parentJobId`.

---

## Entities affected

### Job (no schema change)

Existing columns relevant to this feature:
- `id` (int, PK)
- `status` (enum: queued / inProgress / paused / completed / failed)
- `parentJobId` (int?, FK to Jobs.id, currently with `onDelete: KeyAction.setNull` annotation that does NOT fire — see FR-009 below)
- `errorMessage` (string?, populated by `markJobFailed`)
- `completedFiles`, `completedBytes`, `unverifiedFiles` (int counters)
- `verificationMode` (enum: size / sha256)

**Behavioral changes**:

1. **`parentJobId` FK semantics become real (FR-009 / FR-010)**. Today the column has the `setNull` annotation but `PRAGMA foreign_keys` is off so the cascade silently does nothing. After this feature: `PRAGMA foreign_keys = ON` is set on every connection-open AND a one-time idempotent cleanup nulls any pre-existing dangling references. Net effect: any chained-compression child whose parent gets deleted will observably have `parentJobId = NULL` on subsequent reads.

2. **`errorMessage` cleared by migration Phase 7 lift (FR-012)**. The v8 migration already lifts `Job.status` from `failed` to `completed` for jobs whose only failed children were hash-only failures (per round-19 P2 fix). This feature extends that same Phase 7 statement to also clear `error_message` on the lifted rows. Affected rows: same as Phase 7's existing scope.

3. **Counter consistency invariant (FR-013)**. `Job.unverifiedFiles` MUST equal `COUNT(*) FROM job_files WHERE job_id = ? AND verify_status = 'unverified'` at every operator-observable read. Maintained by atomic write-pairs at every mutation site PLUS self-healing recompute on read paths.

### JobFile (no schema change)

Existing columns relevant to this feature:
- `id` (int, PK)
- `jobId` (int, FK)
- `status` (enum: pending / inProgress / completed / failed)
- `verifyStatus` (enum: pending / verified / mismatch / unverified / notVerified)
- `failureKind` (enum: none / copyError / verifyMismatch / verifyUnreliable)
- `forceDestDeleteApproved` (bool)
- `wasOverwriteApproved` (bool)
- `startedAt` (datetime?, preserved across resets)
- `errorMessage` (string?)

**Behavioral changes**:

1. **Atomic per-file retry (FR-001 / FR-002)**. The `retryFile` operator action transitions `JobFile.status` from `completed` to `pending` AND `JobFile.verifyStatus` from `mismatch`/`unverified` to `pending` AND `JobFile.forceDestDeleteApproved` to `true` (when the operator clicked Force-Delete Retry). All three writes plus the parent `Job.status → queued` flip plus `recomputeCountersFromFiles` happen in a single Drift transaction. Either the entire retry intent is persisted, or none of it is.

2. **Atomic mark-and-increment for unverified (FR-013)**. The transition `JobFile.verifyStatus = unverified` is paired with `Job.unverifiedFiles += 1` in a single transaction. Applied at both forward (`_processTransfer:797` SHA-256 subsystem failure path) and recovery (`_processTransfer:459` resumed verify path) sites.

3. **Concurrency gate on chained-child creation (FR-007)**. The `Job.parentJobId` set when `_createChainedCompressionJob` inserts a new child is paired with the `hasChainedChild` existence check in a single transaction. Two concurrent `maybeChainCompression(parentJobId)` invocations against the same parent will result in exactly one chained child — the second invocation's `hasChainedChild` check inside the transaction sees the first invocation's insert.

---

## State transitions

### `Job.status` lifecycle (extended)

Existing transitions (unchanged in this feature except as noted):

```
[creation] → queued
queued → inProgress (markJobStarted)
inProgress → completed (markJobCompleted)
inProgress → failed (markJobFailed)
inProgress → paused (stopProcessing during execution OR recoverStaleJobs)
paused → queued (resumeJob)
completed → queued (resetJobForRetry — full retry)
failed → queued (resetJobForRetry)
completed → queued (NEW: requeueJobForFileRetry — per-file retry, MUST be atomic per FR-001)
failed → completed (v8 migration Phase 7 lift, with errorMessage NULL per FR-012)
```

The two new/sharpened transitions:

- **completed → queued via per-file retry (FR-001)** — happens INSIDE the atomic `applyPerFileRetry` DAO method together with the file-row reset and counter recompute. The intermediate state (file=pending, parent=completed) MUST be unobservable to any other code path.
- **failed → completed via migration lift (FR-012)** — happens ONLY in v8 migration Phase 7. The lifted job's `errorMessage` is cleared in the same statement. No code path lifts a job from failed to completed at runtime.

### `JobFile.verifyStatus` lifecycle (recap from 017A; no changes)

```
pending → verified           (markFileVerified — SHA-256 match)
pending → mismatch           (markFileVerifyMismatch — SHA-256 mismatch)
pending → unverified         (markFileUnverifiedAndIncrement — NEW atomic, was markFileUnverified+incrementUnverified — SHA-256 subsystem failure)
pending → notVerified        (markFileSizeOnlyVerified — size-mode pass)
mismatch → verified          (acceptMismatch — operator override; audit kept in errorMessage)
unverified → notVerified     (acceptUnverified — operator override; audit kept in errorMessage)
{any} → pending              (resetFileForRetry — operator-driven; clears verify axis but preserves startedAt)
```

The only change in this feature: the forward `pending → unverified` transition is now atomic with the `Job.unverifiedFiles += 1` increment. Same intermediate states; same final state; just no observable mid-write window.

### `Job.parentJobId` lifecycle (FR-009 / FR-010)

```
NULL                         (default for non-chained jobs)
<parent_id>                  (set ONLY by _createChainedCompressionJob inside the maybeChainCompression transaction)
<parent_id> → NULL           (set by FK ON DELETE SET NULL when parent is deleted — NEW: actually fires now)
```

Plus the one-time idempotent connection-open cleanup:

```
<deleted_parent_id> → NULL   (UPDATE jobs SET parent_job_id = NULL WHERE parent_job_id IS NOT NULL AND parent_job_id NOT IN (SELECT id FROM jobs))
```

---

## Validation rules

| Rule | Where enforced | Verified by |
|------|----------------|-------------|
| `Job.unverifiedFiles == COUNT(JobFile WHERE verify_status='unverified')` for every `Job` | Atomic DAO methods (write-time) + `recomputeCountersFromFiles` (read-time defense-in-depth) | `counter_consistency_test.dart` |
| `Job.parentJobId` is either NULL or references an existing `Job.id` | SQLite FK enforcement (after FR-009 lands) + connection-open cleanup statement | `fk_pragma_and_cleanup_test.dart` |
| Atomic per-file retry produces no intermediate observable state | Drift transaction wrapping `applyPerFileRetry` | `retry_atomicity_test.dart` (synthetic interruption matrix) |
| Two concurrent `maybeChainCompression(jobId)` calls produce exactly one chained child | Drift transaction wrapping `hasChainedChild` + `_createChainedCompressionJob` | `chain_dedup_test.dart` (paired-fire fakeAsync stress) |
| `Job` lifted from `failed` to `completed` by Phase 7 has NULL `errorMessage` | v8 migration Phase 7 SET clause | `migration_errormessage_test.dart` |

---

## Non-changes (deliberate)

The following data-model elements are NOT changed by this feature, despite touching adjacent code:

- **Schema version**: stays at v8. No new tables, no new columns, no renamed columns. The FR-009 cleanup is a connection-open statement; FR-012 extends an existing migration phase's SET clause.
- **`JobFile.startedAt` semantics**: preserved across all resets (load-bearing convention from 015). The atomic per-file retry MUST also preserve it.
- **`JobFile.wasOverwriteApproved`**: set ONLY at preflight; never cleared (load-bearing convention from 015). Atomic retry MUST not touch it.
- **`JobFile.forceDestDeleteApproved`**: persisted column, single-use semantics (consumed at top of per-file iteration). Atomic retry SETS it; the executor still consumes-and-clears it as today.
- **`Job.createdAt`**: never modified on retry/resume (load-bearing convention from 015 — mtime-cutoff baseline).
- **All 5 `VerifyStatus` enum values**: pending / verified / mismatch / unverified / notVerified. No additions, no removals.
- **All 4 `FailureKind` enum values**: none / copyError / verifyMismatch / verifyUnreliable. No additions, no removals.

---

## Compatibility with v2.4.0 + v8 (017A) + v8 (017B) load-bearing conventions

Each existing convention checked. None are violated.

| Convention (CLAUDE.md) | Compatibility |
|------------------------|---------------|
| `_safeWrite` wrapper covers every DAO write in the processing loop | ✅ Atomic DAO methods are wrapped by `_safeWrite` at the call site (R6 in research.md). Composition is correct. |
| `JobFile.startedAt` preserved across resets | ✅ `applyPerFileRetry` preserves it (mirrors current `resetFileForRetry`). |
| `JobFile.wasOverwriteApproved` set only at preflight | ✅ Atomic retry never touches this column. |
| `Job.createdAt` is mtime cutoff baseline | ✅ Atomic retry never touches this column. |
| `robocopyFlags` includes `/XN /XC /XO` | ✅ Not touched. |
| Phased shutdown — Phase C always runs | ✅ Not touched. The `_stopRequested` flag (R4) lives entirely inside `JobQueueService`; Phase C in `shell_screen.dart` is unchanged. |
| `PlannedFile` is the consolidated shape | ✅ Not touched. |
| Length-3 PowerShell argv | ✅ Not touched. |
| `markFileCompleted(verified: false)` post-robocopy signal | ✅ Not touched. FR-014 reorders SIZE-MODE only to match this invariant; SHA-256 path stays the same. |
| `VerifyStatus` × `FailureKind` axes independent of `FileStatus` | ✅ Not touched; preserved by the atomic write pattern. |
| `Job.parentJobId` set ONLY at chain time | ✅ Not touched. FR-009 only NULLS it (via FK cascade or cleanup); never SETs it. |
| `forceDestDeleteApproved` operator-attribution | ✅ Atomic retry SETS it (when force=true); executor still consumes-and-clears at top of per-file iteration. |
| `recoverStaleJobs` re-derives counters | ✅ Not touched. New atomic DAO methods are independent of recovery. |
| Case-only NTFS collisions normalized at every rewrite site | ✅ Not touched. |
| Robocopy renamed-destination uses staging dir | ✅ FR-015 ADDS a `.live` PID marker inside the staging dir; does not change the staging-dir creation/use semantics. |
| 5-state VerifyStatus enum | ✅ Not touched. |
| `markFileSizeOnlyVerified` is size-mode success signal | ✅ Not touched. FR-014 reorders WHEN it's called relative to `verifyTransfer`, not what it does. |
| Auto-chain compression gated on clean verify state | ✅ Not touched. FR-007 wraps the dedup gate atomically; the gate logic itself is unchanged. |
| Compression-ready filter uses v8 axis | ✅ Not touched. |
| Slack truthfulness on transfer failure | ✅ Not touched (017B round-13 P2 #1 invariant). FR-011 ADDS truthfulness to the success path for size-mode. |
| SourcesPanel collapse persists | ✅ Not touched. |
| HistorySurface reads `watchAllFiles()` | ✅ Not touched. |
| `acceptMismatch` / `acceptUnverified` audit trail preserved | ✅ Not touched. FR-003/FR-004 add a typed-gate IN FRONT of these calls; the calls themselves are unchanged. |
| Per-file retry recomputes Job-level counters | ✅ Strengthened: now ATOMIC with the row reset (FR-001). |
| Success celebration suppressed on verify warnings | ✅ Not touched. |
| Chained-compression Slack ping counts size-mode parents | ✅ Not touched. FR-011 adds the analogous fix to `notifyTransferCompleted`. |
| Per-file retry blast radius (status=failed early-skip) | ✅ Not touched. |
| v7→v8 migration flips hash-only failures to status=completed | ✅ Not touched. FR-012 extends Phase 7's SET clause to also clear `error_message` on the SAME lifted rows. |

Net: 27 conventions checked; 27 preserved; 2 strengthened (counter atomicity, retry atomicity).
