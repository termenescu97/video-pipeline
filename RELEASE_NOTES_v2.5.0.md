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
- **Round-25** (US6 staging-sweep focused review): 2 P1 + 4 P2 + 1 P3. P1 #1 — cross-machine NAS false-positive deletion (machine A's marker swept by machine B); P1 #2 — cold-start hang on flaky NAS (sync `Directory.listSync`). Four of the five P1/P2 findings collapsed into one design simplification: rely on the existing OS InstanceLock + sweep-runs-first ordering invariants, and use ONLY `host=` in the marker for liveness decisions. PID + exe become diagnostic-only. Async `Directory.list()` with 2-second per-root timeout for NAS guard. `getMostRecentCompletedJob` replaced with `getRecentTerminalJobs(limit: 10)` to cover both successful and failed terminations (P2 #3). Test case 3 redesigned from "self pid+exe preserve" to "foreign host preserve".

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

Cumulative findings across all 25 rounds: **7 P1, ~40 P2, 1 documented FP** (Codex round-10 claimed PowerShell smart quotes act as string delimiters; rejected — `about_Quoting_Rules` and the existing regression test both confirm only ASCII U+0027 is a delimiter).

### Workflow-integrity hardening (019)

After 018 closed, the operator asked "what next to make sure we have done everything we could to make this bulletproof for going to production with real video data." That question seeded a holistic threat-model audit: parallel Opus + Codex agents (Codex round 26) each ran the same 5-tier framework — source data loss, destination corruption, subprocess attack surface, state/counter correctness, operational resilience — across the entire codebase, not just feature deltas. The audit surfaced workflow-level invariants that 25 incremental review rounds had missed because each round was scoped to a single feature.

