# Tasks: High-Priority Product Gaps

**Input**: Design documents from `specs/009-product-gaps/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No automated tests — manual testing on Windows 11 per project convention.

**Organization**: Tasks grouped by user story. US5 (onboarding) requires a foundational schema migration phase first.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Foundational — Schema Migration

**Purpose**: Add `firstRunCompleted` column to AppSettings. Must complete before US5 (onboarding) can be implemented. Also regenerates Drift code needed by all subsequent tasks.

- [x] T001 Add `firstRunCompleted` boolean column with default `false` to `AppSettings` table in `lib/database/tables.dart`
- [x] T002 Bump `schemaVersion` to 3 in `lib/database/database.dart` and add migration: `if (from < 3) await m.addColumn(appSettings, appSettings.firstRunCompleted);`
- [x] T003 Add `setFirstRunCompleted(bool)` method to `lib/database/daos/settings_dao.dart` following the existing singleton pattern
- [x] T004 Run `dart run build_runner build` to regenerate Drift code for the new schema

**Checkpoint**: Schema v3 compiles. `flutter analyze` passes. New column available in generated code.

---

## Phase 2: User Story 1 — Progress bar shows speed, ETA, and filename (Priority: P1) 🎯 MVP

**Goal**: Wire real-time progress data from transfer/compression services to the PipelineProgressBar widget.

**Independent Test**: Start a transfer job. Verify the detail screen shows current filename, speed (MB/s), and ETA updating in real time.

### Implementation for User Story 1

- [x] T005 [US1] Add `ProgressData` class to `lib/services/job_queue_service.dart` with fields: `String? currentFileName`, `double? speedBytesPerSec`, `Duration? eta`, `Duration? elapsed`, `double? fps`. Add `ValueNotifier<ProgressData?> progressNotifier` field to `JobQueueService`.
- [x] T006 [US1] Wire transfer progress in `_processTransfer()` in `lib/services/job_queue_service.dart`: subscribe to `transferService.onProgress`, calculate speed from `transferService.fileStartTime` and `transferService.fileTotalBytes` using elapsed time, update `progressNotifier` with filename, speed, and ETA. Clear notifier when file completes.
- [x] T007 [US1] Wire compression progress in `_processCompression()` in `lib/services/job_queue_service.dart`: subscribe to `compressionService.onProgress`, map `HandbrakeProgress.fps`, `HandbrakeProgress.eta` (parse to Duration), and current filename to `progressNotifier`. Clear notifier when file completes.
- [x] T008 [US1] Update `lib/ui/screens/job_detail_screen.dart` to wrap `PipelineProgressBar` in a `ValueListenableBuilder<ProgressData?>` listening to `jobQueueService.progressNotifier`. Pass `currentFileName`, `speedBytesPerSec`, `eta`, `elapsed`, and `fps` from the notifier value to the widget's parameters.

**Checkpoint**: Progress bar shows filename, speed, and ETA during transfers and compressions. Queued jobs show "Waiting."

---

## Phase 3: User Story 2 — Persistent local log file (Priority: P1)

**Goal**: Write timestamped log entries for all significant events to a file next to the executable.

**Independent Test**: Run a transfer job. Open `copiatorul3000.log` next to the .exe. Verify timestamped entries for job start, file transfers, and job completion.

### Implementation for User Story 2

- [x] T009 [P] [US2] Create `lib/services/log_service.dart` — singleton `LogService` class with `info(String message)`, `warning(String message)`, `error(String message)` methods. Writes to `copiatorul3000.log` next to `Platform.resolvedExecutable`. Format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] message`. On `init()`, check file size and truncate to last 5MB if over 10MB.
- [x] T010 [US2] Initialize `LogService` in `lib/main.dart` — call `logService.init()` after `WidgetsFlutterBinding.ensureInitialized()`. Add `late final LogService logService;` global. Log `"App started"` on init and `"App closed"` in graceful shutdown.
- [x] T011 [US2] Add log calls to `lib/services/job_queue_service.dart` — log job started (with type, source, destination), each file transfer result (success/fail with filename), verification results, and job completed/failed.
- [x] T012 [US2] Add log calls to `lib/services/slack_service.dart` — log notification sent (with job ID) and notification failed (with error details).

**Checkpoint**: Log file contains timestamped entries for all significant events. Slack failures are recorded locally.

---

## Phase 4: User Story 3 — Single-instance lock (Priority: P2)

**Goal**: Prevent two app instances from running simultaneously.

**Independent Test**: Launch the app. Launch a second instance. Verify the second shows an error and exits.

### Implementation for User Story 3

- [x] T013 [P] [US3] Create `lib/utils/instance_lock.dart` — `InstanceLock` class with `Future<bool> acquire()` (write PID to `copiatorul3000.lock` next to executable), `Future<void> release()` (delete lock file), and `Future<bool> _isProcessRunning(int pid)` (check via `tasklist /FI "PID eq $pid"` on Windows, always false on non-Windows).
- [x] T014 [US3] Integrate lock in `lib/main.dart` — call `InstanceLock.acquire()` before Flutter init. If returns false, show a native message box (or simple print + exit) explaining another instance is running and `exit(1)`. Add `late final InstanceLock instanceLock;` global.
- [x] T015 [US3] Release lock in `lib/ui/screens/shell_screen.dart` — call `instanceLock.release()` in `_gracefulShutdown()` before `database.close()`.

