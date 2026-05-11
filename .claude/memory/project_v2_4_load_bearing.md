---
name: v2.4.0 load-bearing conventions (015 + 016)
description: Code-level invariants in Copiatorul3000 that future refactors must preserve — naive cleanup of any one of these re-opens a CRITICAL or HIGH bug
type: project
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
These conventions encode the v2.4.0 hardening from features 015 (robocopy execution-time overwrite guard) and 016 (graceful shutdown race hardening). Each one was the resolution of a CRITICAL or HIGH finding from a Codex `--model gpt-5.5 --effort high` adversarial review. A future session "cleaning up" any of them without reading the originating spec re-opens the bug.

**Why:** Codex caught these in review precisely because they look refactorable on the surface. Documenting them keeps future-me from un-fixing them.

**How to apply:** When touching any of the named files/symbols below, read this memory first. If the change conflicts with the convention, escalate it to a feature spec (it's not a refactor anymore).

### 1. `_safeWrite` wrapper covers every DAO write in the processing loop
File: `lib/services/job_queue_service.dart`

Every DAO write inside the processing loop, `_processJob`, `_processTransfer`, `_processCompression` must go through `_safeWrite(() => ...)`. There are ~25 sites. The wrapper:
- drops writes silently when `_shutdownAbandoned == true` (Phase B drain timed out)
- rethrows real exceptions otherwise

Bypassing it can deadlock shutdown or write into a closed DB during Phase C cleanup. The first 016 implementation only protected ~5 sites; Codex caught it. Don't shrink the coverage.

### 2. `JobFile.startedAt` is preserved across resets
Files: `lib/database/daos/job_file_dao.dart`, `lib/database/daos/job_dao.dart`

`resetFileToPending`, `recoverStaleJobs`, and `resetJobForRetry` deliberately do NOT clear `startedAt`. The 015 executor uses `file.startedAt != null` as the "ever attempted" signal that distinguishes own `/Z` partials from foreign TOCTOU intrusions. If you "fix" the reset to clear it, you turn legitimate resumes into failures and reopen the silent-overwrite CRITICAL.

### 3. `JobFile.wasOverwriteApproved` is set ONCE at preflight, survives retry
File: `lib/services/job_queue_service.dart::_applyResolution`

Set only at preflight time, only for files whose dest existed at that moment. Survives retry. Never cleared. The executor honors it absolutely (delete-then-copy regardless of size). Schema v7.

The split delete-rule the executor enforces: `wasOverwriteApproved || (everAttempted && isPartial)`. Both halves matter — a unified rule was Codex-rejected because "approved overwrite + same-size dest" failed.

### 4. `Job.createdAt` is the mtime cutoff baseline
File: `lib/services/job_queue_service.dart::_processTransfer`

Used as the TOCTOU baseline: dest files modified after `Job.createdAt` are foreign intrusions, not own partials. Refuses delete-then-copy unless `wasOverwriteApproved`. Never modify `Job.createdAt` on retry/resume.

A v1 015 implementation tripped on this for the case "operator cancelled between robocopy success and verification on a non-approved file" — fixed by adding an `everAttempted && !isPartial` early-out before the mtime check.

### 5. `robocopyFlags` includes `/XN /XC /XO`
File: `lib/utils/constants.dart`

```dart
const robocopyFlags = ['/Z', '/V', '/ETA', '/R:3', '/W:5', '/XN', '/XC', '/XO'];
```

`/XN` excludes newer dest, `/XC` excludes changed dest, `/XO` excludes older dest — together they make robocopy refuse to copy when dest exists. The executor is the ONLY thing that may delete a dest (paired with rules #3 and #4). Removing any of `/XN /XC /XO` re-opens the v2.4.0 CRITICAL (silent overwrite).

### 6. Phased shutdown — Phase C always runs
File: `lib/ui/screens/shell_screen.dart::_gracefulShutdown`

Structure:
- **Phase A**: acquire `_shuttingDown` flag (synchronous, idempotent)
- **Phase B**: 10s timeout on `jobQueueService.stopProcessing()`. On timeout: call `markShutdownAbandoned()`.
- **Phase C**: ALWAYS runs. 5s timeout on `database.close()`, instance lock release, 2s log close. Each step has its own try/catch.

Don't wrap Phase B + Phase C in a single outer timeout. Don't skip Phase C if Phase B threw. The original 30s outer-timeout structure was the v2.4.0 HIGH the 016 work fixed.

### 7. `PlannedFile` is the consolidated shape — contract test pins it
File: `lib/services/planned_file.dart`, contract test at `test/contract/planned_file_contract_test.dart`

017A T024 consolidated the previously duplicated `_PlannedFile` across `job_queue_service.dart` and `create_job_screen.dart`. Both consumers now import the public, immutable class with `copyWith`, value equality, and a contract test that fails fast in CI if either consumer's expected shape diverges. A new field added on one side without the other will break the build, not silently lose data.

### v2.5.0 (017A + 017B + 018 + 019) load-bearing conventions

v2.5.0 added significant new invariants — too many to inline here. They live in CLAUDE.md (the project context file auto-loaded into every session) under four sections:

- **"v8 (017A) Load-Bearing Conventions"** — executor correctness. Length-3 PowerShell argv, progress decoupled from verify, persisted `forceDestDeleteApproved`, recovery filtered to SHA-256 mode, NTFS case-collision normalization at every rewrite site, robocopy staging-dir for renames.
- **"v8 (017B) Load-Bearing Conventions"** — UX restructuring. Auto-chain compression gated on clean verify, compression-ready filter uses v8 axis (not legacy `verified`), Slack truthfulness on transfer failure, `VerifyStatus.notVerified` as size-mode baseline.
- **"v8 (018) Load-Bearing Conventions"** — pre-tag concurrency / atomicity. `JobDao.applyPerFileRetry` is a single transaction, typed-confirmation gate on Accept-mismatch / Accept-unverified / Skip-mismatch, `createChainedCompressionJobIfAbsent` is the only chain-creation entry point, `_stopRequested` flag pattern with no-await between re-check and flip, `PRAGMA foreign_keys = ON` in `beforeOpen`, `markFileUnverifiedAndIncrement` atomic primitive, JOIN-based self-healing of `unverifiedFiles` counter, size-mode `_processTransfer` mirrors SHA-256 sequence, `.live` marker `host=` field is load-bearing for the cold-start sweep.
- **"v9 (019) Load-Bearing Conventions"** — workflow integrity (holistic audit). `Job.sourceDriveSerial` capture-at-create + WMI re-check at transfer-resume + erase-eligibility (5-branch logic), erase-time card-content rescan via case-insensitive canonicalize, source-side `followLinks: false` + per-entry type check (mirrors 017B dest-side), `clearForceDestDeleteApproved` AFTER `markFileCompleted` (not at top-of-iteration; recovery branch ALSO clears stale flags), HandBrake compression staging-dir convention with recursive sweep, Slack `_getWebhookUrl()` INSIDE try block, SHA-256 `\\?\` long-path prefix > 240 chars, `drive_service::_runPowerShell` length-3 argv via runtime `StateError` (not `assert` — release builds strip), `createBatchTransferJobs` returns `identityRefused` distinctly from `skipped`.

Read CLAUDE.md (under the relevant "Load-Bearing Conventions" section) before refactoring any of: `_processTransfer`, `recoverStaleJobs`, `resetJobForRetry`, `_createChainedCompressionJob`, `maybeChainCompression`, `markFileCompleted`, `acceptMismatch` / `acceptUnverified`, `notifyTransferCompleted`, `transferFile` (staging-dir branch), `_applyResolution` (both batch and single-job), `_normalizeCaseCollisionsAcrossPlans`, `JobDao.applyPerFileRetry`, `createChainedCompressionJobIfAbsent`, `startProcessing` (the no-await race pattern), `beforeOpen` (FK pragma + cleanup ordering), `markFileUnverifiedAndIncrement`, `sweepOrphanedStagingDirs`, `compressFile` (HandBrake staging branch), `getDriveIdentity`, `unplannedFilesRefusalMessage`, `createBatchTransferJobs` (identity-capture branch).
