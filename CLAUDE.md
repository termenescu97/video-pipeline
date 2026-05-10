# Copiatorul3000

## What This Is

A Flutter desktop app (Windows 11) that automates the video production team's post-shoot workflow: detecting SD cards, transferring video files via robocopy, compressing via HandBrakeCLI, and notifying via Slack. Built as a single Dart/Flutter codebase that compiles to a Windows `.exe`.

**Project location**: `~/Music/copiatorul3000/`
**GitHub repo**: https://github.com/termenescu97/video-pipeline (public)
**Target users**: Non-technical video editors on a single Windows 11 machine

## Development Methodology

We use **Spec-Kit (spec-driven development)** from GitHub. The flow for every feature is:

```
/speckit-constitution → /speckit-specify → /speckit-clarify → /speckit-plan → /speckit-tasks → /speckit-implement
```

Each step creates artifacts in `specs/NNN-feature-name/`:
- `spec.md` — what and why (user stories, requirements, success criteria)
- `plan.md` — how (architecture, tech decisions, file changes)
- `research.md` — technical decisions with rationale
- `tasks.md` — ordered checklist of implementation tasks
- `data-model.md`, `contracts/`, `quickstart.md` — supporting artifacts

The project constitution is at `.specify/memory/constitution.md` with 6 principles:
1. **Human-in-the-Loop** — destructive actions require explicit confirmation
2. **Single Codebase** — all logic in Flutter/Dart, single `.exe`
3. **Resilient Pipeline** — resumable transfers, verified copies
4. **Minimal Complexity** — orchestrate CLI tools, don't reimplement
5. **Observable Progress** — real-time GUI + Slack notifications
6. **Update Transparency** — prompted updates, never silent

## Tech Stack

- **Language**: Dart 3.x / Flutter 3.x (desktop, Windows target)
- **Database**: SQLite via Drift ORM (`sqflite_common_ffi`)
- **File transfer**: robocopy (Windows built-in, `/Z` for resumable)
- **Compression**: HandBrakeCLI (presets read from `%APPDATA%\HandBrake\presets.json`)
- **Notifications**: Slack incoming webhook via `dio`
- **Window management**: `window_manager` (min size 800x600)
- **System tray**: `tray_manager`
- **Folder picker**: `file_picker`
- **CI/CD**: GitHub Actions — builds Windows `.exe` on tag push, creates GitHub Release

## Architecture

```
lib/
├── main.dart                    # Entry point, singleton services
├── app.dart                     # MaterialApp, update check on launch
├── database/
│   ├── database.dart            # Drift database class (schema v5)
│   ├── tables.dart              # Job, JobFile, FavoritePath, AppSettings
│   ├── extensions.dart          # Extension methods on JobType, JobStatus, FileStatus
│   └── daos/                    # Data access objects (JobDao, JobFileDao, etc.)
├── services/
│   ├── job_queue_service.dart   # Queue processing, auto-chain, batch creation, progress notifier
│   ├── transfer_service.dart    # Robocopy subprocess via ProcessRunner, SHA-256 hashing
│   ├── compression_service.dart # HandBrakeCLI subprocess via ProcessRunner
│   ├── slack_service.dart       # Webhook notifications (with operator name + verification method)
│   ├── drive_service.dart       # SD card detection, disk space, erase, test card prep
│   ├── log_service.dart         # Persistent file logger (copiatorul3000.log)
│   └── update_service.dart      # GitHub Releases API check
├── ui/
│   ├── screens/
│   │   ├── shell_screen.dart    # Master-detail layout, keyboard shortcuts, system tray
│   │   ├── home_screen.dart     # Left panel: job queue, batch copy, start/stop, history
│   │   ├── create_job_screen.dart # Right panel: job creation form
│   │   ├── job_detail_screen.dart # Right panel: job progress, retry, erase
│   │   └── settings_screen.dart   # Slack webhook, operator name, update toggle, test card prep
│   ├── widgets/                 # JobCard variants (active/queued/done/next-up), DriveList,
│   │                            #   ProgressBar, ConfirmationDialog, ConflictDialog,
│   │                            #   StatusBar, SourcesPanel, ActivityPanel, PlanSummaryPanel,
│   │                            #   DetailTabs (Files/Audit/Errors), KeyboardCheatSheet,
│   │                            #   HandbrakeBanner, RecoveredChip, SkeletonRow, EraseDriveAction
│   └── theme/app_theme.dart     # StatusColors theme extension, Insets, AppTextStyles
└── utils/
    ├── constants.dart           # Video extensions, robocopy flags, regex patterns
    ├── format_utils.dart        # formatBytes, formatDuration, formatSpeed, formatRelativeTime
    ├── error_mapper.dart        # Raw errors → human-friendly messages
    ├── process_runner.dart      # Shared subprocess stdout/stderr streaming
    ├── robocopy_parser.dart     # Parse robocopy output and exit codes
    ├── handbrake_parser.dart    # Parse HandBrakeCLI progress output
    └── instance_lock.dart       # PID-based single-instance lock
```

## Current State (as of 2026-05-08)

### Completed Features (13 spec-kit features)

