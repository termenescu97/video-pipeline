# Copiatorul3000 v2.5.0

**Tag**: `v2.5.0`
**Date**: 2026-05-08 (post-acceptance)
**Bundles**: features 017A (executor correctness) + 017B (UX restructuring)
**Schema**: v7 → v8 (auto-migrates on launch; rollback-journal mode keeps the migration atomic)

## TL;DR

The 2026-05-08 Windows test exposed two classes of failure: **data-safety blockers in the executor** (every SHA-256 hash subprocess died, progress bar froze at 0/27 even though robocopy copied 3 files cleanly, logs were failure-only with PowerShell parser dumps drowning out signal) and **UX failures around the operator's workflow** (panels open all the time consuming horizontal space, filter pills wrapping to 3 rows, no first-class cross-job history awareness).

v2.5.0 closes both. The executor is now structurally incapable of reproducing the 0/27 freeze; the verify axis is fully decoupled from copy progress; cross-job history is a search-and-filter surface in the home column; the create-job pane and sources panel only consume space when the operator is actively using them.

## What's fixed (executor correctness — 017A)

### The PowerShell `$args[0]` cascade

PowerShell's `-Command` only consumes the script-string argv element; trailing argv is **silently dropped**, so the `$args[0]` pattern that v2.4.0 used to pass paths to `Get-FileHash`, `Get-PSDrive`, `Get-CimInstance`, and `Remove-Item` was effectively passing empty strings. Every hash check failed in the operator's test.

- New `lib/utils/ps_escape.dart::escapePsLiteral` — single-quote-escape for embedding paths into single-quoted PS literals.
- New `ProcessRunner.runPowerShellInline` — asserts the length-3 argv invariant (`['-NoProfile', '-Command', script]`) at runtime AND in unit tests.
- Four call sites rewritten: `transfer_service.computeFileHash`, `drive_service.getDiskFreeSpace`, `getDriveIdentity`, `eraseDrive`. Each embeds its value via `-LiteralPath '${escapePsLiteral(path)}'`, never as a 4th argv element.
- CI grep guard `! grep -rn '\$args\[' lib/` returns 0 matches forever — locks out regressions.

### Progress decoupled from verify outcome

After successful robocopy, bytes are credited to `Job.completedFiles` / `Job.completedBytes` IMMEDIATELY in a separate `_safeWrite` call, BEFORE the verify pass runs. Any verify outcome (success / mismatch / subsystem failure) cannot retroactively decrement copy progress.

- New v8 `VerifyStatus` enum (5 states): `pending` / `verified` / `mismatch` / `unverified` (subsystem failure) / `notVerified` (size-mode baseline).
- New v8 `FailureKind` enum: `none` / `copyError` / `verifyMismatch` / `verifyUnreliable`.
- `markFileCompleted(verified: false)` is the post-robocopy signal; `markFileVerified` / `markFileVerifyMismatch` / `markFileUnverified` / `markFileSizeOnlyVerified` write the verify axis later.
- The "0 / 27 files" freeze is now structurally impossible — the gating check that caused it has been split into independent persisted writes.

### Recovery semantics for abandoned shutdowns

`recoverStaleJobs` now handles the new v8 stale state (file copied successfully, hash check abandoned mid-flight). On next launch the verify pass resumes for those rows without re-copying; counters are re-derived from per-row state via `recomputeCountersFromFiles`.

