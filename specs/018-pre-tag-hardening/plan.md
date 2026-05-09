# Implementation Plan: Pre-Tag Hardening (v2.5.0)

**Branch**: `018-pre-tag-hardening` | **Date**: 2026-05-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/018-pre-tag-hardening/spec.md`
**Findings doc**: [v2.5.0-pre-tag-findings.md](../v2.5.0-pre-tag-findings.md)

## Summary

Close the 10 adversarial-review findings (1 P1, 4 P2, 5 P3) surfaced by parallel Codex (round 21) + Claude Opus reviews after the 20th Codex round on the 017A + 017B work. All ship as one bundle so v2.5.0 tags only after this lands AND Windows operator acceptance passes. No further executor changes after this feature.

Approach groups by failure class, not by finding number:

1. **Atomicity at the source** (FR-001, FR-007, FR-013): refactor every paired `(per-row mutation, job-counter mutation)` write into a single transactional DAO method. `retryFile` becomes one atomic call (file reset + parent requeue + counter recompute in one Drift transaction). `maybeChainCompression` wraps the `hasChainedChild` check + `_createChainedCompressionJob` insert in a transaction. `markFileUnverified` + `incrementUnverified` collapse into one method, applied at both forward (`_processTransfer:797`) and recovery (`_processTransfer:459`) sites. Self-healing `recomputeCountersFromFiles` stays as defense-in-depth on operator-facing read paths.

2. **Convention conformance** (FR-003 — FR-006): wire the existing `ConfirmationDialog.showDestructive` typed-gate primitive into the three Accept/Skip dialogs that today use a plain `AlertDialog`. Phrases: `accept mismatch`, `accept unverified`, `skip mismatch`. Inline case-hint already present in the primitive.

3. **Concurrency discipline** (FR-008): track `_stopRequested` separately from `_isProcessing`. The processing loop exits when it observes `_stopRequested`. `startProcessing` awaits `_stopCompleter` (or rejects) when called during in-flight stop.

4. **FK enforcement + retroactive cleanup** (FR-009, FR-010): on every connection-open, run an idempotent `UPDATE jobs SET parent_job_id = NULL WHERE parent_job_id IS NOT NULL AND parent_job_id NOT IN (SELECT id FROM jobs)` BEFORE issuing `PRAGMA foreign_keys = ON`. Order matters — flipping the pragma first would surface the violation as an error.

5. **Reporting truthfulness** (FR-011, FR-012, FR-014): add `notVerifiedFiles` parameter to `notifyTransferCompleted` (mirroring the round-20 fix to `notifyCompressionCompleted`). v8 migration Phase 7 also clears `error_message` for status-lifted jobs AND an idempotent connection-open cleanup runs the same SET clause on every open (so pre-tag testers who already migrated to v8 get the cleanup retroactively — see R7'). Size-mode `_processTransfer` mirrors the SHA-256 sequence EXACTLY: after robocopy → `markFileCompleted(verified: false)` + progress credit → THEN `verifyTransfer` size check → on success `markFileSizeOnlyVerified` → on failure `markFileFailed`. (Codex round-22 P1 corrected the original "reorder markFileSizeOnlyVerified before verifyTransfer" plan, which would have written success state before proof.)

6. **Filesystem hygiene** (FR-015): startup sweep at the same hook point as `recoverStaleJobs`. Scope: destination roots of jobs in non-terminal status + most-recently-completed job's root. Live-instance marker via PID file inside the staging dir.

No schema bump — these are surgical edits to existing tables and behavior. The cleanup statement in #4 runs at connection-open, not as a numbered migration step (idempotent, safe to re-run).

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (desktop, Windows target)
**Primary Dependencies**: Drift (SQLite ORM), `sqflite_common_ffi`, `path`, `dio` (Slack), `window_manager`, `tray_manager`
**Storage**: SQLite via Drift, schema v8 (no bump in this feature; FR-009 cleanup is a connection-open statement, not a migration step)
**Testing**: `flutter test` (unit), `flutter analyze` (lint), grep guard `! grep -rn '\$args\[' lib/` (preserved from 017A), 78 existing tests must keep passing
**Target Platform**: Windows 11 with PowerShell 5.1; macOS for development only
**Project Type**: Single Flutter desktop app (compiles to one Windows `.exe`)
**Performance Goals**: FR-015 startup sweep adds < 500 ms latency in the typical 1–3-roots case (SC-010); per-file retry round-trip remains under operator-perceptible threshold (< 100 ms typical)
**Constraints**: Constitution Principle I (Human-in-the-Loop), III (Resilient Pipeline), V (Observable Progress); ALL v2.4.0 + v8 (017A) + v8 (017B) load-bearing conventions documented in CLAUDE.md preserved unchanged; no new runtimes; no schema migration steps numbered; no public API changes
**Scale/Scope**: Single Windows workstation; existing low-volume database (tens to low hundreds of jobs); the typed-gate UI swap touches 3 dialog call sites; the atomicity refactor touches ~5 DAO methods + their ~10 call sites; the FK pragma + cleanup is one connection-open hook; the staging-dir sweep is one new startup-time helper

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | ✅ PASS (strengthened) | The whole point of US2 is Principle I conformance. Today's plain-button Accept/Skip dialogs are a Principle I gap; FR-003 — FR-006 close it by wiring the existing typed-gate primitive. No new code path takes a destructive action without operator confirmation. |
| II. Single Codebase | ✅ PASS | All changes in Dart/Flutter + Drift SQL. No new runtimes, no IPC, no secondary languages. The FK cleanup statement is plain SQL via `customStatement`, same primitive used by the v8 migration. |
| III. Resilient Pipeline | ✅ PASS (strengthened) | Atomicity work (FR-001, FR-007, FR-013) directly serves Principle III — partial-write states become unreachable. The startup staging-dir sweep (FR-015) closes a hygiene gap that, while non-data-safety, fits the spirit ("the system tidies up after a crash"). FK retroactive cleanup ensures past dangling refs don't surface as new errors. |
| IV. Minimal Complexity | ✅ PASS | No new CLI tools. The 6 fix categories all use existing primitives: Drift transactions, the existing `ConfirmationDialog.showDestructive`, the existing `_safeWrite`, the existing `recomputeCountersFromFiles`, the existing `customStatement`, the existing `recoverStaleJobs` startup hook. The PID-marker file for live-staging-dir detection is a 2-line helper, not a new abstraction. |
| V. Observable Progress | ✅ PASS (strengthened) | FR-011 (size-mode Slack truth), FR-012 (migrated-job error-message cleanup), FR-013 (counter consistency), FR-014 (size-mode progress crediting parity) all serve "the system tells the truth about itself, in real time, to the operator." Existing structured logging (LogPhase) preserved for all new code paths. |
| VI. Update Transparency | ✅ PASS | No update mechanism changes. Schema unchanged; FR-009 cleanup runs silently at connection-open and affects at most a handful of rows per operator (typically zero). |

No constitution violations. No `Complexity Tracking` entries needed.

## Project Structure

### Documentation (this feature)

```text
specs/018-pre-tag-hardening/
├── plan.md              # This file
├── research.md          # Phase 0 — atomicity patterns, FK pragma lifecycle, staging-dir liveness detection
├── data-model.md        # Phase 1 — verifyStatus state machine + parent-FK semantics (no entity changes)
├── quickstart.md        # Phase 1 — developer onboarding + manual verification recipes
├── checklists/
│   └── requirements.md  # Spec quality checklist (already passing)
└── tasks.md             # Phase 2 (generated by /speckit-tasks)
```

No `contracts/` directory — purely internal feature, no public API changes.

### Source Code (repository root)

Existing layout from 017A + 017B; this feature touches:

```text
lib/
├── services/
│   ├── job_queue_service.dart       # FR-001 (retryFile atomicity), FR-007 (chain TOCTOU), FR-008 (start/stop race), FR-014 (size-mode reorder), FR-015 (startup sweep wiring)
│   ├── transfer_service.dart        # FR-015 (PID-marker on staging-dir create)
│   └── slack_service.dart           # FR-011 (notVerifiedFiles parameter)
├── database/
│   ├── database.dart                # FR-009 (connection-open cleanup + PRAGMA), FR-012 (Phase 7 errorMessage clear)
│   └── daos/
│       ├── job_dao.dart             # FR-001 (atomic retryFile DAO method), FR-013 (atomic counter pairs)
│       └── job_file_dao.dart        # FR-013 (atomic markFileUnverified + increment), FR-001 helpers
├── ui/
│   └── widgets/
│       ├── job_card_done.dart       # FR-003 + FR-004 (typed-gate on Accept menu items)
│       └── job_card_active.dart     # FR-005 (typed-gate on Skip in mismatch banner)
└── utils/
    └── (no new files — all helpers fit in existing modules)