| Feature | Branch | Tasks | Status |
|---------|--------|-------|--------|
| 001 - Video Pipeline Automation | `001-video-pipeline-automation` | 43/43 | ✅ Complete |
| 002 - UI Improvements | `002-ui-improvements` | 5/5 | ✅ Complete |
| 003 - Critical Bug Fixes | `003-fix-critical-bugs` | 23/23 | ✅ Complete |
| 004 - Core UX Improvements | `004-core-ux-improvements` | 42/42 | ✅ Complete |
| 005 - Polish & Code Quality | `005-polish-code-quality` | 29/29 | ✅ Complete |
| 007 - Critical Bug Fixes (v2) | `007-critical-bug-fixes` | 10/10 | ✅ Complete |
| 008 - High-Priority QA Fixes | `008-high-priority-qa-fixes` | 14/14 | ✅ Complete |
| 009 - Product Gaps | `009-product-gaps` | 21/21 | ✅ Complete |
| 010 - Medium Fixes | `010-medium-fixes` | 21/21 | ✅ Complete |
| 011 - SHA-256 Verification | `011-sha256-verification` | 19/19 | ✅ Complete |
| 012 - Test Card Prep | `012-test-card-prep` | 4/4 | ✅ Complete |
| 013 - Data Safety & Reliability Hardening | `013-data-safety-hardening` | 46/46 | ✅ Complete |
| 014 - UI/UX Redesign — Visual Hierarchy & Operator Trust | `014-ui-redesign` | 114/114 | ✅ Complete |
| 015 - Robocopy Execution-Time Overwrite Guard | merged into v2.4.0 | n/a | ✅ Complete (bundled) |
| 016 - Graceful Shutdown Race Hardening | merged into v2.4.0 | n/a | ✅ Complete (bundled) |
| 017A - Executor Correctness (data-safety pass) | `017-executor-correctness` | implementation complete | 🟡 v2.5.0-pending QA |
| 017B - UX Restructuring | `017-ux-restructuring` | implementation complete | 🟡 v2.5.0-pending QA |

**Latest release**: v2.4.0 (tagged 2026-05-08; GitHub Actions building Windows .exe)
**Previous release**: v2.3.0 (tagged, built via GitHub Actions)
**Total tasks implemented**: 392 (390 across 014 + 015 + 016 bundles)
**In flight (v2.5.0)**: operator's 2026-05-08 Windows test exposed three executor blockers (PowerShell positional-args cascade, 0/27 progress freeze, hash-failure-treated-as-job-failure) PLUS three UX failures (open-all-the-time panels, filter-pill wrap, fragile cross-job history). 017A is the executor-correctness half; 017B is the UX restructuring half; both ship under the v2.5.0 tag. Schema bumped to v8: `VerifyStatus` enum (5 states: pending/verified/mismatch/unverified/notVerified), `FailureKind` enum, `Job.parentJobId`, `Job.unverifiedFiles`, `JobFile.forceDestDeleteApproved`, `AppSettings.sourcesPanelCollapsed`. **20 Codex adversarial-review rounds** across both branches; cumulative findings: 4 P1, ~32 P2, 1 documented FP. Awaiting operator Windows acceptance (T067) before tagging `v2.5.0`.

> **QA status**: T114 (Windows manual QA) is the operator's responsibility on the workstation. Update prompt is gated by Constitution Principle VI — never silent — so operators see and approve the v2.3 → v2.4 transition before applying.

### What Works

- Job queue with per-job configuration (source, destination, preset, auto-chain)
- Batch "Copy All Cards" — one click to queue all detected SD cards
- Robocopy-based transfer with file verification (size comparison)
- HandBrakeCLI compression with preset dropdown
- Slack notifications at every phase transition
- Master-detail desktop layout (queue left, detail right)
- Keyboard shortcuts (Ctrl+N, Ctrl+Enter)
- Right-click context menus on job cards
- Drag-to-reorder queue
- Job history section
- Retry failed jobs
- SD card erase with verification gates and drive identity check
- Disk space indicator and insufficient space warning
- Human-friendly error messages with technical details expandable
- HandBrake installation detection with banner
- System tray icon
- Auto-update check from GitHub Releases (prompted, never silent)
- Native folder picker (file_picker)
- Favorites system for frequently used paths
- Last-used destination auto-fill across sessions
- Debounced settings save
- Operator name tracking (in settings, jobs, Slack messages)
- CSV history export via file save dialog
- Relative timestamps on history cards
- Real-time progress bar with speed (MB/s), ETA, current filename
- Persistent local log file (copiatorul3000.log next to executable)
- Single-instance lock (PID-based, prevents database corruption)
- Slack webhook unconfigured banner on home screen
- First-run welcome/onboarding state
- Path length warning for Windows 260-char limit
- Optional SHA-256 hash verification per job (toggle in creation form + batch copy)
- Hash audit trail — source and destination hashes stored per file, viewable in UI
- Test card prep utility (one-click SD card setup for QA testing)
- Per-card destination subfolders in batch copy (`label_driveletter` format) — prevents cross-card collisions
- Destination conflict detection at job creation time (skip / rename / new folder / typed-overwrite confirmation)
- Crash recovery for in-progress jobs on startup (recovered to paused for operator review)
- Atomic transactional job creation (zero-file guard prevents phantom jobs)
- Erase safety: serial-number identity re-verification + typed-confirmation TextField
- Size-only verification warning shown inside the erase dialog
- Cancellable SHA-256 hashing (parallel-safe, killable mid-stream)
- Graceful shutdown for both window close and tray quit (now phased + abandonment-aware — see 016 in load-bearing conventions)
- OS-level instance lock (atomic acquisition via RandomAccessFile.lock, fail-closed)
- Queue ordering matches drag-and-drop display order (sortOrder, then createdAt)

### What Works (014 + 015 + 016, v2.4.0)

