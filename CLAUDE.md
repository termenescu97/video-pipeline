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
│   ├── widgets/                 # JobCard, DriveList, ProgressBar, ConfirmationDialog
│   └── theme/app_theme.dart     # StatusColors theme extension
└── utils/
    ├── constants.dart           # Video extensions, robocopy flags, regex patterns
    ├── format_utils.dart        # formatBytes, formatDuration, formatSpeed, formatRelativeTime
    ├── error_mapper.dart        # Raw errors → human-friendly messages
    ├── process_runner.dart      # Shared subprocess stdout/stderr streaming
    ├── robocopy_parser.dart     # Parse robocopy output and exit codes
    ├── handbrake_parser.dart    # Parse HandBrakeCLI progress output
    └── instance_lock.dart       # PID-based single-instance lock
```

## Current State (as of 2026-05-06)

### Completed Features (12 spec-kit features)

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

**Latest release**: v2.3.0 (tagged, built via GitHub Actions)
**Total tasks implemented**: 277

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
- Graceful shutdown for both window close and tray quit (awaits queue + 30s safety timeout)
- OS-level instance lock (atomic acquisition via RandomAccessFile.lock, fail-closed)
- Queue ordering matches drag-and-drop display order (sortOrder, then createdAt)

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

None — all known data-safety bugs resolved as of v2.3.0.

### Review & Quality Process

- **Codex plugin installed** (`openai/codex-plugin-cc`) — enables `/codex:adversarial-review` and `/codex:rescue` for GPT-powered code reviews
- **Adversarial review pattern**: after implementing a feature, run a review before merging. Has caught command injection, data loss bugs, and Constitution violations.
- **Known false positives**: QA-5 (dropdown param correct in Flutter 3.41.9), QA-7 (Dart event loop makes race guard correct)

### v3.0 Roadmap (from PM review)

**Tier 1**: NAS upload automation, auto-detect SD cards, dashboard stats, ~~SHA-256 verification~~ (done in 011)
**Tier 2**: Job templates, scheduled jobs, multi-machine sync, selective file copy
**Tier 3**: Cloud backup, metadata extraction, team activity feed

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
specs/013-data-safety-hardening/plan.md
<!-- SPECKIT END -->