- The rescued set: `inProgress` jobs UNION jobs with `inProgress` files UNION jobs with `completed`+`verifyStatus=pending` files (filtered to SHA-256 mode — size-mode jobs don't have a SHA-256 phase to abandon).
- Rescued jobs at status=completed/failed flip to paused so they re-enter the queue.
- `Job.parentJobId` (new v8 column) links chained-compression jobs back to their transferAndCompress parent so `notifyCompressionCompleted` can surface parent verify counts.

### Verify-mismatch retry without infinite loops

A SHA-256 mismatch on a `/Z`-completed robocopy used to be unrecoverable: the feature-015 delete predicate (`wasOverwriteApproved || (everAttempted && isPartial)`) kept skipping robocopy because the size matched, so re-verify saw the same corrupt bytes forever.

- New `JobFile.forceDestDeleteApproved` column persists the operator's explicit Retry approval across app restarts.
- `_processTransfer` consumes the approval on read at the top of the per-file iteration (single-use semantics) and adds it to the delete-predicate as a fourth `OR` term, bypassing both the feature-015 predicate and the size-match short-circuit.
- Robocopy-time renamed transfers (case-collision normalization, conflict-rename) use a private `.tmp_robocopy_<tag>` staging subdirectory and a post-copy `File.rename` so the operation can't clobber any pre-existing file in destDir.

### NTFS case-only collision protection

Two source files with paths that differ only in case (`DCIM/IMG_001.MOV` vs `dcim/img_001.mov` from a case-sensitive source like exFAT or a network share) collapse to the same NTFS destination key and silently overwrite mid-batch. v2.4.0's collision check (`File.existsSync`) only caught collisions against pre-existing disk state, not within the planned set.

- `JobQueueService.normalizeCaseCollisions` runs at preflight for both batch (`createBatchTransferJobs`) and single-job (`CreateJobScreen._applyResolution`) paths. First occurrence keeps its destination; later occurrences are rerouted via `_suffixedPathAgainst` (collision-aware suffix helper that checks BOTH disk and the lowercased planned-set).
- The conflict-rename branch also uses `_suffixedPathAgainst` so generated suffixes can't re-collide with already-claimed planned paths.
- Re-runs after `newFolder` resolution (operator picks a different destination) so the rebuilt destinations don't lose their suffix stamps.

### Structured logging at every phase boundary

`LogService` is now a named-param API: `info/warning/error({jobId, fileIndex, totalFiles, phase, subprocessStderr})`. Format: `[2026-05-08 14:23:45] [INFO] [job=1 file=03/27 phase=transfer] message`. Subprocess stderr is truncated to first line + 200 grapheme clusters via the `characters` package (no mojibake on emoji or surrogate pairs).

INFO-level events emitted at: enqueue / preflight / transfer / verify / compress / finalize / recover / shutdown phase transitions, plus per-file copy success and per-file verify success. ERROR triage no longer dumps the full PowerShell parser stack — first line of stderr only.

## What's improved (UX restructuring — 017B)

### Layout

- **ActivityPanel removed.** The third column that consumed 300px of horizontal real estate at all times is gone. Cross-job history now lives inline in the home column.
- **CreateJobScreen pane auto-hides.** No more empty "Click a job in the queue to expand its detail" placeholder; the create pane only renders when the operator is actively creating a job (Ctrl+N or the "+ New Job" button). Queue narrows to 360px while creating, expands to full width otherwise.
- **SourcesPanel collapsible.** 240px ↔ 48px icon strip via `Ctrl+1` or the chevron in its header. Collapsed state persists across restarts (`AppSettings.sourcesPanelCollapsed`). Auto-expands when a NEW SD card is detected (after-launch insertions only — cards present at launch don't undo the persisted preference).

### Filter pills

The 5-chip filter row in the Files tab no longer wraps to 3 rows at typical column widths. Now a single horizontal-scroll row that keeps every chip in reach regardless of column width.

### History surface

The new `HistorySurface` widget at the bottom of the home column replaces the right-column ActivityPanel. Three new affordances over v2.4.0's history:

- **Search box** filters by `Job.sourcePath` AND `Job.operatorName` (case-insensitive substring).
- **Status filter chips**: All / Verified / Unverified / Mismatch / Failed. The Verified / Unverified / Mismatch buckets use the v8 verify axis — a job whose ONLY failure was a SHA-256 mismatch is findable as Mismatch, not buried in a generic Failed bucket.
- **Expansion state shared with the active queue** — a card that was expanded above stays expanded when it transitions to history.
- **CSV export entry** retained (Ctrl+E shortcut).

### Active card

The verify-axis stats line + mismatch banner is gated on `verificationMode == sha256` AND `type != compression` (Codex round-12 P2). Size-mode jobs don't render misleading "0 / N verified" — the verify axis only matters in SHA-256 mode.

The mismatch banner (`Investigate` / `Retry` / `Skip`) is disabled while the job is currently processing (Codex round-4 P1). Operator must wait for the run to finish, then use the same actions from the JobCardDone history menu — which now also exposes Retry-mismatched, Accept-mismatched (typed-confirmation gated), Retry-unverified, and Accept-unverified.

### Diagnostics → Recent failures

New section at the bottom of Settings → Diagnostics. Streams `jobFileDao.watchAllFiles`, buckets by jobId, and lists every job that has at least one row at `status=failed` OR `verifyStatus=mismatch` OR `verifyStatus=unverified`. Per-job count chips colored by severity. Newest-first up to 20 jobs. Operator triages non-clean completions without parsing `copiatorul3000.log`.

### Compression auto-chain gating

`transferAndCompress` jobs no longer silently auto-chain compression on a transfer that left ANY file at mismatch / unverified. The chain is suppressed with a WARNING log line; the operator must Retry or Accept the warnings via the JobCardDone menu, then `JobQueueService.maybeChainCompression` (called from each Accept handler) checks whether the gate now passes and creates the chained child if so. Without this, accepting 27 mismatched files would silently produce a 0-file compression child while the snackbar said "compression chain resumed" (Codex round-15 P1).

## Schema migration v7 → v8

Auto-migrates on launch. The migration is wrapped in a single transaction (atomicity guarantee — a mid-migration crash leaves the DB at v7 cleanly).

New columns (defaults applied to existing rows):

- `JobFiles.verifyStatus` (textEnum, default `pending`)
- `JobFiles.failureKind` (textEnum, default `none`)
- `JobFiles.forceDestDeleteApproved` (bool, default false)
- `Jobs.unverifiedFiles` (int, default 0)
- `Jobs.parentJobId` (nullable int, FK to Jobs.id with `ON DELETE SET NULL` — Codex round-1 P2 #4)
- `AppSettings.sourcesPanelCollapsed` (bool, default false)

Backfill rules for existing rows:

- `status=completed` AND `verified=true` AND parent `verificationMode=sha256` → `verifyStatus=verified`
- `status=completed` AND `verified=true` AND parent `verificationMode=size` AND `type IN (transfer, transferAndCompress)` → `verifyStatus=notVerified` (size-mode baseline; compression rows stay at `pending` because the verify axis doesn't apply to them)
- `status=failed` AND `errorMessage` matches a SHA-256-mismatch pattern → `verifyStatus=mismatch` + `failureKind=verifyMismatch`
- `status=failed` AND `errorMessage` matches a hash-subsystem-failure pattern → `verifyStatus=unverified` + `failureKind=verifyUnreliable`
- `status=failed` otherwise → `failureKind=copyError`
- `Job.unverifiedFiles` re-derived from per-row state via aggregate query

## Review process

Both features went through the full spec-kit pipeline (`/speckit-specify` → `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement`) with **20 Codex adversarial-review rounds** total (`gpt-5.5`, `effort=high`):

- 017A: 6 rounds — covered PowerShell argv shape, schema migration backfill, recovery semantics, retry persistence, mismatch banner UX, FK delete cascade, completed-mismatch reset filter, active-card retry race.
- 017B: 9 rounds — covered the round-7 P1 robocopy-rename overwrite (staging-dir fix), case-collision detection in single-job + newFolder paths, persisted SourcesPanel collapse, HistorySurface details wiring, mismatch Skip flow, VerifyStatus.notVerified for size-mode, conflict-rename collision-aware suffix helper, Slack failure-truth, transferAndCompress auto-chain gating, unverified recovery + chain resume after Accept, compression-ready filter on the v8 axis.
- Bundled rounds 17–20: counter-recompute on per-file retry (round-17 P2 + round-18 P2 #1), success-celebration suppression on verify warnings (round-18 P2 #2), v8 migration backfill of hash-only v7 failures to status=completed so Accept paths reach them (round-19 P2), per-file-retry blast radius scoping (round-20 P2 #1), size-mode parent file count in chained-compression Slack ping (round-20 P2 #2).

### Pre-tag hardening (018)

A focused pre-tag pass ran AFTER 017A+017B implementation closed. Combined parallel Opus-max-thinking + Codex round-21 reviews surfaced 10 concerns; spec-kit feature 018 (`specs/018-pre-tag-hardening/`) addressed them in 35 ordered tasks across 7 user stories. Three additional Codex rounds during 018:

- **Round-22** (plan review): 1 P1 + 3 P2 + 6 P3. P1 — typed-gate phrase enforcement; folded into T005-T007 wording. All P2s folded into the plan; one P3 (CLAUDE.md "junk drawer") split T031 into add+archive.
- **Round-23** (tasks review): 1 P1 + 7 P2 + 1 P3. P1 — chain-dedup gate must be transactional; T010 rewritten. P2s included `_processTransfer` task-ordering false-positive (Phase 7 dep graph corrected), counter-self-healing under-spec (T022 rewritten to use single-query JOIN), startup-sweep wiring layer (T027 rewritten as standalone helper).
- **Round-24** (post-checkpoint-6c review): 1 P2 + 2 P3. P2 — size-mode resume gap created by T024 (the `verification_mode = 'sha256'` filter from Codex round-3 P2 #1 became stale; recovery branch had to learn size-mode re-verify). P3s — `watchAllJobs` correlated subquery cost (added `idx_job_files_job_id` index in beforeOpen), pure-SHA-256 Slack body wrongly always rendered `Size-only: 0` (omit when 0).

10 closed findings shipped in the 9 commits on `018-pre-tag-hardening`:
- Per-file retry now a single transaction (`JobDao.applyPerFileRetry`); 4-case test with mid-transaction failure injection.
- Typed-confirmation gate on Accept-mismatch / Accept-unverified / Skip-mismatch via `ConfirmationDialog.showDestructive`; 8-case test across 3 phrases.
- Chain-dedup centralized via `createChainedCompressionJobIfAbsent` (in-transaction `hasChainedChild` guard); 4-case stress test.
- `_stopRequested` flag pattern with no-await between re-check and flip; 3-case race test using a shared release completer.
- `PRAGMA foreign_keys = ON` set in `beforeOpen` (was previously unset; `parentJobId ON DELETE SET NULL` was dead code); 5-case FK + cleanup test.
- Stale `error_message` cleanup on lifted jobs — both inline in Phase 7 SET clause AND in `beforeOpen` for retroactive coverage; 3-case test.
- `markFileUnverifiedAndIncrement` atomic primitive replaces the previous two-`_safeWrite` sequence at both forward and recovery sites; 9-case counter-consistency test.
- Self-healing JOIN aggregate on `getJob`/`watchJob`/`watchAllJobs`/`watchCompletedJobs`; same test as above covers all four paths in both drift directions; reconciliation gated to drift-only.
- Size-mode `_processTransfer` mirrors SHA-256 sequence (markFileCompleted+credit BEFORE size verify); recovery branch handles size-mode + completed + pending; 3-case forward + recovery + rollback test.
- Orphaned-staging-dir cold-start sweep with two-axis liveness (PID + exe match); 5-case test including SC-010 perf budget.

Cumulative findings across all 24 rounds: **5 P1, ~36 P2, 1 documented FP** (Codex round-10 claimed PowerShell smart quotes act as string delimiters; rejected — `about_Quoting_Rules` and the existing regression test both confirm only ASCII U+0027 is a delimiter).

## Verification

### Pre-build (macOS)
- `flutter analyze` clean (0 issues).
- `flutter test` — 126 tests pass (78 baseline + 48 from feature 018's regression matrix).
- CI grep guard: `! grep -rn '\$args\[' lib/` returns 0 matches.

### Windows acceptance (operator runs on workstation — T067)

1. **Re-run the failing scenario.** Same SD card transferAndCompress, 27 files, 161 GB, `H:\` → `E:\Studio Termene\Brut - To compress\test\Canon_Reels_H`. Expected: progress bar advances during transfer phase (bytes credited live); file counter increments live; phase indicator transitions Transfer → Verify → Compress; all hashes succeed; no PowerShell parser errors in log; INFO lines for each successful copy and verify with `[job=N file=K/27 phase=...]` prefix.
2. **Negative — bytes mismatch.** Rename a source file mid-copy. File ends with `verifyStatus=mismatch` (soft fail, status=completed); other 26 complete normally. Banner offers Investigate / Retry / Skip.
3. **Negative — hash subsystem broken.** Temporarily rename `powershell.exe`. Files end with `verifyStatus=unverified`; copy progress still advances; job not marked failed.
4. **Negative — abandoned shutdown mid-verify.** Force-kill the process between copy and verify of one file. On relaunch, `recoverStaleJobs` re-enters the verify-only phase for that file; counters re-derive correctly; no double-credit.
5. **Negative — retry after verify mismatch.** Rename a source file mid-verify so dest has same size but different bytes. Operator clicks Retry. Destination is deleted; robocopy re-copies; new verify passes. No infinite loop.
6. **Negative — case-only collision.** Source tree contains `DCIM/IMG_001.MOV` and `dcim/img_001.mov` (different sub-paths, same NTFS key on dest). Preflight detects collision; `_suffixedPathAgainst` produces `img_001_1.MOV`; both files end at distinct destinations.
7. **Negative — UNC source path.** Drag a UNC path into job creation. Preflight either routes to a UNC free-space helper or shows a clear "free space check skipped" warning. Job still creates; copy still works.
8. **UI — Sources collapse.** `Ctrl+1` toggles 240↔48 px. Queue + active card expand. Persists across restart. Auto-expands on new card detected. Existing card at launch does NOT undo the persisted collapse.
9. **UI — CreateJob auto-hide.** Idle state has no empty pane. `Ctrl+N` opens form, queue narrows to 360. Save closes form, queue expands to full width.
10. **UI — Filter pills.** 5 chips visible in single horizontal-scroll row at any column width.
11. **UI — History search.** Queue's history surface finds a job by partial source path; status filter narrows to Mismatch (not just Failed) and reveals jobs whose ONLY failure was verify mismatch.
12. **UI — Diagnostics → Recent failures.** Lists jobs with non-clean verify outcomes; tapping a row opens the job's detail tabs.
13. **Workflow — auto-chain gate.** transferAndCompress with one mismatch row does NOT spawn a chained compression job. Operator clicks Accept on the mismatch row in JobCardDone; SnackBar reports "compression chain resumed"; the chained compression job appears in the queue.

### Pre-release
- Tag `v2.5.0-pre`. GitHub Actions builds Windows .exe.
- Operator runs full acceptance.
- Promote to `v2.5.0` after acceptance (delete the `-pre` suffix).

## Deferred to v3.0

- Ctrl+H to focus the history search box (P3 nice-to-have; the search box is always visible).
- Date-range filter / timeline visualization on the history surface.
- Multi-select bulk actions on history rows.
- ConfirmationDialog.showCritical consolidation for the SD-erase path (the bespoke typed-confirmation in `erase_drive_action.dart` still satisfies FR-047 in spirit; planned to bundle with the next destructive-action feature — NAS upload "Disconnect & wipe local cache").

## Co-author

🤖 Implementation co-authored with Claude Opus 4.7 (1M context).