test/
├── unit/
│   ├── retry_atomicity_test.dart           # NEW — FR-001/FR-002 synthetic interruption matrix (SC-001)
│   ├── typed_gate_coverage_test.dart       # NEW — FR-003/4/5/6 (SC-002)
│   ├── chain_dedup_test.dart               # NEW — FR-007 paired-Accept stress (SC-003)
│   ├── start_stop_race_test.dart           # NEW — FR-008 stress (SC-004)
│   ├── fk_pragma_and_cleanup_test.dart     # NEW — FR-009/FR-010 (SC-005)
│   ├── slack_size_mode_truth_test.dart     # NEW — FR-011 (SC-006)
│   ├── migration_errormessage_test.dart    # NEW — FR-012 (SC-007)
│   ├── counter_consistency_test.dart       # NEW — FR-013 (SC-008)
│   ├── size_mode_progress_order_test.dart  # NEW — FR-014 (SC-009)
│   └── staging_dir_sweep_test.dart         # NEW — FR-015 (SC-010)
└── (existing tests must continue to pass — SC-011)
```

**Structure Decision**: No structural changes. All edits land in existing files; new tests follow the existing `test/unit/` convention (one file per FR cluster). The 10 new test files match the 10 SCs that close the 10 findings — one-to-one traceability for the post-implement Codex review (SC-012).

## Implementation Sequencing

Tasks generation (via `/speckit-tasks`) will produce ~25 ordered tasks. Sequencing principle: data-safety first (P1 user stories), correctness second (P2), reporting/hygiene last (P3). Within each priority tier, schema-adjacent work (DAO + database) lands before service-layer work, which lands before UI wiring, which lands before tests.

Tier 1 (P1 — gates v2.5.0 tag):
- US1 (atomic retry): job_dao.dart `applyPerFileRetry` method → job_queue_service.dart `retryFile` collapses to one call → `retry_atomicity_test.dart`.
- US2 (typed-gate): wire `showDestructive` into job_card_done.dart Accept entries → job_card_active.dart Skip entry → `typed_gate_coverage_test.dart` (widget tests assert button-disabled-until-typed-match).

Tier 2 (P2 — must ship in this feature):
- US3 (concurrency): `maybeChainCompression` transaction-wrap → `_stopRequested` flag pattern → two stress tests.
- US4 (FK + cleanup): `database.dart` connection-open hook (cleanup SQL → PRAGMA flip) → unit test that asserts pragma state + cleanup of seeded dangling row.

Tier 3 (P3 — bundled):
- US5 reporting (4 sub-fixes): `notifyTransferCompleted` parameter add → migration Phase 7 `error_message=NULL` extension → `_processTransfer` size-mode branch reorder → `markFileUnverified+increment` collapse with self-healing fallback on read paths → 4 unit tests.
- US6 hygiene: PID-marker on staging-dir create → startup sweep helper → wire into `recoverStaleJobs` startup hook → unit test with seeded orphan dir.

After implementation:
- `flutter analyze --no-pub` clean (mandatory)
- `flutter test` 78 + 10 new = 88 tests pass (SC-011 baseline)
- Codex round 22 (`gpt-5.5 effort=high`) on the merged feature (SC-012 — must surface no new P1/P2)
- Manual Windows acceptance per RELEASE_NOTES_v2.5.0.md T067 (SC-011 final)
- Tag v2.5.0

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| FR-009 cleanup statement runs on every connection-open. If misimplemented, becomes a perf regression on hot startup paths. | Codex round-22 P3: actual SQLite plan is `SCAN jobs` plus rowid lookups (NOT a SEARCH on parent_job_id, which lacks an index). At the project's scale (tens to low hundreds of jobs) this is sub-millisecond and acceptable. Adding an index on `parent_job_id` is deferred to v2.6 if production observes a regression. |
| The atomic `retryFile` refactor changes a long-tested code path. Risk of subtle regression in error-handling shape (e.g., a different exception type bubbles up). | Keep the public `retryFile(int fileId, {bool forceDestDelete})` signature unchanged. Only the implementation collapses to one DAO call. Existing callers see no surface change. |
| `_stopRequested` flag pattern (FR-008) is a non-trivial concurrency change to a well-tested loop. | Add a dedicated unit test that interleaves `stopProcessing` and `startProcessing` 100× and asserts loop count = 1 throughout (SC-004). Use a deterministic test runner (controlled awaiter) rather than wall-clock sleeps. |
| Migration Phase 7 errorMessage clear (FR-012) is a write to existing rows on every operator's database. | Statement scoped to rows that meet the lift criteria; idempotent (re-running on already-cleared rows is a no-op). Phase 7 itself already runs in the same v8 transaction; we extend it, not add new phases. |
| Staging-dir PID marker (FR-015) on Windows: file locking semantics differ from POSIX. A live PID file might be left behind if the process is killed without cleanup. | Sweep checks (a) PID exists in OS process table AND (b) PID's executable path matches the current app's executable. If either check fails, treat as orphan. Same approach as the existing instance-lock helper (proven). |
| Codex round-22 might surface NEW findings (not just confirm fixes). Could push tag past acceptable schedule. | This is acceptance-by-design — round 22 IS the gate (SC-012). If it surfaces a new P1/P2, fix-and-rerun before tagging. P3 findings can defer to v2.5.1. |

## Codex round-22 review — findings folded back

The plan above was passed to Codex `gpt-5.5 effort=high` (`codex exec` with the prompt at `/tmp/codex_plan_review_prompt.md`). 10 findings returned (1 P1, 3 P2, 6 P3). All folded into spec/plan/research/data-model. Fold map:

| Codex finding | Severity | Where folded |
|---|---|---|
| Size-mode "progress" fix wrote success before verification | P1 | spec.md FR-014 (rewritten), plan.md Summary #5 (rewritten) |
| Stop/start fix still allowed multiple queued starters | P2 | research.md R4 (re-check after await spelled out) |
| Chain dedup not centralized across all chain paths | P2 | research.md R8' (new `createChainedCompressionJobIfAbsent` gate routes BOTH `_processJob` and `maybeChainCompression`) |
| Existing v8 databases waved away, not fixed | P2 | research.md R7' (added idempotent connection-open cleanup for status-lifted jobs, alongside the FK cleanup) |
| FK lifecycle claim overstated | P3 | research.md R2 (corrected: `beforeOpen` runs AFTER migrations, not before) |
| FK cleanup query-plan claim false without index | P3 | plan.md Risks (claim corrected: SCAN jobs is acceptable at current scale; index deferred) |
| `_safeWrite` transaction composition overclaimed cancellation | P3 | research.md R6 (corrected: row/counter atomicity, NOT abandonment preemption) |
| Counter self-healing read paths not specified | P3 | data-model.md (specific DAO read paths named: `watchAllJobs`, `watchCompletedJobs`, `watchJob`) |
| SC-009 test metric tautological | P3 | spec.md SC-009 (rewritten: controlled completer assertion, not await-count) |
| Staging marker liveness underspecified | P3 | research.md R5 (corrected: marker write is load-bearing — abort transfer if it fails) |

Round 22 surfaced ZERO findings on the typed-confirmation work, the FR-001 atomic retry direction, or the FR-013 atomic counter pattern — those parts are solid.

The plan now reflects all round-22 corrections. Ready for `/speckit-tasks`.