- Three-column shell: Sources (left, 240px) / Queue + inline Detail (center, flex) / Activity (right, 300px)
- Slim StatusBar with single-color state dot + queue summary (replaces bare AppBar; tray tooltip mirrors)
- Job card variants: Active (hero with shimmering progress) / NextUp (hero with Start CTA) / Queued (slim row, drag handle) / Done (dimmed history); router picks per status
- Inline detail tabs (Files / Audit / Errors) expand within the active card — no separate route
- Per-file SHA-256 hash popover with copy-to-clipboard
- Live SD card sources panel with auto-refresh polling and "Listening for cards" pulse
- Live PlanSummaryPanel in CreateJobScreen (file count · bytes · free-space verdict · conflict count · long-path "View files" link); replaces v2.3.0's blocking AlertDialogs
- Review-first "Copy All Cards" dialog with detected-cards confirmation step
- Side-nav Settings: Notifications / Operator / Behavior / Diagnostics / About; persistent default verification + conflict-handling preferences (schema v6)
- Diagnostics panel: instance-lock state, log path with "Reveal in Explorer", HandBrake detection, Prep Test Cards
- Failed-jobs banner ("N failed — review") with [Retry all] [Dismiss]; dismiss persists per-ID until a NEW failure
- Completion celebration card ("All cards copied & verified") with sequential per-card erase CTA
- "Recovered after restart" chip on jobs rescued from a previous crash
- 12 keyboard shortcuts (Ctrl+N, Ctrl+Shift+C, Ctrl+Enter, Ctrl+,, ?, F1, ↑, ↓, Space, Delete, Ctrl+R, Ctrl+L, Ctrl+E) with discoverability via `?` cheat sheet modal
- Typed-confirmation gate on every non-conflict destructive action (severity-aware: destructive vs critical) — no more button-only confirms for delete/erase/overwrite
- ConflictDialog shows source ↔ destination sizes side-by-side with "(identical size)" / "(very different)" hint
- Visible drag handle (☰) on queued/next-up cards; click on card body expands inline (no drag conflict)
- Skeleton-row shimmer placeholders during first-load on Sources, Queue, and FilesTab
- HandBrake-not-installed banner extracted to its own widget; renders in HomeScreen warning slot AND CreateJobScreen
- Material 3 with `StatusColors` theme extension used everywhere; `Insets.*` spacing scale + `AppTextStyles` typography scale (tabular figures on numerics so digit changes don't reflow); JetBrains Mono for paths/hashes

**015 — Robocopy execution-time overwrite guard:**
- `robocopyFlags` always carries `/XN /XC /XO` so robocopy itself refuses to overwrite a non-empty dest. The executor in `JobQueueService._processTransfer` is the ONLY thing that may delete a dest before invoking robocopy — and only when the operator explicitly approved overwrite at preflight, OR when we're resuming our own `/Z` partial.
- Schema v7 adds `JobFile.wasOverwriteApproved` — set at preflight in `_applyResolution` only for files whose dest existed at that moment. Survives retry; never cleared.
- Split delete-rule: `wasOverwriteApproved || (everAttempted && isPartial)`. The `everAttempted` signal comes from preserved `JobFile.startedAt` (resetFileToPending / recoverStaleJobs / resetJobForRetry deliberately do NOT clear it).
- mtime cutoff TOCTOU guard: dest files modified after `Job.createdAt` are treated as foreign intrusions, not own partials — refuses delete-then-copy unless approved.
- Symlink/junction guard at dest: `FileSystemEntity.type` checked before delete; non-files refuse the unlink path.
- Per-file `FileSystemException` on delete is isolated — that one file fails, queue continues.
- `prepTestCards` re-verifies SD-card serial number per-card before deleting `DCIM/100TEST`.

**016 — Graceful shutdown race hardening:**
- `shell_screen.dart::_gracefulShutdown` is phased with phase-local timeouts: Phase A (acquire flag) → Phase B (10s queue drain via `stopProcessing()`) → Phase C (5s `database.close()`, instance lock release, 2s log close). Phase C ALWAYS runs regardless of Phase B drain outcome — never wrapped in a single timeout.
- `JobQueueService._shutdownAbandoned` flag flips when Phase B times out. `markShutdownAbandoned()` is the public setter.
- `_safeWrite(op)` wrapper sits in front of every DAO write inside the processing loop and `_processJob` / `_processTransfer` / `_processCompression` (~25 sites). When `_shutdownAbandoned` is true, the wrapper drops writes silently; otherwise it rethrows real exceptions. Bypassing it can deadlock shutdown or write into a closed DB.
- `recoverStaleJobs` writes audit-log entries via injected `LogService` so post-mortem can trace which jobs were rescued.
- DriveService `_runPowerShell` takes a `tag` param and logs every non-zero exit. Per-helper failure logging — no more silent PowerShell flakiness.
- `TransferService.computeFileHash` catches `(e, st)`, captures stderr, logs root cause.
- `completedBytes` accumulator is threaded through every job-completion path in JobQueueService — final byte progress no longer staler than `completedFiles`.
- HandBrake banner detection cached at module level (was probing PATH on every rebuild).
- `RecoveredChip` extracted as shared widget; was duplicated between `job_card_queued.dart` and `job_card_next_up.dart`.
- Compression failure → honest Slack `notifyJobFailed`, not a green checkmark.

### Load-Bearing Conventions (don't break these without updating the relevant feature spec)

These invariants encode the v2.4.0 hardening from 015 + 016. A naive refactor that erases them re-opens a CRITICAL or HIGH bug. Each line names the file you'd touch:

- **`_safeWrite` wrapper (`lib/services/job_queue_service.dart`)** — required for ALL DAO writes inside the processing loop, `_processJob`, `_processTransfer`, `_processCompression`. Bypassing it can deadlock shutdown or write into a closed DB during Phase C cleanup.
- **`JobFile.startedAt` is preserved across resets (`lib/database/daos/job_file_dao.dart`, `lib/database/daos/job_dao.dart`)** — `resetFileToPending`, `recoverStaleJobs`, `resetJobForRetry` deliberately do NOT clear it. The 015 executor uses `file.startedAt != null` to distinguish own `/Z` partials from TOCTOU intrusions. If you find yourself "cleaning up" the reset, read 015's plan first.
- **`JobFile.wasOverwriteApproved` semantics (`lib/services/job_queue_service.dart::_applyResolution`)** — set ONLY at preflight time, ONLY for files whose dest existed at that moment. Survives retry. Never cleared. The executor honors it absolutely (delete-then-copy regardless of size).
- **`Job.createdAt` is the mtime cutoff baseline (`lib/services/job_queue_service.dart::_processTransfer`)** — never modify on retry/resume. Changing it shifts the TOCTOU guard window and could reclassify foreign intrusions as own partials.
- **`robocopyFlags` (`lib/utils/constants.dart`)** — must include `/XN /XC /XO`. Removing them re-opens the v2.4.0 CRITICAL (silent overwrite). The flags are paired with executor-side delete logic; changing one without the other breaks the contract.
- **Phased shutdown structure (`lib/ui/screens/shell_screen.dart::_gracefulShutdown`)** — Phase C cleanup (DB close, lock release, log close) must ALWAYS run regardless of Phase B drain outcome. Don't wrap them in a single outer timeout. If a refactor makes the function shorter, it's probably wrong.
- **`PlannedFile` is the consolidated shape (`lib/services/planned_file.dart`)** — 017A T024 unified the previously duplicated `_PlannedFile` across `job_queue_service.dart` and `create_job_screen.dart`. Both consumers now import the public, immutable class with `copyWith`, value equality, and a contract test (`test/contract/planned_file_contract_test.dart`) that fails fast if either consumer's expected shape diverges. A new field added on one side without the other will break the build.

### v8 (017A) Load-Bearing Conventions

These invariants encode the 017A executor-correctness pass that closes the operator's 2026-05-08 Windows test failures (PowerShell `$args[0]` cascade, 0/27 progress freeze, hash-failure-treated-as-job-failure). Schema v8 introduced two orthogonal axes — the existing `FileStatus` (copy state) and the new `VerifyStatus` (verify state) — and the executor now treats progress and verify as fully decoupled.

- **Length-3 argv is the only valid PowerShell shape (`lib/utils/process_runner.dart`)** — `runPowerShellInline` asserts `arguments.length == 3` for `['-NoProfile', '-Command', script]`. Trailing argv after `-Command` is silently dropped by PS — the v2.4.0 root cause. Embed values via single-quoted `-LiteralPath '${escapePsLiteral(value)}'`, never as a 4th argv element. CI grep guard `! grep -rn '\$args\[' lib/` enforces this forever.
- **`markFileCompleted(verified: false)` is the post-robocopy signal (`lib/database/daos/job_file_dao.dart` + `_processTransfer`)** — bytes are credited to `Job.completedFiles`/`Job.completedBytes` IMMEDIATELY after robocopy returns, in a separate `_safeWrite` call. Do not gate this on verify outcome. The two `_safeWrite` calls (markFileCompleted + updateJobProgress) make the 0/27 freeze structurally impossible to reproduce.
- **`VerifyStatus` × `FailureKind` axes are independent of `FileStatus` (`lib/database/tables.dart`)** — a file can be `status=completed && verifyStatus=mismatch` (bytes on disk, hash differs — soft failure, FR-004). A subsystem failure routes through `verifyStatus=unverified && failureKind=verifyUnreliable` (warning, not hard failure). Do not collapse these axes back to a single `verified` boolean.
- **`Job.parentJobId` is set ONLY at chain time (`_createChainedCompressionJob`)** — links a chained-compression job back to its transfer parent so `notifyCompressionCompleted` can surface parent verify counts. Standalone compression jobs have `parentJobId=null`. Resetting/copying jobs must NOT carry `parentJobId` across — that would mis-attribute verify outcomes.
- **`forceDestDeleteApproved` is operator-attribution (`JobFile.forceDestDeleteApproved`)** — persisted column (NOT an in-memory set, per Codex round-2 P2 #2 fix). Set by `retryFile(forceDestDelete: true)` in response to an explicit operator action (verify-mismatch banner Retry); cleared by `_processTransfer` on read at the top of the per-file iteration (single-use semantics). Bypasses both the feature-015 delete predicate AND the size-match short-circuit. Re-mismatch on the next pass requires a fresh banner Retry click — recovery on next launch reads `failureKind=verifyMismatch` and the persisted approval, never fires implicitly (Constitution Principle I).
- **`recoverStaleJobs` re-derives counters from per-row state (`lib/database/daos/job_dao.dart`)** — calls `recomputeCountersFromFiles(jobId)` for every rescued job. The rescued set: inProgress jobs UNION jobs with inProgress files UNION jobs with completed/verifyStatus=pending files (filtered to `verificationMode=sha256` only — Codex round-3 P2 #1: size-mode jobs never enter a SHA-256 phase, so completed+pending isn't an "abandoned mid-verify" state for them). Rescued completed/failed jobs flip to paused so `getNextQueuedJob` can pick them up (Codex round-5 P2 #1). Trusted source of truth is the per-row `JobFile` state; persisted Job counters can drift from a partial-write shutdown.
- **Case-only NTFS collisions are normalized everywhere paths get rewritten (`createBatchTransferJobs`, `create_job_screen.dart::_applyResolution`)** — `_normalizeCaseCollisionsAcrossPlans` runs between enumerate and conflict-preflight; the rebuilt-after-newFolder path also re-runs it (Codex round-9 P2 #2). Conflict-rename branches use `_suffixedPathAgainst` (collision-aware variant of `_suffixedPath`, Codex round-12 P1) that checks BOTH disk AND the lowercased planned-set so generated suffixes can't re-collide on NTFS. The legacy `_suffixedPath` is retired — every rename site goes through the collision-aware variant.
- **Robocopy renamed-destination uses staging dir (`TransferService.transferFile`)** — when the requested destination basename differs from the source basename (case-collision normalization, conflict-rename), robocopy can't rename during copy. Naive `[sourceDir, destDir, sourceBasename]` would target an existing conflict file; the post-copy rename would then move that pre-existing file to the suffixed destination — silent data loss. Fix (Codex round-7 P1): copy into a private `.tmp_robocopy_<tag>` subdir under destDir, then `File.rename` the staged file to the final path. Staging cleanup is split from rename success (Codex round-11 P3) so a failed rmdir doesn't fail an already-completed transfer. Resumed renamed transfers detect target-exists with matching size and discard the staged duplicate (Codex round-8 P2 #1).
- **Per-file retry is scope-isolated by an executor-side `failed`-row skip (`_processTransfer`)** — `requeueJobForFileRetry` (per-file path) only flips the operator-selected row to `pending`; OTHER `status=failed` rows in the same job stay failed. The executor early-skips `status=failed` rows with a `failedCount++` tally so they aren't auto-re-copied, and the post-loop branch keeps routing through `notifyJobFailed` for jobs that still have unrecovered copy errors. The "Retry failed files" path (`resetJobForRetry`) flips failed→pending FIRST, so those rows enter the loop as pending and ARE processed. Removing the early-skip would re-open Codex round-20 P2 #1 (per-file retry of a mismatch on a job with copy-error rows would re-copy those rows + silently lift the job to `completed`).
- **v7→v8 migration flips hash-only failures to status=completed (`Database._migration` Phase 4b/6/7)** — the post-copy hash patterns Phase 3 (mismatch) and Phase 4 (unverified) match are emitted by `transfer_service.dart` and `job_queue_service.dart` AFTER robocopy reported success. Phase 4b therefore flips those rows from `status=failed` to `status=completed` (legacy `verified` stays 0; failureKind preserved for audit). Phase 6 re-derives `Job.completedFiles/completedBytes/unverifiedFiles` for affected jobs; Phase 7 lifts `Job.status` from `failed` to `completed` for jobs whose only `status=failed` children were these hash-only rows. Without this restructure (Codex round-19 P2), the new Accept actions in `JobCardDone` are unreachable for migrated jobs (renders only on `JobStatus.completed`) and `maybeChainCompression` stays blocked because a non-completed file row remains.

### v8 (017B) Load-Bearing Conventions

017B is the UX restructuring half of v2.5.0. Its invariants encode operator-visible decisions and the workflow gates that prevent silent data loss after the new verify-axis Accept paths.

- **VerifyStatus has 5 states, not 4 (`lib/database/tables.dart`)** — `pending` / `verified` / `mismatch` / `unverified` / `notVerified`. The first four are SHA-256-mode outcomes; `notVerified` is the size-mode baseline added in Codex round-11 to keep size-mode rows distinct from SHA-256 subsystem failures. Slack and HistorySurface treat `notVerified` as the clean default for size-mode jobs; only `unverified` triggers warning prefixes. Switch sites must handle all 5 cases (compiler-enforced exhaustiveness).
- **`markFileSizeOnlyVerified` is the size-mode success signal (`lib/database/daos/job_file_dao.dart`)** — sets `verifyStatus=notVerified` + legacy `verified=true` + `failureKind=none`. Used by `_processTransfer`'s size-verification branch. Never write `verifyStatus=verified` on a size-mode pass — `verified` is reserved for cryptographic SHA-256 match.
- **Auto-chain compression is gated on clean verify state (`JobQueueService._processJob` + `maybeChainCompression`)** — for `transferAndCompress` jobs, the chain only fires when ALL files are at `verifyStatus IN {verified, notVerified}`. Any `mismatch` or `unverified` row suppresses the chain with a WARNING log; the operator must Retry or Accept the warnings via the JobCardDone menu, then `maybeChainCompression` (called from each Accept handler) checks the result and creates the chained child if the gate now passes (Codex round-13 + round-14 P2). `JobDao.hasChainedChild(parentJobId)` prevents duplicate chains.
- **Compression-ready filter uses the v8 axis, not legacy `verified` (`_createChainedCompressionJob`)** — `verifyStatus IN {verified, notVerified}` is the condition for compression eligibility. `acceptMismatch` and `acceptUnverified` flip `verifyStatus` but intentionally leave `verified=false` (so it doesn't lie about cryptographic trust); filtering on the legacy boolean would silently exclude every operator-accepted file from compression (Codex round-15 P1).
- **Slack truthfulness on transfer failure (`JobQueueService._processTransfer`)** — when `failedCount > 0`, the failure path routes through `notifyJobFailed` and early-returns. `notifyTransferCompleted` is reserved for paths where `markJobCompleted` was called. Without this split, a copy-failed job would send a green-checkmark Slack message because the new signature only carries verify counts, not failed-count (Codex round-13 P2 #1).
- **SourcesPanel collapse persists across restarts (`AppSettings.sourcesPanelCollapsed`)** — operator's chosen state is loaded on shell init, written via `setSourcesPanelCollapsed` on toggle. Auto-expand-on-new-card only fires when a path appears that wasn't in the previously-seen set; the FIRST poll seeds the baseline without auto-expanding (Codex round-9 P2 #1) so an existing card at launch doesn't undo the persisted preference.
- **HistorySurface reads `jobFileDao.watchAllFiles()` (`lib/ui/widgets/history_surface.dart`)** — single stream feeds both the verify-tally per job and the Diagnostics → Recent failures section. The status filter chips (All / Verified / Unverified / Mismatch / Failed) consult the tally; "Verified" means clean (status=completed AND zero unverified AND zero mismatched), not just `verifyStatus=verified`. The expansion set is shared with the active queue (HomeScreen passes `expandedJobIds`) so a card stays expanded across the queue→history transition.
- **`acceptMismatch` and `acceptUnverified` preserve the audit trail (`JobFileDao`)** — both flip `verifyStatus` to a clean state but write the operator-override message to `errorMessage` AND keep the source/destination hashes. Future reviewers can reconstruct exactly which files were operator-accepted and what their hashes were at the time. The legacy `verified` boolean is deliberately NOT flipped to true.
- **Per-file retry recomputes Job-level counters (`requeueJobForFileRetry` + `recomputeCountersFromFiles`)** — when retrying a single mismatched/unverified row from a `JobStatus.completed` job, `resetFileForRetry` flips that row back to `pending`. Without recomputing, `Job.completedFiles/completedBytes` carry the old (now-stale) counters into the next pass. `requeueJobForFileRetry` wraps the status flip + counter recompute in a single Drift transaction (Codex round-18 P2 #1) so the queue picks up correct totals before processing.
- **Success celebration suppressed on verify warnings (`startProcessing`)** — `notifyQueueAllDone` only fires when no processed job ended with `mismatch` / `unverified` rows. SHA-256 transfers ending with verify warnings still mark `Job.status=completed` (FR-004 — soft fail) but the queue-level celebration toast is suppressed via `hadVerifyWarnings` (Codex round-18 P2 #2). The per-job Slack notification still warns; the celebration is reserved for fully-clean queue runs.
- **Chained-compression Slack ping counts size-mode parents (`notifyCompressionCompleted`)** — `parentNotVerifiedFiles` is a 5th parameter alongside `parentVerifiedFiles`. Default size-mode `transferAndCompress` jobs land at `verifyStatus=notVerified`; without counting that, the Slack line read "Transfer verification: 0 verified · Passed" even on perfectly-clean runs (Codex round-20 P2 #2). Label switches to "N size-verified · Passed" for size-mode and "A verified + B size-only · Passed" for mixed-history jobs.

### v8 (018) Load-Bearing Conventions

Feature 018 was the pre-tag hardening pass before v2.5.0. Across 24 Codex adversarial-review rounds (rounds 21-24 specific to 018), 4 distinct concurrency / atomicity / freshness invariants surfaced as load-bearing for the executor's correctness contract. Each is enforced by a dedicated regression test under `test/unit/`.

- **`JobDao.applyPerFileRetry` is a single transaction (`lib/database/daos/job_dao.dart`)** — file-row reset (`resetFileForRetry`) + parent Job mutation + `recomputeCountersFromFiles` MUST be inside one `db.transaction()`. The previous two-`_safeWrite` sequence could land the file write but skip the parent flip if a Phase-B drain timed out between them, leaving the parent stuck at `JobStatus.completed` with one row at `pending`. Atomicity proven by `retry_atomicity_test.dart` (4 cases, including a `testOnlyMidTransactionHook` failure injection).
- **Typed-confirmation gate on Accept-mismatch / Accept-unverified / Skip-mismatch (`lib/ui/widgets/job_card_done.dart` + `job_card_active.dart`)** — every menu item that mutates verify state past an operator-visible warning routes through `ConfirmationDialog.showDestructive` with the literal phrases `'accept mismatch'` / `'accept unverified'` / `'skip mismatch'`. Constitution Principle I (Human-in-the-loop) — bypassing this gate via direct DAO calls is a specification violation. `typed_gate_coverage_test.dart` (8 cases × 3 phrases) pins it.
- **`createChainedCompressionJobIfAbsent` is the only chain-creation entry point (`lib/services/job_queue_service.dart`)** — `JobDao.hasChainedChild(parentJobId)` runs INSIDE the same transaction as the chain insert so two concurrent calls (auto-chain in `_processJob` + post-Accept call from `JobCardDone`) can race to the same parent without producing duplicate children. Both call sites route through this helper. `chain_dedup_test.dart` (4 cases including N=10 stress) is the contract test.
- **`_stopRequested` flag pattern with no-await between re-check and flip (`startProcessing`)** — N concurrent `startProcessing()` calls during a stop drain MUST resolve to at most one running loop. Implementation: every concurrent caller awaits `_stopCompleter.future`, then re-checks `_isProcessing` and flips it on consecutive lines with NO `await` in between (Dart's microtask FIFO ordering is the load-bearing primitive). Inserting an await between the check and the flip re-opens the race. `start_stop_race_test.dart` (3 cases) pins it via a shared release completer.
- **`PRAGMA foreign_keys = ON` set on every connection-open (`lib/database/database.dart::beforeOpen`)** — per-connection setting (SQLite docs); MUST be set on every open, not just first install. The `parentJobId` `ON DELETE SET NULL` constraint depends on this. `fk_pragma_and_cleanup_test.dart` (5 cases) verifies via real `NativeDatabase` AND in-memory.
- **`beforeOpen` cleanup statements run BEFORE the FK pragma flip (`lib/database/database.dart`)** — order is load-bearing: (1) NULL out dangling `parent_job_id` from pre-feature operators, (2) NULL out stale `error_message` on lifted jobs, (3) `CREATE INDEX IF NOT EXISTS idx_job_files_job_id`, (4) flip `PRAGMA foreign_keys = ON`. Running the cleanup AFTER the pragma flip would surface deferred FK constraint failures on the FIRST write that touches an offending row. Both cleanups are idempotent no-ops at typical project scale.
- **`markFileUnverifiedAndIncrement` is the SHA-256-subsystem-failure primitive (`lib/database/daos/job_file_dao.dart`)** — single transaction wraps the file-row write + `JobDao.incrementUnverified`. Replaces the previous two-`_safeWrite` sequence. The forward path AND the recovery branch in `_processTransfer` both call it. Bypassing it with the legacy `markFileUnverified` re-opens the FR-013 ~0.6% leak window. `counter_consistency_test.dart` case 1 + 1b proves atomicity.
- **The four DAO read paths self-heal `unverifiedFiles` via JOIN, not COUNT round-trips (`getJob`/`watchJob`/`watchAllJobs`/`watchCompletedJobs`)** — single `customSelect` with a per-job correlated sub-select returns the corrected counter inline; the persisted `jobs.unverified_files` column is a denormalized cache. `getJob` additionally schedules `recomputeCountersFromFiles` ONLY when drift detected (no write storms on the hot path). The `idx_job_files_job_id` index added in `beforeOpen` keeps the sub-select cost flat. `counter_consistency_test.dart` cases 2-8 prove all four paths self-heal in both drift directions.
- **Size-mode `_processTransfer` mirrors SHA-256 sequence exactly (`lib/services/job_queue_service.dart::_processTransfer`)** — robocopy → `markFileCompleted(verified: false)` → credit `completedCount/completedBytes` + `updateJobProgress` → `verifyTransfer` → `markFileSizeOnlyVerified` (success) or rollback + `markFileFailed` (mismatch). Bytes are credited BEFORE verify so a verify I/O stall doesn't freeze the operator's progress bar. The recovery branch handles `status=completed && verifyStatus=pending` for size-mode AND SHA-256 — `getRescuedJobIds`'s third UNION arm dropped the SHA-256 filter (Codex round-24 P2). `size_mode_progress_order_test.dart` (3 cases) pins forward + recovery + rollback.
- **`.live` marker write in `transferFile` is load-bearing (`lib/services/transfer_service.dart`)** — every staging dir gets a `.live` file with `pid` + `Platform.resolvedExecutable` immediately after creation. If the marker write fails, the transfer aborts with the original error preserved (inner try/catch on cleanup so a delete failure doesn't mask the marker-write failure; `Error.throwWithStackTrace` keeps the original stack). Without the marker, the cold-start sweep in `lib/services/startup_sweep.dart` cannot distinguish own active staging from orphans and would either delete live work or leave orphans accumulating in operator destinations. `staging_dir_sweep_test.dart` case 3 pins the self-preservation; cases 1+2 pin the orphan-removal path.

### Known Issues (from review-report-v2.md)

**Critical (fixed in 007-critical-bug-fixes)**:
1. ~~Duplicate filenames from recursive listing overwrite at destination~~ — fixed: preserves full relative path from drive root
2. ~~File marked completed then overwritten as failed (verify race)~~ — fixed: single status write per file
3. ~~ProcessRunner streams not awaited before exitCode~~ — fixed: `Stream.forEach()` + `Future.wait()`
4. ~~`exit(0)` in system tray kills without cleanup~~ — fixed: graceful shutdown sequence
5. ~~`DropdownButtonFormField.initialValue` compile error~~ — false positive: `initialValue` is correct in Flutter 3.41.9
6. ~~`createBatchTransferJobs` parameter is `List<dynamic>`~~ — fixed: typed as `List<DetectedDrive>`

**High (fixed in 008-high-priority-qa-fixes)**:
- ~~startProcessing() race condition~~ — false positive: Dart's single-threaded event loop makes the guard correct
- ~~Chained compression job missing totalFiles/totalBytes~~ — fixed: updateJobTotals called after insert
- ~~Compression preset not validated in `_canCreate()`~~ — fixed: preset null check added
- ~~Reorder indices mismatch between filtered list and DAO~~ — fixed: reorder by job ID instead of index
- ~~Retry doesn't reset completedFiles/completedBytes~~ — fixed: counters reset to 0
- ~~Context menu "Retry" has no handler~~ — fixed: onRetry callback added to JobCard
- ~~watchSettings()/getSettings() crash if settings row missing~~ — fixed: null-safe with defaults
- ~~No filesystem error handling in listVideoFiles~~ — fixed: try/catch with blocking dialog for skipped paths

**High (fixed in 009-product-gaps)**:
- ~~Progress bar ETA/speed/filename never wired~~ — fixed: ValueNotifier pipes real-time data to PipelineProgressBar
- ~~No persistent log file~~ — fixed: LogService writes to copiatorul3000.log next to executable
- ~~No single-instance lock~~ — fixed: PID-based lock file prevents concurrent instances
- ~~No Slack webhook unconfigured banner~~ — fixed: orange banner on home screen when webhook empty
- ~~No first-run onboarding~~ — fixed: welcome state with guidance on first launch (schema v3)
- ~~`githubRepo` is placeholder~~ — fixed: set to `termenescu97/video-pipeline`

**Medium (fixed in 010-medium-fixes)**:
- ~~No last-used destination memory~~ — fixed: auto-fills from settings, persists across sessions (schema v4)
- ~~No operator name tracking~~ — fixed: configurable in settings, stamped on jobs and Slack messages
- ~~No CSV export~~ — fixed: Export History button generates CSV via file save dialog
- ~~No timestamps on history cards~~ — fixed: relative timestamps ("5 min ago", "Yesterday")
- ~~Favorite label path split broken on macOS~~ — fixed: uses `p.basename()` instead of backslash split
- ~~Erase rejects lowercase drive letters~~ — fixed: regex accepts `[A-Za-z]`
- ~~No path length warning~~ — fixed: warns when destination paths exceed 260 chars
- ~~formatBytes shows "0 B" for errors~~ — fixed: shows "N/A" for negative values
- Selective file copy (PM-10) — deferred to v3.0

Full report: `specs/006-review-findings/review-report-v2.md`

**All 30 review issues resolved** (28 fixed, 2 false positives, 1 deferred to v3.0 by design).

**Critical/High (fixed in 013-data-safety-hardening)** — 14 findings from GPT 5.5 adversarial review + 7 from a follow-up Codex review of the implementation:
- ~~Cross-card collision in batch copy~~ — fixed: per-card `label_driveletter` subfolders in batch and single-job drive root
- ~~Destination files silently overwritten~~ — fixed: pre-flight conflict detection with skip/rename/new folder/typed-overwrite resolution
- ~~In-progress jobs stranded on crash~~ — fixed: `recoverStaleJobs` on startup moves them to paused
- ~~Job creation not transactional~~ — fixed: `createJobWithFiles` wraps job + files + totals in a Drift transaction with zero-file guard
- ~~SD erase TOCTOU~~ — fixed: pre/post identity comparison via WMI disk serial number + typed-confirmation field
- ~~Size-only verification unlocks erase silently~~ — fixed: prominent warning inside the erase dialog
- ~~ProcessRunner can hang on unconsumed pipes~~ — fixed: stdout/stderr always drained
- ~~Shutdown closes DB while queue is writing~~ — fixed: `stopProcessing` returns `Future<void>` resolving after state writes; window close + tray quit share the same path with a 30s safety timeout
- ~~Instance lock is non-atomic and permissive~~ — fixed: OS-level `RandomAccessFile.lock(FileLock.exclusive)`, fails closed
- ~~Reorder doesn't affect processing order~~ — fixed: `getNextQueuedJob` orders by `sortOrder`, `createdAt`
- ~~SHA-256 hashing uncancellable~~ — fixed: routed through per-call `ProcessRunner` instances; `cancel()` kills all active hash subprocesses
- ~~Chained compression flattens paths~~ — fixed: preserves relative path from transfer destination
- ~~PowerShell calls not exception-safe~~ — fixed: `_runPowerShell` helper with try/catch; `getDriveIdentity` uses `$args[0]`; `eraseDrive` uses `-LiteralPath` + `$args[0]`
- ~~Version stuck at 1.0.0~~ — fixed: single-sourced from pubspec.yaml via `package_info_plus`

### Open Bugs

None known as of v2.4.0. The robocopy overwrite-guard CRITICAL flagged in the v2.4.0 final review was implemented as feature 015 and bundled into the same release (schema v7, split delete-rule, mtime cutoff, `_safeWrite` abandonment guard). The graceful-shutdown HIGH was implemented as feature 016 (phased shutdown). Both passed Codex `--model gpt-5.5 --effort high` adversarial review.

Deferred to v2.5 (no operator-visible behavior change):
- **`ConfirmationDialog.showCritical` consolidation for the SD erase path.** The erase dialog has its own bespoke typed-confirmation gate (`erase_drive_action.dart`) that satisfies FR-047 in spirit but doesn't route through the canonical primitive added in Phase 14. Bundle with the next feature that ships a destructive action (currently planned: NAS upload "Disconnect & wipe local cache" in v3.0).

### Review & Quality Process

- **Codex plugin installed** (`openai/codex-plugin-cc`) — enables `/codex:adversarial-review` and `/codex:rescue` for GPT-powered code reviews
- **Adversarial review pattern**: after implementing a feature, run a review before merging. Has caught command injection, data loss bugs, and Constitution violations.
- **Known false positives**: QA-5 (dropdown param correct in Flutter 3.41.9), QA-7 (Dart event loop makes race guard correct)

#### Codex Adversarial-Review Cadence (validated in 015 + 016)

The pattern that worked across this session for data-safety-critical features:

- Default flags: `--model gpt-5.5 --effort high`. (`gpt-5.5-codex` is rejected by the operator's account; bare `gpt-5.5` works. Use `--effort xhigh` for data-loss-CRITICAL passes.)
- Cadence per feature: **plan v1 → Codex review → plan v2 → Codex review → implementation → Codex review → fix → Codex review → commit**. Two review rounds at each of "plan" and "implementation" is typical for non-trivial work; trivial features can do one of each.
- The reviewer can disagree on framing (e.g. v1 015 plan claimed WAL mode — wrong, it's rollback-journal). Treat factual rebuttals as load-bearing: replace the rationale, don't paper over it.
- The reviewer's CANNOT VERIFY findings still require investigation; they may be wrong, but they're rarely worthless. Resolve them by reading the code, not by handwaving.
- If the reviewer flags 9 findings, applying 8 of them with explicit pushback on the 9th is normal and good. Track which were rejected and why so future sessions don't relitigate.

### v3.0 Roadmap

- **v2.5 (next release)**: NAS upload automation. Bundle `ConfirmationDialog.showCritical` consolidation for the SD-erase path so the bespoke typed-confirmation in `erase_drive_action.dart` finally routes through the canonical primitive. NAS feature ships its own "Disconnect & wipe local cache" destructive action — same dialog primitive should serve both.
  - Convention going forward: any new destructive action defaults to `ConfirmationDialog.showCritical`. Bespoke gates require a written reason.
- **v3.0 (from PM review)**:
  - **Tier 1**: auto-detect SD cards (replace polling), dashboard stats, ~~SHA-256 verification~~ (done in 011), ~~NAS upload~~ (now v2.5).
  - **Tier 2**: Job templates, scheduled jobs, multi-machine sync, selective file copy (PM-10).
  - **Tier 3**: Cloud backup, metadata extraction, team activity feed.

## Build & Release

```bash
# Development (from ~/Music/copiatorul3000/)
flutter pub get
dart run build_runner build
flutter analyze

# Release (triggers GitHub Actions Windows build)
git tag vX.Y.Z
git push origin vX.Y.Z
# → GitHub Actions builds .exe → creates Release with zip
# → App checks GitHub Releases on launch and prompts to update
```

## Key Files for Context

- `.specify/memory/constitution.md` — project principles (6 rules)
- `specs/006-review-findings/review-report-v2.md` — latest review (30 issues + roadmap)
- `specs/001-video-pipeline-automation/spec.md` — original feature spec
- `specs/001-video-pipeline-automation/plan.md` — original architecture plan

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan at
specs/018-pre-tag-hardening/plan.md
<!-- SPECKIT END -->