**Convergent findings (both auditors flagged independently)** — 5 closed:
- F-1 (P1 CERTAIN both): drive-letter remap on reinsert — paused job stores `Job.sourcePath = 'E:\\'`; if reinsert mounts as `F:\\`, retry hits not-found OR worse, hits a different camera's card with similar folder structure. Closed by `Job.sourceDriveSerial` capture-at-create + WMI re-check at transfer-resume + erase-eligibility (5-branch logic with sentinel for v8 migration).
- F-2 (P1 CERTAIN both): erase-time card-content reconciliation — operator queues batch, camera flushes one more clip 30s later, batch runs, operator clicks Erase; the new clip is destroyed because eligibility only verified PLANNED files, not what's currently on the card. Closed by `unplannedFilesRefusalMessage` (case-insensitive `p.canonicalize` + `toLowerCase`).
- F-3 (P1 LIKELY Opus + P2 Codex): source-side symlink guard — 017B added DEST-side `followLinks: false`; the source mirror was never added. Closed by adding the same `followLinks: false` + per-entry type check to `DriveService.listVideoFiles`, `prepTestCards`, and `JobQueueService.createBatchTransferJobs` enumeration.
- F-4 (P2 both): `forceDestDeleteApproved` clear ordering — top-of-loop clear races with operator-driven Retry banner clicks landing AFTER iteration started. Closed by moving the clear to AFTER `markFileCompleted(verified: false)` in BOTH SHA-256 and size-mode paths. Round-27b extended this with a recovery-time clear so a crash-survived flag can't fire implicitly.
- F-5 (P2 both): HandBrake compression staging-dir convention — 017A added `.tmp_robocopy_*` staging for transfer; compression still wrote partial `.mp4`s directly to dest. Closed by mirroring the staging-dir pattern with `.tmp_handbrake_copiatorul3000_*` prefix; sweep matcher updated; sweep walk made recursive (round-27b P2 #4 — HandBrake preserves source folder hierarchy, nested staging dirs were missed by non-recursive walk).

**Bundled cheap defenses** — 3:
- Slack `_getWebhookUrl()` moved INSIDE `_send`'s try block (settings-load failure no longer propagates to main pipeline).
- SHA-256 hash long-path prefix `\\?\` for paths > 240 chars.
- `drive_service::_runPowerShell` length-3 argv enforcement via runtime `StateError` (not `assert` — `flutter build windows --release` strips asserts) + permanent CI grep guard against the `$args[` pattern.

**Single-auditor findings explicitly deferred to v2.5.1** — 5 (rationale per CLAUDE.md "Deferred to v2.5.1"): F-D1 (size-mode TOCTOU between robocopy and verifyTransfer), F-D3 (sweep prefix collision with unrelated tools), F-D4 (cross-machine NAS staging-tag collision), F-D5 (DST/clock-jump mtime cutoff), F-D8 (eraseDrive Remove-Item -LiteralPath re-verify after symlink guard).

**Codex review verdicts**:
- **Round-27a** (post-design adversarial review): 1 P1 + 5 P2 + 3 P3. P1 — sentinel ambiguity (null in `sourceDriveSerial` would mean both "legacy v8" AND "v9 capture failed"), closed by explicit `'__legacy_v8__'` sentinel backfilled at migration + fail-closed-at-create rule. P2s folded: Dart `assert` strips in release builds (replaced with runtime `StateError`), HandBrake rename atomicity wrap, prefix-narrowing for sweep matcher, long-path threshold tuning, single vs batch identity-refused error semantics.
- **Round-27b** (post-implement adversarial review): 0 P1 + 4 P2 + 2 P3. All folded: legacy-job banner now surfaces via new `QueueStateNotifier.operatorMessages` stream → SnackBar (was log-only); queue starvation closed via new `getNextQueuedJobExcluding(Set<int>)` so the executor advances past identity-paused jobs; batch identity-refusal reported as distinct `identityRefused` axis; HandBrake sweep made recursive; recovery branch clears stale `forceDestDeleteApproved`; CI grep guard added to `.github/workflows/build.yml`.

Schema bump v8 → v9: one new column `Job.sourceDriveSerial`, sentinel-backfilled (`'__legacy_v8__'`) for existing v8 rows in a single Drift transaction. No data backfill loss — sentinel is the authoritative "this row pre-dates identity tracking" marker, and the executor's branch (a) handles it explicitly with a one-time-per-launch operator-visible banner.

Test count: 126 (post-018) → **161 passing** after 019 (added 35 cases across 9 new test files: migration_v8_to_v9, handbrake_staging, slack_settings_failure, long_path_hash, runpowershell_argv_guard, drive_identity_check, force_delete_deferred_clear, source_symlink_guard, erase_rescan).

## Verification

### Pre-build (macOS)
- `flutter analyze` clean (0 issues).
- `flutter test` — 161 tests pass (78 baseline + 48 from 018 + 35 from 019).
- CI grep guard: `! grep -rn '\$args\[' lib/` returns 0 matches; the same guard now runs as a workflow step on every tagged build (`.github/workflows/build.yml`).

### Pre-flight safety (operator does this BEFORE step 1)

We're still in MVP / continuous-testing phase — fresh build folder per cycle, the `.db` content is disposable. The protections below focus exclusively on the data that ISN'T disposable: bytes on the SD card and bytes at the destination.

- **Smoke test with one small card BEFORE the 161 GB run.** Connect a single SD card with ~10 GB and run a transferAndCompress against a temp destination (e.g. `E:\v2.5.0-smoke\`). Watch for: progress bar advances during transfer, file counter increments live, INFO lines in `copiatorul3000.log` for each successful copy + verify, no PowerShell parser errors. If anything looks off here, STOP and report — do NOT proceed to the 161 GB run.
- **Source data invariant.** SD cards stay in the camera/reader during the entire run. Do NOT format the card on the camera until the v2.5.0 run reports clean and you've spot-checked at least 3 destination files (open one, scrub through, confirm playback). The app's "Erase drive" action is a separate operator step requiring typed-confirmation; it is never automatic.
- **Diagnostics screenshot before tagging promotion.** After the 161 GB run completes, open Settings → Diagnostics, screenshot the panel (instance-lock state, log path, HandBrake detection, recent failures section). This artifact lives with the release for future post-mortem if anything regresses later.

If the app behaves weirdly in ways unrelated to the actual file transfer (UI state confused, queue showing stale rows, history out of sync), the MVP-context fix is: close the app, delete `%APPDATA%\com.example\video_pipeline\video_pipeline.db`, relaunch. Fresh schema, no real history lost.

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

#### 019-specific must-fix verification (added by holistic audit)

14. **Card-swap guard at transfer-resume (F-1).** Create a transferAndCompress job for SD card "A" mounted at `H:\`. Stop the queue mid-transfer. Eject card A, insert a different card "B" at the same drive letter. Resume. Expected: job pauses with banner "Card identity mismatch at H:\ — original: <serial-A>, current: <serial-B>. Re-insert the original card to resume." Card B is NOT touched. Re-insert card A → resume succeeds.
15. **Erase-time card rescan (F-2).** Create + complete a transfer for 5 files on SD card "A". Before clicking Erase, copy ONE additional file to the card via Explorer (simulate camera flush). Click Erase → typed-confirmation dialog. Expected: refusal message "1 file(s) added to the card since the job was created — including <filename>". Erase is BLOCKED until operator deletes the new file or re-creates the job.
16. **Source-side symlink guard (F-3).** On the SD card root, create a symlink/junction pointing to a directory OUTSIDE the card (`mklink /J H:\leak C:\Users\...\Documents`). Create a transfer job. Expected: planned set excludes the symlink target's contents; log shows `createBatchTransferJobs: skipped symlink at H:\leak`. Without this guard, the destination would silently expand to include unrelated documents.
17. **Force-delete deferred clear (F-4).** Trigger a verify mismatch on file K. Click Retry from the banner. Mid-retry (after robocopy returns but before next file iteration), force-kill the app. Relaunch. Expected: file K's `forceDestDeleteApproved` is cleared during recovery — the next manual Retry requires a FRESH banner click. No implicit re-fire of the destructive flag.
18. **HandBrake nested staging dir sweep.** Run a transferAndCompress that produces a nested output structure (`E:\out\Camera1\Day1\file.mp4`). Force-kill mid-compression so a `.tmp_handbrake_copiatorul3000_*` dir is left under `E:\out\Camera1\Day1\`. Relaunch. Expected: cold-start sweep walks recursively and removes the orphan staging dir; INFO log line `startup-sweep: removed orphan staging dir <path>`.
19. **Long-path SHA-256 (T031 manual gate).** Create a destination path > 260 chars (deeply nested folder hierarchy). Run a SHA-256-mode transfer. Expected: hash succeeds — the `\\?\` prefix correctly enables long-path semantics in PowerShell 5.1's `Get-FileHash -LiteralPath`. Without the prefix, the call would fail with "FileNotFoundException" despite the file existing.
20. **Legacy-job banner SnackBar.** Migrate a v8-era `.db` to v9 (or manually `UPDATE jobs SET source_drive_serial = '__legacy_v8__' WHERE id = N`). Resume that job. Expected: SnackBar appears at the bottom of the screen: "Job pre-dates drive-identity tracking — re-create to enable card-swap detection. Proceeding without identity check." Same job resumed again in the same launch does NOT re-show the SnackBar (one-time-per-launch).
21. **Batch identity-refused vs empty-card distinction.** Insert two SD cards, one with WMI returning a serial, one where WMI returns null (simulate by ejecting at the right moment, or use a card reader that strips identity). Run "Copy All Cards". Expected: SnackBar reports "Created 1 jobs, refused 1 card (could not read serial — re-insert and retry)" — distinct from "skipped N empty cards".

### Pre-release

**Merge sequence** (older feature branches first so each merge integrates cleanly with the next):

```bash
# From main, fast-forward through each feature branch in order
git checkout main
git merge --no-ff 017-executor-correctness
git merge --no-ff 017-ux-restructuring
git merge --no-ff 018-pre-tag-hardening
git merge --no-ff 019-workflow-integrity-hardening

# Tag the pre-release (GitHub Actions: builds Windows .exe + uploads zip
# to GitHub Releases under v2.5.0-pre).
git tag v2.5.0-pre
git push origin main v2.5.0-pre
```

The `-pre` suffix keeps the build out of `/releases/latest` so end-users on v2.4.0 don't auto-prompt to upgrade until acceptance passes.

**Acceptance + promote**:
1. Operator downloads the v2.5.0-pre Windows .exe from GitHub Releases.
2. Operator runs the focused 4-tier checklist in **`OPERATOR_QA_v2.5.0.md`** (extracted from the 21 steps above into Pre-flight → Smoke (15 min) → 161 GB run (4 hours unattended) → UI (30 min) → optional negative tests). Tier 1 + 2 + 3 are mandatory for ship; Tier 4 is "try to break it on purpose" and not blocking.
3. Findings logged to `specs/020-v2.5.1-field-findings/spec.md` → "Operator-reported findings". Don't keep findings in chat scrollback — they get lost.
4. After clean acceptance: re-tag without the `-pre` suffix.

```bash
git tag v2.5.0          # same commit as v2.5.0-pre
git push origin v2.5.0
```

GitHub Actions builds again, uploads `v2.5.0` zip to Releases, and the in-app update prompt now points operators on v2.4.0 to v2.5.0.

### Recovery procedures (if something breaks after promote)

MVP context: DB issues are recoverable by deleting `%APPDATA%\com.example\video_pipeline\video_pipeline.db` and relaunching. The bytes on disk (source SD + destination files) are the data that matters.

- **Symptom: app launches but the queue/history shows stale or wrong counts.** Self-healing reads (018 T022) correct on the next emission. If still wrong after a relaunch, delete the `.db` and re-create the job.
- **Symptom: app crashes on launch immediately after upgrade.** Delete the `.db` and relaunch — fresh v8 schema, no real history lost. If it still crashes, reinstall v2.4.0 from GitHub Releases and report.
- **Symptom: a transfer reports completed but a destination file is missing/corrupt.** Source SD card is intact (we do not auto-erase). Re-run a per-file Retry from the JobCardDone menu, or re-create the job. The job's audit tab shows source/destination hashes for every file in SHA-256 mode — diff those.
- **Symptom: orphaned `.tmp_robocopy_*` dirs in destination.** Cold-start sweep removes them on next launch (018 T027). If they persist across restarts, check the `.live` marker's `host=` field — if it says another machine, that's working as designed (cross-machine NAS guard).

## Deferred to v3.0

- Ctrl+H to focus the history search box (P3 nice-to-have; the search box is always visible).
- Date-range filter / timeline visualization on the history surface.
- Multi-select bulk actions on history rows.
- ConfirmationDialog.showCritical consolidation for the SD-erase path (the bespoke typed-confirmation in `erase_drive_action.dart` still satisfies FR-047 in spirit; planned to bundle with the next destructive-action feature — NAS upload "Disconnect & wipe local cache").

## Co-author

🤖 Implementation co-authored with Claude Opus 4.7 (1M context).
