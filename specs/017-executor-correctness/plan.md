# Implementation Plan: Executor Correctness (v2.5.0)

**Branch**: `017-executor-correctness` | **Date**: 2026-05-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/017-executor-correctness/spec.md`

## Summary

Fix the executor failures from the operator's 2026-05-08 Windows test run on v2.4.0:

1. **PowerShell `$args[0]` was never wired up** — `-Command` consumes only the script string, so the trailing argv element (the file path) is silently dropped at four call sites: `transfer_service.dart::computeFileHash`, `drive_service.dart::getDiskFreeSpace`, `drive_service.dart::getDriveIdentity`, `drive_service.dart::eraseDrive`. Memory entry crediting feature 013 with the fix overstated intent.
2. **Progress counters gated on verification success** — when (1) cascades, every file's verify fails and `Job.completedFiles/completedBytes` never advance. UI reads `0 B / 161 GB`.
3. **No structured logging** — `LogService` has plain-string `info/warning/error`, no `jobId/file/phase` context, no INFO-level events for successful operations.

Approach: replace `$args[0]` with single-quote escape (`s.replaceAll("'", "''")`) inside the `-Command` script string + `-LiteralPath` for verbatim path treatment. Decouple progress counters from verify outcome (two `_safeWrite` calls). Add schema v8 columns `JobFile.verifyStatus`, `JobFile.failureKind`, `Job.unverifiedFiles`, `AppSettings.sourcesPanelCollapsed` (last one consumed by feature 018). Extend `recoverStaleJobs` to handle `status=copied + verifyStatus=pending` rows. Add `forceDestDelete=true` retry path for verify-mismatch. Add normalized-key collision detection at preflight for NTFS case-only duplicates. Refactor `LogService` to a named-param API with `LogPhase` enum; structured INFO events at every phase boundary.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (desktop, Windows target)
**Primary Dependencies**: Drift (SQLite ORM), `sqflite_common_ffi`, `path`, `package_info_plus`, `dio` (Slack), `window_manager`, `tray_manager`, `file_picker`
**Storage**: SQLite via Drift, schema v7 → v8 migration in this feature
**Testing**: `flutter test` (unit), `flutter analyze` (lint), grep guard for `\$args\[` in `lib/`
**Target Platform**: Windows 11 with PowerShell 5.1 (default); macOS for development only (PowerShell helpers cannot execute)
**Project Type**: Single Flutter desktop app (compiles to one Windows `.exe`)
**Performance Goals**: Progress UI updates within 5 s of underlying state change (SC-002); SHA-256 hashing should not stall progress reporting for files in flight in adjacent slots
**Constraints**: Constitution Principle I (Human-in-the-Loop), III (Resilient Pipeline), V (Observable Progress); v2.4.0 load-bearing conventions preserved (`_safeWrite` wrapper, `JobFile.startedAt` preserved across resets, `JobFile.wasOverwriteApproved` set only at preflight, `Job.createdAt` mtime cutoff baseline never modified, `/XN /XC /XO` robocopy flags retained, phased shutdown structure A/B/C unchanged)
**Scale/Scope**: Single Windows workstation; jobs of 50–100 GB per file, 27 files / 161 GB observed in operator's test corpus; database holds historical jobs (low-volume — tens to low hundreds)

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | ✅ PASS | All destructive paths preserved; verify-mismatch Retry is operator-initiated, never automatic. `forceDestDelete=true` only fires when operator clicks Retry on a mismatched file. Auto-resume of verification on relaunch is non-destructive (read-only hash check). |
| II. Single Codebase | ✅ PASS | All changes in Dart/Flutter. No new runtimes or IPC bridges. PowerShell remains a CLI delegate (orchestration only, per Principle IV). |
| III. Resilient Pipeline | ✅ PASS | `recoverStaleJobs` extended for copied-but-unverified rows (FR-006, FR-007). Counter re-derivation prevents post-shutdown drift. `_safeWrite` abandonment-aware wrapper unchanged. |
| IV. Minimal Complexity | ✅ PASS | No new CLI tools. PowerShell escape is a 5-line helper, not a reimplementation. UNC free-space helper deferred (warning surface in v2.5; full impl in v3.0 NAS work). |
| V. Observable Progress | ✅ PASS | Progress counters decouple from verify (FR-002). Structured logging adds phase context for operator triage (FR-010, FR-011, FR-012). Slack notifications EXPANDED (FR-016): `notifyTransferCompleted` now surfaces verified / unverified / mismatch counts and uses a warning prefix when non-clean — operators walking away receive actionable detail per the principle. |
| VI. Update Transparency | ✅ PASS | No update mechanism changes. Schema migration runs at startup but is fast (< 2 s on operator's DB) and non-interactive — if measured slow, add splash UI in a later patch. |

No constitution violations. No `Complexity Tracking` entries.

## Project Structure

### Documentation (this feature)

```text
specs/017-executor-correctness/
├── plan.md              # This file
├── research.md          # PowerShell escape research, Drift migration patterns
├── data-model.md        # Schema v7 → v8 entity changes
├── quickstart.md        # Developer onboarding for the new helpers
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Generated by /speckit-tasks
```

### Source Code (repository root)

```text
lib/
├── services/
│   ├── transfer_service.dart           # A1, A2 — computeFileHash rewrite
│   ├── drive_service.dart              # A1, A2 — getDiskFreeSpace, getDriveIdentity, eraseDrive
│   ├── job_queue_service.dart          # A4 (progress decouple), A5 (forceDestDelete), A7 (recovery), A8 (collision), A9 (_PlannedFile consolidation)
│   └── log_service.dart                # A6 — named-param API, LogPhase enum
├── utils/
│   └── process_runner.dart             # A1 — runPowerShellInlineScript helper, argv-length assertion
├── database/
│   ├── tables.dart                     # A3 — JobFile.verifyStatus, JobFile.failureKind, Job.unverifiedFiles, AppSettings.sourcesPanelCollapsed
│   ├── database.dart                   # A3 — schema v8 migration with backfill
│   └── daos/
│       ├── job_dao.dart                # A4 — incrementVerified/Unverified/Failed; A7 — recovery counter re-derivation
│       └── job_file_dao.dart           # A4 — markFileCopied, markFileVerified, markFileVerifyMismatch, markFileUnverified
└── ui/
    └── widgets/
        ├── job_card_active.dart        # surfaces verify-mismatch banner (Investigate / Retry / Skip per FR-005)
        └── files_tab.dart              # per-file verifyStatus chip (verified / mismatch / unverified)

test/
├── unit/
│   ├── process_runner_argv_test.dart   # A1 — assert argv length is 3 when calling PowerShell inline scripts
│   ├── ps_escape_test.dart             # A1 — fixtures for paths with ', [, ], *, ?, `, $, U+2018, U+2019, > 260 chars
│   ├── progress_decouple_test.dart     # A4 — verify counter advances when hash mocked to fail
│   ├── recovery_test.dart              # A7 — copied + pending → verify-only on next run
│   ├── collision_normalize_test.dart   # A8 — case-only collision detection
│   └── log_format_test.dart            # A6 — golden tests on log line format per (level × phase)
└── contract/
    └── planned_file_contract_test.dart # A9 — _PlannedFile shape consumed by JobQueueService AND CreateJobScreen
```

**Structure Decision**: Existing single-codebase Flutter desktop app (CLAUDE.md). All work in `lib/services/`, `lib/utils/`, `lib/database/`, with new tests under `test/unit/` and `test/contract/`. No new directories created.

## Implementation Phases

### Phase 0 — Research

See [research.md](./research.md) for:

- **R-A1**: PowerShell single-quote escape semantics; verification on paths with `'`, `[`, `]`, `*`, `?`, `` ` ``, `$`, smart quotes (U+2018/U+2019), > 260 char paths.
- **R-A3**: Drift migration patterns; transactional column add + backfill UPDATE on Windows + macOS test environments.
- **R-A4**: `_safeWrite` interaction with two-step writes (copy then verify) — confirm no deadlock on Phase B drain.
- **R-A6**: Backward-compat strategy for `LogService.info(String)` one-arg call sites; golden test fixture format.
- **R-A8**: Path normalization for NTFS case key (`path.canonicalize` vs manual `toLowerCase()`); macOS HFS+ behavior under same code.

### Phase 1 — Design

See [data-model.md](./data-model.md) for the schema v7 → v8 entity diff and migration backfill rules.

See [quickstart.md](./quickstart.md) for developer onboarding (how to call the new PowerShell helper, how to add new `LogPhase` events).

### Phase 2 — Tasks

Generated by `/speckit-tasks` into `tasks.md`. Expected ~50–60 tasks across the 9 work items A1-A9 plus Codex-revision items:

- **CRITICAL fix from round 1**: schema v8 migration uses real v7 column names (`verificationMode` text-enum, `JobFiles.verified` boolean, `JobFiles.status` text-enum) — not the placeholder `requireHashVerification` boolean from the original draft.
- **HIGH H2**: narrow `errorMessage LIKE` patterns distinguish real `mismatch` from subsystem `unverified` outcomes.
- **HIGH H3 (Slack)**: `SlackService.notifyTransferCompleted` expanded with per-state counts and warning prefix (FR-016).
- **HIGH H4 (compression scope)**: `verifyStatus` scoped to transfer-phase rows; UI hides verify counters for `JobType.compression` (FR-017).
- **MEDIUM M1**: counter re-derivation runs once per rescued job after all stale-row mutations (FR-018).
- **MEDIUM M2**: stderr truncation enforced INSIDE `LogService.error` (not at every call site) — Codex M2 + FR-012.
- **MEDIUM M3**: log format spec defines bracket content for every (jobId × file × phase) partial-context combination.
- **MEDIUM M4**: `_PlannedFile` contract test covers full population AND subset shapes per consumer (batch / single / overwrite / rename / `copyWith` preservation).
- Recovery semantics A7, retry `forceDestDelete` A5/H2, collision detection A8/H3, contract test A9/M7 already incorporated from the meta-plan's first Codex round.

## Complexity Tracking

> **No entries** — Constitution Check passes on all six principles. The closest justified complexity is the new `verifyStatus` × `failureKind` enum pair, which would be simpler as a single composite enum but splits cleanly because copy-state and verify-state have different lifecycles and different recovery-time treatment (copy state can be reset on retry; verify state survives until the file is re-copied). The split is per Codex H1 + H2 review.

The pre-existing `JobFiles.verified` boolean (v5) is preserved in the schema rather than being removed in favor of `verifyStatus`. This is deliberate: removing it would force migration of every UI/DAO read site in feature 014 (~6 places) within this feature's scope. The boolean stays as a coarse legacy signal; new code reads `verifyStatus`. A follow-up patch in v2.6 can remove the boolean once all readers migrate.
