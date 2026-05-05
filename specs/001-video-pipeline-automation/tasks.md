# Tasks: Video Pipeline Automation

**Input**: Design documents from `specs/001-video-pipeline-automation/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in spec. Tests are NOT included.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, dependencies, tooling

- [X] T001 Initialize Flutter project with `flutter create --platforms=windows video_pipeline` and configure pubspec.yaml with dependencies (win32, drift, sqflite_common_ffi, dio, build_runner, drift_dev)
- [X] T002 Create project folder structure per plan: lib/database/, lib/services/, lib/ui/screens/, lib/ui/widgets/, lib/ui/theme/, lib/utils/
- [X] T003 [P] Configure GitHub Actions workflow for Windows build in .github/workflows/build.yml
- [X] T004 [P] Create app constants and configuration in lib/utils/constants.dart (file extensions, app version, default paths)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Define Drift database tables (Job, JobFile, FavoritePath, AppSettings) in lib/database/tables.dart
- [X] T006 Create Drift database class with migrations in lib/database/database.dart
- [X] T007 Run `dart run build_runner build` to generate Drift code
- [X] T008 [P] Create JobDao with CRUD operations and reactive `.watch()` queries in lib/database/daos/job_dao.dart
- [X] T009 [P] Create JobFileDao with per-job file queries and status updates in lib/database/daos/job_file_dao.dart
- [X] T010 [P] Create FavoritePathDao with CRUD and last-used tracking in lib/database/daos/favorite_path_dao.dart
- [X] T011 [P] Create SettingsDao for singleton app settings in lib/database/daos/settings_dao.dart
- [X] T012 Implement JobQueueService (queue processing logic, sequential execution, auto-chain trigger) in lib/services/job_queue_service.dart
- [X] T013 [P] Implement SlackService (HTTP POST to webhook, message formatting, best-effort delivery) in lib/services/slack_service.dart
- [X] T014 [P] Create app theme and base styling in lib/ui/theme/app_theme.dart
- [X] T015 [P] Create reusable confirmation dialog widget (human-in-the-loop) in lib/ui/widgets/confirmation_dialog.dart
- [X] T016 Set up MaterialApp with routing and database initialization in lib/app.dart and lib/main.dart

**Checkpoint**: Foundation ready — database, queue service, and base UI infrastructure operational. User story implementation can begin.

---

## Phase 3: User Story 1 — Job Queue and Transfer (Priority: P1) MVP

**Goal**: User can detect SD cards, create transfer jobs with configurable settings (source, destination, auto-chain), queue them, and process them with resumable file transfer and real-time progress.

**Independent Test**: Insert an SD card, create a transfer job, start it, verify files arrive at destination with correct sizes. Interrupt and resume. Receive Slack notification on completion.

### Implementation for User Story 1

- [X] T017 [US1] Implement DriveService (detect removable drives via win32 GetLogicalDrives/GetDriveType, list with name/path/size) in lib/services/drive_service.dart
- [X] T018 [US1] Implement robocopy output parser (exit code handling, file completion detection) in lib/utils/robocopy_parser.dart
- [X] T019 [US1] Implement TransferService (spawn robocopy /Z, stream stdout, update JobFile status per-file, poll destination size for intra-file progress) in lib/services/transfer_service.dart
- [X] T020 [US1] Wire TransferService into JobQueueService (start transfer jobs, update Job status, trigger Slack on complete/fail) in lib/services/job_queue_service.dart
- [X] T021 [P] [US1] Create DriveList widget (displays detected removable drives with name, path, capacity) in lib/ui/widgets/drive_list.dart
- [X] T022 [P] [US1] Create JobCard widget (shows job status, progress bar, file count, source/destination) in lib/ui/widgets/job_card.dart
- [X] T023 [P] [US1] Create ProgressBar widget (real-time transfer progress, file count, current file name) in lib/ui/widgets/progress_bar.dart
- [X] T024 [US1] Create HomeScreen (job queue list view, start/pause controls, reactive via Drift .watch()) in lib/ui/screens/home_screen.dart
- [X] T025 [US1] Create CreateJobScreen (source drive picker, destination folder picker with favorites, auto-chain toggle, preset selector) in lib/ui/screens/create_job_screen.dart
- [X] T026 [US1] Create JobDetailScreen (per-job progress, file list with individual status, error display) in lib/ui/screens/job_detail_screen.dart
- [X] T027 [US1] Implement favorite path save/load in CreateJobScreen (save button next to folder picker, dropdown of saved favorites) in lib/ui/screens/create_job_screen.dart

**Checkpoint**: User Story 1 fully functional. User can detect drives, create transfer jobs, process queue, see progress, and get Slack notifications. This is the MVP.

---

## Phase 4: User Story 2 — Compress Transferred Files (Priority: P2)

**Goal**: User can create standalone compression jobs or auto-chain from transfer. Each job specifies input files, preset (from HandBrake), and output location. Real-time per-file progress with percentage and ETA.

**Independent Test**: Point app at a folder of video files, select a preset from dropdown, choose output location, start compression, verify output files are produced. Receive Slack notification.

### Implementation for User Story 2

- [ ] T028 [US2] Implement HandBrake progress parser (regex for percentage, FPS, ETA from stdout) in lib/utils/handbrake_parser.dart
- [ ] T029 [US2] Implement CompressionService (read presets from %APPDATA%\HandBrake\presets.json, spawn HandBrakeCLI with --preset, stream progress, update JobFile status) in lib/services/compression_service.dart
- [ ] T030 [US2] Wire CompressionService into JobQueueService (process compression jobs, handle auto-chain creation from completed transfer jobs, trigger Slack) in lib/services/job_queue_service.dart
- [ ] T031 [US2] Update CreateJobScreen to support compression-only job creation (input folder, preset dropdown, output location picker with favorites) in lib/ui/screens/create_job_screen.dart
- [ ] T032 [US2] Update JobDetailScreen to show compression-specific progress (percentage, current file, FPS, ETA) in lib/ui/screens/job_detail_screen.dart

**Checkpoint**: User Stories 1 AND 2 both work independently. Transfer and compression can run as separate jobs or chained.

---

## Phase 5: User Story 3 — Erase SD Cards After Validation (Priority: P3)

**Goal**: After a successful transfer, user can erase SD cards via a button in the app. Requires explicit confirmation dialog (human-in-the-loop).

**Independent Test**: Complete a transfer, verify the erase button appears, click it, confirm in dialog, verify SD card is empty.

### Implementation for User Story 3

- [ ] T033 [US3] Implement SD card erase logic (format drive via win32 or diskpart subprocess) in lib/services/drive_service.dart
- [ ] T034 [US3] Add "Erase SD Cards" button to JobDetailScreen (visible only after verified transfer, triggers confirmation dialog) in lib/ui/screens/job_detail_screen.dart
- [ ] T035 [US3] Wire erase flow: button → confirmation_dialog → DriveService.erase() → success message in lib/ui/screens/job_detail_screen.dart

**Checkpoint**: All user stories independently functional. Full pipeline operational.

---

## Phase 6: User Story 4 — Monitor Pipeline via Slack (Priority: P2)

**Goal**: Slack notifications at every phase transition with actionable detail.

**Independent Test**: Trigger any pipeline phase, verify Slack message arrives in correct channel with expected format.

### Implementation for User Story 4

- [ ] T036 [US4] Implement all Slack message formats per contracts/slack-notification.md (transfer start/complete/fail, compression start/complete/fail) in lib/services/slack_service.dart
- [ ] T037 [US4] Create SettingsScreen (Slack webhook URL input, test notification button, update preferences) in lib/ui/screens/settings_screen.dart
- [ ] T038 [US4] Wire Slack calls into JobQueueService at all phase transitions (job start, file complete, job complete, job fail) in lib/services/job_queue_service.dart

**Checkpoint**: All notifications flow to Slack. Team can monitor pipeline remotely.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: App updates, refinements, deployment readiness

- [ ] T039 Implement UpdateService (check GitHub Releases API via dio, compare versions, show prompted update dialog) in lib/services/update_service.dart
- [ ] T040 Wire UpdateService into app startup (check on launch, show dialog if new version available, never auto-update) in lib/main.dart
- [ ] T041 Add USB hot-plug monitoring via device_manager package (detect card insertion/removal while app is running, refresh drive list) in lib/services/drive_service.dart
- [ ] T042 Add error handling for edge cases: SD card removed mid-transfer, HDD full, HDD disconnected, HandBrake not installed, no presets found, Slack unreachable in lib/services/job_queue_service.dart
- [ ] T043 Finalize GitHub Actions workflow: build Windows .exe, create release, attach asset on tag push in .github/workflows/build.yml

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational — this is the MVP
- **User Story 2 (Phase 4)**: Depends on Foundational; can run after or in parallel with US1 (different services/files)
- **User Story 4 (Phase 6)**: Depends on Foundational; SlackService is created in Phase 2, messages defined here
- **User Story 3 (Phase 5)**: Depends on US1 (needs completed transfer to enable erase)
- **Polish (Phase 7)**: Depends on all user stories being complete

### Within Each User Story

- Parsers/utils before services
- Services before UI
- Core implementation before integration with queue

### Parallel Opportunities

- T003, T004 (Setup): independent files
- T008, T009, T010, T011 (DAOs): independent files
- T013, T014, T015 (Slack, theme, dialog): independent files
- T021, T022, T023 (US1 widgets): independent files
- User Stories 1, 2, and 4 can theoretically run in parallel after Foundational (different services)

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL — blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test transfer pipeline end-to-end
5. Deploy to video team for feedback

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add User Story 1 → MVP (transfer works!)
3. Add User Story 2 → Compression works
4. Add User Story 4 → Slack notifications active
5. Add User Story 3 → SD card erase available
6. Polish → Auto-update, edge case handling, CI/CD

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
