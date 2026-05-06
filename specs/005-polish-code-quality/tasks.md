# Tasks: Polish & Code Quality

**Input**: Design documents from `specs/005-polish-code-quality/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: Not requested.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [ ] T001 Add `tray_manager` dependency to pubspec.yaml and run `flutter pub get`
- [ ] T002 [P] Create lib/database/extensions.dart — add `extension JobTypeX on JobType { String get label }` and `extension JobStatusX on JobStatus { String get label; Color get color }` with all switch cases
- [ ] T003 [P] Create lib/utils/process_runner.dart — shared utility that starts a process, streams stdout/stderr through SystemEncoding decoder, splits by newline, calls a parser callback per line, returns exit code
- [ ] T004 [P] Add `StatusColors` ThemeExtension to lib/ui/theme/app_theme.dart — define semantic colors: success (green), error (red), warning (orange), active (blue), pending (grey). Register in both light and dark themes
- [ ] T005 Add `watchJob(int jobId)` method to lib/database/daos/job_dao.dart — `(select(jobs)..where((t) => t.id.equals(jobId))).watchSingleOrNull()`

---

## Phase 2: User Story 1 — Code Deduplication (Priority: P1)

- [ ] T006 [US1] Update lib/services/transfer_service.dart to use ProcessRunner utility instead of inline process streaming boilerplate
- [ ] T007 [US1] Update lib/services/compression_service.dart to use ProcessRunner utility instead of inline process streaming boilerplate
- [ ] T008 [US1] Update lib/ui/screens/job_detail_screen.dart — replace inline _jobTypeLabel/_statusLabel with extensions from lib/database/extensions.dart, replace inline file size formatting with formatBytes(), use watchJob(id) instead of watchAllJobs().map()
- [ ] T009 [US1] Update lib/ui/widgets/job_card.dart — replace inline _jobTitle with job.type.label, replace inline status switch with job.status.label/job.status.color from extensions
- [ ] T010 [US1] Update lib/services/slack_service.dart — replace inline file size calculations with formatBytes()
- [ ] T011 [US1] Update lib/services/job_queue_service.dart `createBatchTransferJobs()` — replace hardcoded ['.mov', '.mp4'] with videoExtensions constant from constants.dart
- [ ] T012 [US1] Update lib/services/drive_service.dart — replace inline file size formatting in DetectedDrive.displaySize with formatBytes()

**Checkpoint**: Zero duplicated logic. All formatting/labels/colors from shared sources.

---

## Phase 3: User Story 4 — Security & Stability (Priority: P1)

- [ ] T013 [US4] Add drive path validation in lib/services/drive_service.dart `eraseDrive()` — check path matches `RegExp(r'^[A-Z]:\\$')` before executing PowerShell command. Return false and log if invalid
- [ ] T014 [US4] Wrap `_checkForUpdates()` body in lib/app.dart with try-catch that silently handles all errors
- [ ] T015 [US4] Update lib/ui/screens/settings_screen.dart — replace `onChanged` with debounced save using Timer (500ms delay after last keystroke). Cancel timer on dispose
- [ ] T016 [US4] Update lib/ui/screens/job_detail_screen.dart — use `jobDao.watchJob(widget.jobId)` instead of `jobDao.watchAllJobs().map(...)`

**Checkpoint**: No injection risk, no startup crash, efficient queries, no keystroke-level DB writes.

---

## Phase 4: User Story 3 — Visual Polish (Priority: P2)

- [ ] T017 [US3] Update lib/ui/screens/create_job_screen.dart — rename "Both" SegmentedButton label to "Copy & Compress"
- [ ] T018 [US3] Update all screens and widgets to use StatusColors from theme extension instead of hardcoded Colors.red/green/orange/blue/grey for status indicators
- [ ] T019 [US3] Remove FloatingActionButton from lib/ui/screens/shell_screen.dart (New Job is already in the left panel toolbar)
- [ ] T020 [US3] Update lib/ui/screens/home_screen.dart — change first-job snackbar message to "Job added to queue. Press Start to begin processing"
- [ ] T021 [US3] Update lib/ui/screens/create_job_screen.dart `_refreshDrives()` — after refresh, show snackbar "Found X drives" or "No removable drives found"

**Checkpoint**: Consistent visuals, clear terminology, no FAB.

---

## Phase 5: User Story 2 — Desktop Power User (Priority: P2)

- [ ] T022 [US2] Add keyboard shortcuts to lib/ui/screens/shell_screen.dart using Shortcuts + Actions widgets: Ctrl+N → create job, Ctrl+Enter → start/stop queue, Delete → remove selected job
- [ ] T023 [US2] Add right-click context menu to lib/ui/widgets/job_card.dart using GestureDetector.onSecondaryTapDown + showMenu() — options: View Details, Delete, Retry (if failed)
- [ ] T024 [US2] Replace ListView in lib/ui/screens/home_screen.dart active jobs section with ReorderableListView — onReorder updates job queue order in database
- [ ] T025 [US2] Add sort_order column to Jobs table in lib/database/tables.dart for queue ordering
- [ ] T026 [US2] Initialize system tray in lib/ui/screens/shell_screen.dart using tray_manager — show app icon, tooltip with queue status, tray menu with Show/Quit
- [ ] T027 [US2] Update system tray tooltip during queue processing with current job progress

**Checkpoint**: Full desktop UX — keyboard, right-click, drag-reorder, system tray.

---

## Phase 6: Polish

- [ ] T028 Regenerate Drift code with `dart run build_runner build` (if sort_order column added)
- [ ] T029 Run `flutter analyze` and fix any issues

---

## Dependencies & Execution Order

- Phase 1 (Setup): No dependencies
- Phase 2 (Dedup): Depends on Phase 1 (extensions, ProcessRunner)
- Phase 3 (Security): Depends on Phase 1 (watchJob)
- Phase 4 (Visual): Depends on Phase 1 (StatusColors theme)
- Phase 5 (Desktop): Depends on Phase 1 (tray_manager); T025 must come before T024
- Phase 6: After everything

**Total**: 29 tasks across 6 phases
