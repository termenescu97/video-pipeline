# Implementation Plan: High-Priority Product Gaps

**Branch**: `009-product-gaps` | **Date**: 2026-05-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/009-product-gaps/spec.md`

## Summary

Close 6 high-priority product/UX gaps: wire real-time progress data (speed, ETA, filename) to the progress bar widget, add persistent local logging, implement single-instance lock, show Slack webhook banner, add first-run onboarding, and fix the GitHub repo placeholder. This is a mix of new features (2 new files) and wiring changes to existing files. Requires a schema migration (v2→v3) for the `firstRunCompleted` column.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (3.41.9)
**Primary Dependencies**: Drift (SQLite ORM), path package, tray_manager, window_manager
**Storage**: SQLite via Drift (schema v2 → v3 for firstRunCompleted column)
**Testing**: Manual testing on Windows 11
**Target Platform**: Windows 11 desktop
**Project Type**: Desktop app
**Constraints**: Single codebase (Constitution II), minimal complexity (Constitution IV)
**Scale/Scope**: 6 product gaps, 2 new files, 11 modified files

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | PASS | Onboarding guides user; banner informs about missing config |
| II. Single Codebase | PASS | All Dart, no new runtimes |
| III. Resilient Pipeline | PASS | Single-instance lock prevents DB corruption; logging aids debugging |
| IV. Minimal Complexity | PASS | ValueNotifier for progress (no state mgmt lib); simple file logger (no logging framework); PID lock file (no Win32 FFI) |
| V. Observable Progress | PASS (fixes violation) | PM-1 wires speed/ETA/filename to the existing progress bar widget |
| VI. Update Transparency | PASS (fixes violation) | QA-15 fixes the repo placeholder so update checks actually work |

## Project Structure

### Documentation (this feature)

```text
specs/009-product-gaps/
├── plan.md              # This file
├── research.md          # Technical decisions
├── spec.md              # Feature specification
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Created by /speckit-tasks
```

### Source Code (files to modify/create)

```text
lib/
├── main.dart                          # PM-2 (init logger), PM-3 (lock check)
├── services/
│   ├── job_queue_service.dart         # PM-1 (progress notifier), PM-2 (log calls)
│   ├── transfer_service.dart          # PM-1 (speed/ETA calculation)
│   ├── compression_service.dart       # PM-1 (filename tracking)
│   ├── slack_service.dart             # PM-2 (log send/fail)
│   └── log_service.dart               # PM-2 (NEW — file logger)
├── database/
│   ├── tables.dart                    # PM-5 (firstRunCompleted column)
│   ├── database.dart                  # PM-5 (schema v3 migration)
│   └── daos/settings_dao.dart         # PM-5 (setFirstRunCompleted method)
├── ui/screens/
│   ├── job_detail_screen.dart         # PM-1 (wire progress to widget)
│   ├── home_screen.dart               # PM-4 (Slack banner), PM-5 (welcome state)
│   └── shell_screen.dart              # PM-3 (release lock in shutdown)
└── utils/
    ├── constants.dart                 # QA-15 (fix repo placeholder)
    └── instance_lock.dart             # PM-3 (NEW — PID lock logic)
```

## Changes by Issue

### PM-1: Progress bar data wiring

**Architecture**:
1. Add `ProgressData` class to `job_queue_service.dart` — holds currentFileName, speedBytesPerSec, eta, fps, elapsed
2. Add `ValueNotifier<ProgressData?>` to `JobQueueService` — set from progress callbacks during transfer/compression
3. In `_processTransfer()`: on each `FileProgressEvent`, calculate speed from elapsed time and file size, update notifier
4. In `_processCompression()`: on each `HandbrakeProgress`, map fps/eta/filename to notifier
5. In `job_detail_screen.dart`: wrap `PipelineProgressBar` in `ValueListenableBuilder`, pass all fields

**Key files**:
- `lib/services/job_queue_service.dart` — add ProgressData class + ValueNotifier + update logic in process methods
- `lib/ui/screens/job_detail_screen.dart` — listen to notifier, pass data to widget

### PM-2: Persistent local log file

**New file**: `lib/services/log_service.dart`
- `LogService` singleton with `info()`, `warning()`, `error()` methods
- Writes to `copiatorul3000.log` next to executable
- Format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] message`
- On init: check size, truncate if >10MB

**Instrumentation points**:
- `main.dart`: log app start/stop
- `job_queue_service.dart`: log job started/completed/failed, file transfer results
- `slack_service.dart`: log notification sent/failed

### PM-3: Single-instance lock

**New file**: `lib/utils/instance_lock.dart`
- `InstanceLock.acquire()` — write PID to lock file, return true if acquired
- `InstanceLock.release()` — delete lock file
- `InstanceLock.isStale()` — check if PID in lock file is still running via `tasklist`

**Integration**:
- `main.dart`: call `acquire()` before `WidgetsFlutterBinding.ensureInitialized()`. If fails, show error and `exit(1)`.
- `shell_screen.dart`: call `release()` in `_gracefulShutdown()` before `exit(0)`.

### PM-4: Slack webhook banner

**File**: `lib/ui/screens/home_screen.dart`
- Add `StreamBuilder<AppSetting?>` wrapping the home screen body
- If settings null or `slackWebhookUrl.isEmpty`, show orange banner at top
- Banner: "Slack notifications disabled — tap to configure"
- `onTap`: navigate to SettingsScreen

### PM-5: First-run onboarding

**Schema change**:
- `tables.dart`: add `BoolColumn get firstRunCompleted => boolean().withDefault(const Constant(false))();`
- `database.dart`: bump `schemaVersion` to 3, add migration `if (from < 3) await m.addColumn(appSettings, appSettings.firstRunCompleted);`
- `settings_dao.dart`: add `setFirstRunCompleted(bool)` method
- Run `dart run build_runner build` to regenerate Drift code

**UI change**:
- `home_screen.dart`: in the empty state block, check `firstRunCompleted`. If false, show welcome state with:
  - App description ("Copiatorul3000 automates video file transfer and compression")
  - "Insert an SD card to start" hint
  - "Configure Slack" button → SettingsScreen
  - "Get Started" button → sets flag, switches to normal empty state

### QA-15: GitHub repo placeholder

**File**: `lib/utils/constants.dart`
**Change**: `'YOUR_ORG/video-pipeline'` → `'termenescu97/video-pipeline'`

## Complexity Tracking

No constitution violations. No complexity tracking needed.
