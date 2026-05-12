# Copiatorul3000

## Session Bootstrap — READ THIS FIRST

**Before responding to anything non-trivial in this repo, read the in-repo project memory.** The portable memory lives at `.claude/memory/` (index: `.claude/memory/MEMORY.md`). It encodes:

- feedback rules — project-specific case studies that informed cross-project rules (`feedback_*.md`, 4 files)
- project state, decisions, deferred work, false positives (`project_*.md`, 6 files)
- external references (Codex plugin, video team environment) (`reference_*.md`, 2 files)

> **User-global context loads alongside this layer.** `~/.claude/CLAUDE.md` (auto-loaded into every session on this machine) carries Andrei's universal working rules, tooling stack, and the Jira workflow. Cross-project rules that used to live in this repo's memory (human-in-the-loop, no half-baked, explain as course, etc.) were promoted to that file. Don't expect to find them here — read the user-global layer.

**This is not optional.** Skipping the project memory means re-asking questions answered in past sessions, re-litigating decisions already made, and re-investigating false positives already dismissed. The cost of reading these on session start is small; the cost of NOT reading them is real.

Process: at the start of any session, read `.claude/memory/MEMORY.md`, then read every linked file. The auto-memory harness mechanism (when `~/.claude/projects/<encoded-cwd>/memory/` happens to exist for the current OS path) is a convenience, not the source of truth. The repo `.claude/memory/` is the source of truth and travels with the code across machines.

## Memory writes go in the repo

When you save new memories — corrections from the user, project-state updates, new false positives, new feedback rules — write them to **`<repo-root>/.claude/memory/`** in this repo, and update **`<repo-root>/.claude/memory/MEMORY.md`** to index them. Do **NOT** write to `~/.claude/projects/<encoded-cwd>/memory/` even when the system reminder points there.

Reason: project memory must travel with the repo so future Claude Code sessions — including on different machines, after fresh installs, or after a developer hands off the project — get the full context from a single `git clone`. Memory that only lives in the user-global path is invisible to teammates, invisible across machines, and impossible to review.

Commit memory updates with `docs(memory): <short summary>`. Treat them like any other code change: small, reviewable, scoped.

For **cross-project** memories (rules that would apply to any project I work on, not just this one), write to `~/.claude/CLAUDE.md` instead — see the memory-write routing section there.

## Jira tracking

This project is tracked under **AUTO-1** (`https://termene.atlassian.net/browse/AUTO-1`). Worklog cadence and confirmation rules per `~/.claude/CLAUDE.md` Jira workflow section. Time format: `1h30m`. Always confirm time + summary with Andrei before submitting `mcp__atlassian__addWorklogToJiraIssue`.

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

## Project scope: MVP / continuous-testing phase

This is NOT a production deployment with real operator history at stake. Each test cycle installs a fresh build folder; the SQLite `.db` file at `%APPDATA%\com.example\video_pipeline\video_pipeline.db` survives across builds via path_provider's stable location, but its content is essentially throwaway state — if anything looks off, the operator can delete the `.db` and the next launch creates a fresh schema. Recommendations involving DB backups, integrity-check pragmas, schema rollback, or any "preserve operator history across upgrades" defenses are out of scope until v3.0 or later when there's real audit-trail value to protect.

What IS in scope, always: bytes on disk. Source SD card content (typed-confirmation-gated erase, never automatic) and destination video files (`/XN /XC /XO` + executor-side delete gating + optional SHA-256 verify). Hash mismatch handling, source-data invariants, destination-overwrite guards, and the human-in-the-loop principle are non-negotiable regardless of MVP status. Defensive thinking should focus there.

## Current State (as of 2026-05-11)

### Completed Features (19 spec-kit features)

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
| 018 - Pre-tag Hardening | `018-pre-tag-hardening` | 28/28 | 🟡 v2.5.0-pending QA |
| 019 - Workflow Integrity Hardening | `019-workflow-integrity-hardening` | 40/46 | 🟡 v2.5.0-pending QA |
| 020 - v2.5.1 Field Findings | `019-workflow-integrity-hardening` (skeleton) | n/a yet | ⚪ slot pre-created, populate post-acceptance |