**Checkpoint**: Second instance shows error and exits. Stale lock files are cleaned up automatically.

---

## Phase 5: User Story 4 — Slack webhook banner (Priority: P2)

**Goal**: Show a persistent banner on the home screen when Slack webhook URL is empty.

**Independent Test**: Clear Slack webhook in settings. Return to home screen. Verify orange banner appears. Configure URL. Verify banner disappears.

### Implementation for User Story 4

- [x] T016 [US4] Add a `StreamBuilder<AppSetting?>` in `lib/ui/screens/home_screen.dart` that watches `settingsDao.watchSettings()`. If settings are null or `slackWebhookUrl` is empty, show an orange banner at the top of the Column (before the Start/Stop row at line 75). Banner text: "Slack notifications disabled — tap to configure." `onTap` navigates to `SettingsScreen`. Banner disappears reactively when webhook is configured.

**Checkpoint**: Banner shows when webhook empty, disappears when configured. Tapping navigates to settings.

---

## Phase 6: User Story 5 — First-run onboarding (Priority: P2)

**Goal**: Show a welcome/guidance state on first launch that explains the app and suggests next steps.

**Independent Test**: Launch with fresh database. Verify welcome state appears. Tap "Get Started." Verify it disappears permanently.

**Depends on**: Phase 1 (schema migration for `firstRunCompleted` column)

### Implementation for User Story 5

- [x] T017 [US5] Replace the empty-state block (lines 45-68) in `lib/ui/screens/home_screen.dart` with a conditional: if `firstRunCompleted` is false (from settings stream), show a welcome state with app description ("Copiatorul3000 automates video file transfer and compression"), "Insert an SD card to start" hint, "Configure Slack" button (→ SettingsScreen), and "Get Started" button (→ sets `firstRunCompleted` to true via `settingsDao.setFirstRunCompleted(true)`). If `firstRunCompleted` is true, show the existing empty state.
- [x] T018 [US5] In `lib/ui/screens/home_screen.dart`, also set `firstRunCompleted` to true when the first job is created (in `_batchCopyAllCards` success path, after jobs are created).

**Checkpoint**: First launch shows welcome. "Get Started" or first job creation dismisses it permanently.

---

## Phase 7: User Story 6 — Correct GitHub repo URL (Priority: P2)

**Goal**: Fix the placeholder so update checks actually work.

**Independent Test**: Launch with update checking enabled. Verify the check queries the correct repository.

### Implementation for User Story 6

- [x] T019 [P] [US6] Change `githubRepo` constant from `'YOUR_ORG/video-pipeline'` to `'termenescu97/video-pipeline'` in `lib/utils/constants.dart`

**Checkpoint**: Update check queries the correct GitHub repo. Prompts appear when updates are available.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Final verification and documentation.

- [x] T020 Run `flutter analyze` to verify zero analysis errors across all modified and new files
- [x] T021 Update known issues and feature table in `CLAUDE.md` to reflect 009 completion

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Foundational)**: Must complete first — schema migration + codegen
- **Phase 2 (US1)**: Depends on Phase 1 (needs regenned Drift code)
- **Phase 3 (US2)**: Independent of other user stories
- **Phase 4 (US3)**: Independent of other user stories
- **Phase 5 (US4)**: Independent (uses existing settings stream)
- **Phase 6 (US5)**: Depends on Phase 1 (needs `firstRunCompleted` column)
- **Phase 7 (US6)**: Independent — one-line change
- **Phase 8 (Polish)**: Depends on all phases complete

### Parallel Opportunities

After Phase 1 completes:
```
Phase 2 (US1: progress wiring) ──┐
Phase 3 (US2: logging)          ──┤
Phase 4 (US3: instance lock)    ──┼──→ Phase 8 (Polish)
Phase 5 (US4: Slack banner)     ──┤
Phase 6 (US5: onboarding)       ──┤
Phase 7 (US6: repo fix)         ──┘
```

Within phases, tasks marked [P] can run in parallel (different files).

---

## Implementation Strategy

### Recommended Sequential Order (Solo Developer)

1. **Phase 1**: Schema migration + codegen (foundational, blocks US1 and US5)
2. **Phase 7**: QA-15 repo fix (one-line, quick win)
3. **Phase 2**: PM-1 progress wiring (P1, highest impact)
4. **Phase 3**: PM-2 logging (P1, new file + instrumentation)
5. **Phase 4**: PM-3 instance lock (P2, new file + main.dart integration)
6. **Phase 5**: PM-4 Slack banner (P2, home_screen.dart)
7. **Phase 6**: PM-5 onboarding (P2, home_screen.dart — do after banner since same file)
8. **Phase 8**: Polish — analyze + docs

### MVP First (User Story 1 Only)

1. Complete Phase 1 (schema migration)
2. Complete Phase 2 (progress wiring)
3. **STOP and VALIDATE**: Verify speed/ETA/filename shows during transfers
4. Proceed to remaining phases

---

## Notes

- 2 new files: `lib/services/log_service.dart`, `lib/utils/instance_lock.dart`
- Schema migration v2→v3 required (run `dart run build_runner build` after table change)
- [P] tasks = different files, no dependencies
- Total: 21 tasks across 8 phases (1 foundational + 6 user stories + 1 polish)