**Latest release**: v2.4.0 (tagged 2026-05-08; GitHub Actions built Windows .exe)
**Previous release**: v2.3.0 (tagged, built via GitHub Actions)
**Total tasks implemented**: 461 (392 through v2.4.0 + 069 across 017A + 017B + 018 + 019)

**In flight (v2.5.0)**: **`v2.5.0-pre` tagged + built + locally installed**. `main` is at `e004d2c` (merged 017A → 017B → 018 → 019). GH Actions build succeeded (5m28s). Release marked Pre-release manually via `gh release edit --prerelease` (the GH Action does NOT auto-detect `-pre` as a prerelease pattern — important gotcha for future tags). v2.4.0 stays as Latest, so v2.4.0 operators don't auto-prompt to upgrade. Developer is doing pre-check QA on the installed build BEFORE handing to operator — UI fixes from this pre-check should land as v2.5.0 polish (re-tag `v2.5.0-pre-2`), not v2.5.1. See `HANDOFF_v2.5.0-pre.md` at repo root for full session-state details until that file is deleted.

The v2.5.0 release scope grew through three pressures, each captured in its own feature:

1. **017A + 017B** (operator's 2026-05-08 Windows test failure). Three executor blockers (PowerShell positional-args cascade, 0/27 progress freeze, hash-failure-treated-as-job-failure) PLUS three UX failures (open-all-the-time panels, filter-pill wrap, fragile cross-job history). 017A is the executor-correctness half; 017B is the UX restructuring half. Schema bumped to v8.
2. **018** (pre-tag hardening). Focused concurrency / atomicity / freshness pass before tagging — per-file retry atomicity, typed-gate phrase enforcement, chain-dedup transactional gate, FK pragma in beforeOpen, JOIN-based self-healing of `unverifiedFiles`, orphaned staging-dir cold-start sweep with `host=`-only liveness check.
3. **019** (workflow-integrity hardening, holistic threat-model audit). The operator's question after 018 — "what next to make sure we have done everything we could to make this bulletproof for going to production with real video data" — seeded a holistic audit (parallel Opus + Codex agents, same 5-tier framework) that caught **5 convergent workflow-level invariants 25 incremental review rounds had missed**. F-1 (drive-letter remap on reinsert), F-2 (erase-time card-content reconciliation), F-3 (source-side symlink guard), F-4 (forceDestDeleteApproved clear ordering), F-5 (HandBrake compression staging-dir convention). +3 bundled defenses. Schema bumped to v9 (`Job.sourceDriveSerial` with sentinel-backfill `'__legacy_v8__'` for v8 rows in a single transaction).

**27 Codex adversarial-review rounds** total across all four branches (017A: 6, 017B: 9, 018: 4, 019: 8). Cumulative findings: ~7 P1, ~45 P2, 1 documented FP — all resolved or explicitly rejected with rationale. Round-27b (the final review) returned **0 P1**; only P2/P3 — diminishing-returns territory.

**Test count**: 161/161 passing on `019-workflow-integrity-hardening`. `flutter analyze` clean.

**Direction**: stop reviewing pre-ship; let the operator field-test. The cycle of "one more review will catch it" hits real diminishing returns past round-27b. The actual ship-gate is the 21-step Windows acceptance in `RELEASE_NOTES_v2.5.0.md` (13 baseline from 017 + 8 019-specific), not Codex round 28. Issues found in the field bundle into v2.5.1.

**Merge sequence** (documented in RELEASE_NOTES_v2.5.0.md "Pre-release"):
```
main ← 017-executor-correctness ← 017-ux-restructuring ← 018-pre-tag-hardening ← 019-workflow-integrity-hardening
                                                                                    ↓
                                                                               tag v2.5.0-pre
                                                                                    ↓
                                                                          operator runs 21-step acceptance
                                                                                    ↓
                                                                               tag v2.5.0 (promote)
```

> **QA status**: Operator-run on the Windows workstation; no autonomous gate beyond the green CI build. Update prompt is gated by Constitution Principle VI — never silent.

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
- **`.live` marker write in `transferFile` is load-bearing (`lib/services/transfer_service.dart`)** — every staging dir gets a `.live` file with `host=${Platform.localHostname}` + `pid` + `exe` immediately after creation. `host` is the load-bearing field (Codex round-25); `pid`+`exe` are diagnostic-only after the round-25 redesign. If the marker write fails, the transfer aborts with the original error preserved (inner try/catch on cleanup so a delete failure doesn't mask the marker-write failure; `Error.throwWithStackTrace` keeps the original stack). The cold-start sweep in `lib/services/startup_sweep.dart` deletes every same-host marker (orphan by definition — InstanceLock + sweep-runs-first invariant) and silently preserves foreign-host markers (cross-machine NAS safety). `staging_dir_sweep_test.dart` case 3 pins the foreign-host preservation; cases 1+2 pin the same-host removal.

- **Sweep depends on InstanceLock + sweep-runs-first (`lib/main.dart`)** — `sweepOrphanedStagingDirs` runs immediately after `recoverStaleJobs` and BEFORE `JobQueueService` construction. Two upstream invariants make the simplified host-only liveness check safe: (1) `InstanceLock` (`lib/utils/instance_lock.dart`) guarantees at most one Copiatorul3000 process per machine, AND (2) sweep is the first code path that touches `.tmp_robocopy_*` directories on cold start — no new markers are written until `JobQueueService` exists. Reordering startup so the sweep fires AFTER another process could have written markers, OR removing the InstanceLock, would re-open the false-positive deletion bugs Codex round-25 closed.

### v9 (019) Load-Bearing Conventions

Feature 019 was the holistic threat-model audit pass. Triggered by the operator's question after 018 ("what next to make sure we have done everything we could to make this bulletproof"); satisfied by parallel Opus + Codex audits each running the same 5-tier framework (source data loss / destination corruption / subprocess attack surface / state-counter correctness / operational resilience). 5 convergent findings (3 P1 + 2 P2) closed; 3 cheap defenses bundled. Schema bumped v8→v9: one new column `Job.sourceDriveSerial`, sentinel-backfilled for v8 rows.

- **`Job.sourceDriveSerial` is fail-closed at create AND re-checked at transfer-resume (`lib/services/job_queue_service.dart::createBatchTransferJobs` + `_processJob` + `lib/ui/screens/create_job_screen.dart`)** — captured via `DriveService.getDriveIdentity` for every transfer / transferAndCompress job at creation; null OR empty serial REFUSES the job (single-card path) or reports `identityRefused` separately from `skipped` (batch path, Codex round-27b P2 #3). At transfer-resume, the executor re-checks via 5-branch logic: (a) sentinel `'__legacy_v8__'` → bypass with one-time-per-launch operator-visible banner via `QueueStateNotifier.operatorMessages`, (b) null on transfer-type job → bug indicator, pause, (c) real serial + current null → fail-closed pause "could not verify card identity", (d) real serial + current differs → pause with mismatch banner, (e) match → proceed. Without this rule, null could ambiguously mean "legacy v8 bypass" OR "v9 capture failed" — the round-27a backdoor that the migration sentinel only closes if v9 capture is itself fail-closed. `drive_identity_check_test.dart` (5 cases).
- **Erase-eligibility rescans card content; refuses on unplanned files (`lib/ui/widgets/erase_drive_action.dart::unplannedFilesRefusalMessage`)** — `@visibleForTesting` pure function compares the planned source set against a fresh card scan via case-insensitive `p.canonicalize` + `toLowerCase`. Closes F-2 (operator queues batch, camera flushes one more clip 30s later, batch runs, operator clicks Erase — that new clip would be destroyed by an eligibility check that only verified PLANNED files). Diff is one-way: card-superset triggers refusal, card-subset does not (operator-driven deletion is permitted). Sample truncates at 5 with `...` ellipsis. `erase_rescan_test.dart` (6 cases).
- **Source-side enumeration uses `followLinks: false` + per-entry `FileSystemEntity.type` check (`lib/services/drive_service.dart::listVideoFiles` + `prepTestCards` + `lib/services/job_queue_service.dart::createBatchTransferJobs`)** — mirrors the 017B dest-side hardening to the source side. Closes F-3: a junction at source pointing into the destination tree creates an enumeration cycle; a symlink to an unrelated path silently expands the planned set outside the SD card. Symlinks/junctions are SKIPPED + logged; cycles complete in bounded time. `source_symlink_guard_test.dart` (3 cases).
- **`clearForceDestDeleteApproved` happens AFTER `markFileCompleted(verified: false)`, NOT at top of iteration (`lib/services/job_queue_service.dart::_processTransfer`)** — closes F-4: top-of-loop clear would race with operator-driven Retry banner clicks landing AFTER the iteration started but BEFORE robocopy returned. The clear must follow the post-copy state write so single-use semantics fire only after the executor has actually consumed the approval. Mirrored in BOTH SHA-256 and size-mode paths. Recovery branch ALSO clears stale `forceDestDeleteApproved` on every rescued file (Codex round-27b P3 #5) so a crash-survived flag can't fire implicitly on next launch — Constitution Principle I requires a fresh operator click. `force_delete_deferred_clear_test.dart` (4 cases).
- **HandBrake compression uses staging-dir convention symmetric with transfer pipeline (`lib/services/compression_service.dart::compressFile`)** — writes into `<dirname>/.tmp_handbrake_copiatorul3000_<tag>/`, then `File.rename` to the final path on success. `.live` marker with `host=${Platform.localHostname}` + `pid` + `exe`; rename wrapped in try/catch with cleanup on failure; the more-specific prefix narrows sweep false-positive surface vs. a bare `.tmp_handbrake_*` matcher. `startup_sweep` matcher accepts BOTH `.tmp_robocopy_*` AND `.tmp_handbrake_copiatorul3000_*`, AND walks recursively (Codex round-27b P2 #4) so nested staging dirs under the compression hierarchy are discoverable — `<root>/<sub>/.tmp_handbrake_*/` would otherwise be missed. `handbrake_staging_test.dart` (4 cases).
- **Slack `_getWebhookUrl()` runs INSIDE `_send`'s try block (`lib/services/slack_service.dart`)** — settings-load failures in the Slack helper must NOT propagate to the main pipeline (Constitution Principle V — observability never blocks data path). Previously thrown above the try block. `slack_settings_failure_test.dart` (1 case) verifies SettingsDao throw on getSettings is swallowed by every notify call.
- **SHA-256 hashing prepends `\\?\` for paths > 240 chars (`lib/services/transfer_service.dart::longPathPrefixed`)** — `@visibleForTesting` top-level helper. PowerShell 5.1 + `Get-FileHash -LiteralPath` requires the long-path prefix above the Windows MAX_PATH boundary. Threshold is 240 (not 260) for headroom on the suffix added by hash output formatting. `long_path_hash_test.dart` (4 cases) pins the script-shape transformation.
- **`drive_service::_runPowerShell` enforces length-3 argv via runtime guard, not assert (`lib/services/drive_service.dart`)** — `if (...) throw StateError(...)` because `flutter build windows --release` strips Dart asserts. Extracted as `@visibleForTesting static void checkPsArgvShape(args, tag)` so the regression test can call it directly without a real PowerShell subprocess. CI grep guard added to `.github/workflows/build.yml` (Codex round-27b P3 #6) — `! grep -rn '\$args\[' lib/` fails the build on any reintroduction of the v2.4.0 PowerShell cascade pattern. `runpowershell_argv_guard_test.dart` (5 cases).
- **`createBatchTransferJobs` return shape carries `identityRefused` distinctly from `skipped` (`lib/services/job_queue_service.dart`)** — Codex round-27b P2 #3. Operator UI surfaces "refused N cards (could not read serial — re-insert and retry)" separately from "skipped N empty cards" so they know whether to re-insert (capture failed) or accept (truly empty). Consumers must destructure the new fields: `({int created, int skipped, int identityRefused, List<String> identityRefusedPaths, List<String> conflicts})`.
- **`recoverStaleJobs` clears stale `forceDestDeleteApproved` on every rescued file (`lib/database/daos/job_dao.dart`)** — Codex round-27b P3 #5. The flag is operator-attribution (set by an explicit "Retry" click from the verify-mismatch banner) with single-use semantics; if the app crashed AFTER arming but BEFORE consumption, the flag would fire implicitly on next launch. The clear is inside the recovery transaction alongside the inProgress→pending file resets.

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

Deferred to v2.5.1 (single-auditor-only findings from 019 audit; not load-bearing for the bytes-on-disk contract):
- **F-D1** (Codex-only, P3): size-mode TOCTOU between robocopy success and `verifyTransfer` size read — the destination could be modified by an external process in the gap. Probability is vanishingly low (operator's own machine, dest path freshly created), and the SHA-256 path is already TOCTOU-immune. Bundle when the next feature touches `_processTransfer`.
- **F-D3** (Opus-only, P3): startup_sweep prefix collision — an unrelated tool that creates `.tmp_robocopy_*` directories in the same destination root would have those dirs deleted (foreign-host marker would save them, but absent-marker would not). Mitigated by the more-specific `.tmp_handbrake_copiatorul3000_*` prefix; the bare `.tmp_robocopy_*` matcher is kept for backwards compat with 018-era staging dirs. Tighten when 018 staging dirs are guaranteed to have aged out.
- **F-D4** (Codex-only, P3): cross-machine NAS write race — two operators on different machines targeting the same NAS root could both write `.live` markers in the same staging dir name (microsecond tag collision is astronomically unlikely but theoretically possible). The host check on read is the load-bearing primitive; collision-by-tag would require a v2.5.1 UUID upgrade to the staging tag.
- **F-D5** (Opus-only, P3): DST/clock-jump mtime cutoff — `Job.createdAt` baseline TOCTOU guard could mis-classify a foreign intrusion as own-partial if the clock jumps backward (DST end, NTP correction). The window is small (1h DST shift); operator-visible attack surface is essentially zero on a single-operator workstation.
- **F-D8** (Codex-only, P3): `eraseDrive` `Remove-Item -LiteralPath` already migrated to inline-script pattern in 017A. The remaining concern was a hypothetical DCIM subdirectory with embedded special chars surviving the erase — re-verify after the 019 source-side symlink guard if a real case appears in the field.

Deferred to v3.0:
- Selective file copy (PM-10) — operator can't pick a subset of files to transfer; entire DCIM tree is enumerated. Multi-camera shoots where a subset is unusable would benefit.

### Review & Quality Process

- **Codex plugin installed** (`openai/codex-plugin-cc`) — enables `/codex:adversarial-review` and `/codex:rescue` for GPT-powered code reviews
- **Adversarial review pattern**: after implementing a feature, run a review before merging. Has caught command injection, data loss bugs, and Constitution violations.
- **Known false positives**: QA-5 (dropdown param correct in Flutter 3.41.9), QA-7 (Dart event loop makes race guard correct)

#### Codex Adversarial-Review Cadence (validated in 015 + 016, refined through v2.5.0)

The pattern that worked across this session for data-safety-critical features:

- Default flags: `--model gpt-5.5 --effort high`. (`gpt-5.5-codex` is rejected by the operator's account; bare `gpt-5.5` works. Use `--effort xhigh` for data-loss-CRITICAL passes.)
- Cadence per feature: **plan v1 → Codex review → plan v2 → Codex review → implementation → Codex review → fix → Codex review → commit**. Two review rounds at each of "plan" and "implementation" is typical for non-trivial work; trivial features can do one of each.
- The reviewer can disagree on framing (e.g. v1 015 plan claimed WAL mode — wrong, it's rollback-journal). Treat factual rebuttals as load-bearing: replace the rationale, don't paper over it.
- The reviewer's CANNOT VERIFY findings still require investigation; they may be wrong, but they're rarely worthless. Resolve them by reading the code, not by handwaving.
- If the reviewer flags 9 findings, applying 8 of them with explicit pushback on the 9th is normal and good. Track which were rejected and why so future sessions don't relitigate.

#### Stop conditions — when reviewing more is the wrong move (lesson from v2.5.0)

The v2.5.0 cycle taught us a hard lesson: incremental adversarial reviews hit diminishing returns past a certain point, and chasing "one more review" is a trap that delays operator field-testing without producing better code.

- **Stop when the P1 trajectory collapses.** When two consecutive rounds return zero P1 (round-27b on 019 was the explicit example), additional same-framing rounds will mostly produce P3-grade nits. Going from 27 to 28 to 29 rounds doesn't catch the next class of bug — a different lens does.
- **Holistic > incremental for workflow-level invariants.** 25 incremental review rounds on 017A + 017B + 018 missed the 5 workflow-level F-1 through F-5 findings that 019's holistic threat-model audit caught in one pass. If incremental rounds are returning P3-only, the next high-value move is a different framing (e.g. a 5-tier threat-model audit covering the whole codebase, parallel-agent same-prompt convergence) — not another round of the same.
- **Real-world is the load-bearing gate, not review #N+1.** Past the diminishing-returns point, the bug class that matters is "what real Windows operator workflow with real bytes on disk will surface that no review framework predicted." Ship to operator (via `-pre` tag), let them run the 21-step acceptance, fold what they find into v2.5.1.
- **The cycle warning sign**: when you find yourself saying "we're 1 review away from solid" for the third time on the same release, that's not the truth — that's the cycle. Ship the `-pre` tag instead.

### Roadmap

- **v2.5.0 (in flight, awaiting operator acceptance)**: workflow-integrity hardening (017A + 017B + 018 + 019 bundle). NAS upload was originally planned for this slot but slipped — the operator's 2026-05-08 Windows test failure triggered a data-safety pass that consumed the release.
- **v2.5.1 (post-operator-acceptance)**: anything the operator finds during the 21-step Windows acceptance. Plus the 5 explicitly-deferred 019 P3 findings (F-D1 size-mode TOCTOU, F-D3 sweep prefix collision, F-D4 cross-machine NAS write race, F-D5 DST/clock-jump mtime, F-D8 eraseDrive Remove-Item -LiteralPath re-verify) — each documented in "Open Bugs → Deferred to v2.5.1".
- **v2.6.0 (next feature release)**: NAS upload automation. Ships its own "Disconnect & wipe local cache" destructive action; bundle `ConfirmationDialog.showCritical` consolidation for the SD-erase path at the same time so both routes go through the canonical primitive.
  - Convention going forward: any new destructive action defaults to `ConfirmationDialog.showCritical`. Bespoke gates require a written reason.
- **v3.0 (from PM review)**:
  - **Tier 1**: auto-detect SD cards (replace polling), dashboard stats, ~~SHA-256 verification~~ (done in 011), ~~NAS upload~~ (now v2.6.0).
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
- `RELEASE_NOTES_v2.5.0.md` — full operator-facing changelog + 21-step Windows acceptance + merge sequence
- `OPERATOR_QA_v2.5.0.md` — focused 4-tier acceptance checklist extracted for the operator's actual workstation use (Pre-flight → Smoke → 161 GB run → UI → optional negative tests). Uses checkbox markdown so progress can be tracked.
- `specs/019-workflow-integrity-hardening/` — most recent feature spec, plan, tasks, holistic-audit framework
- `specs/018-pre-tag-hardening/plan.md` — pre-tag concurrency / atomicity invariants
- `specs/006-review-findings/review-report-v2.md` — historical review (30 issues + roadmap, all closed)
- `specs/001-video-pipeline-automation/spec.md` — original feature spec
- `specs/001-video-pipeline-automation/plan.md` — original architecture plan

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan at
specs/019-workflow-integrity-hardening/plan.md
<!-- SPECKIT END -->
