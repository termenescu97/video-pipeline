# Tasks: Data Safety & Reliability Hardening

**Input**: Design documents from `specs/013-data-safety-hardening/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story. The mapping from plan phases to user stories is:
- US1 (Safe Batch Copy) ← Plan C1, C3
- US2 (Destination File Protection) ← Plan C2
- US3 (Crash Recovery) ← Plan B1
- US4 (Transactional Creation) ← Plan B2
- US5 (SD Erase Safety) ← Plan D1, D2
- US6 (Subprocess Management) ← Plan A1, E1
- US7 (Single-Instance Safety) ← Plan A2
- US8 (Queue Ordering) ← Plan B3
- US9 (Compression Paths) ← Plan C3 (shared with US1)
- US10 (PowerShell Integration) ← Plan A3
- US11 (Version Metadata) ← Plan A4
- Shutdown (US6 acceptance 3-4) ← Plan E2

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Foundation Fixes (no UI changes)

**Purpose**: Isolated infrastructure fixes that unblock later phases. Four file groups can run in parallel; tasks within each group are sequential (same file).

**Group A** — `lib/utils/process_runner.dart` (1 task):
- [x] T001 [P] [US6] Fix ProcessRunner to always drain stdout and stderr streams in `lib/utils/process_runner.dart` — replace `Future<void>.value()` with `process.stdout.drain()` / `process.stderr.drain()` when no callback is provided (lines 17-31)

**Group B** — `lib/utils/instance_lock.dart` (6 tasks, sequential — same file):
- [x] T002 [US7] Move lock file path to `getApplicationSupportDirectory()` in `lib/utils/instance_lock.dart` — executable directory may be read-only (e.g., `C:\Program Files\`)
- [x] T003 [US7] Fix instance lock PID write in `lib/utils/instance_lock.dart` — import `dart:io` and write `'$pid'` using the global `pid` property instead of undefined variable (line 29)
- [x] T004 [US7] Fix instance lock to fail closed in `lib/utils/instance_lock.dart` — change `catch (_) { return true; }` to `catch (_) { return false; }` so lock acquisition failure prevents app startup (line 31)
- [x] T005 [US7] Implement atomic lock acquisition in `lib/utils/instance_lock.dart` — write PID to temp file `copiatorul3000.lock.tmp` then rename to `copiatorul3000.lock` (rename is atomic on Windows and POSIX)
- [x] T006 [US7] Add stale lock recovery in `lib/utils/instance_lock.dart` — if lock file exists and PID is not running (via `tasklist`), delete stale lock and re-acquire. If PID check fails, treat lock as held (fail closed)
- [x] T007 [US7] Add second-instance error dialog in `lib/main.dart` — when `instanceLock.acquire()` returns false, show a blocking `AlertDialog` with message "Another instance of Copiatorul3000 is already running" and an "Exit" button that calls `exit(1)`. Replace the current `stderr.writeln` + `exit(1)` with the dialog (requires `WidgetsFlutterBinding.ensureInitialized()` before lock acquisition)

**Group C** — `lib/services/drive_service.dart` (5 tasks, sequential — same file, T008-T011 depend on T0007b):
- [x] T008 [US10] Add `_runPowerShell(List<String> args)` helper method in `lib/services/drive_service.dart` — wraps `Process.run('powershell', ...)` in try/catch, returns `ProcessResult?` (null on failure)
- [x] T009 [US10] Refactor `_getWindowsDrives()` in `lib/services/drive_service.dart` to use `_runPowerShell()` helper — return empty list on null result (existing "no drives detected" UI handles this)
- [x] T010 [US10] Refactor `getDiskFreeSpace()` in `lib/services/drive_service.dart` to use `_runPowerShell()` helper — return -1 on null result (existing "unknown" display handles this)
- [x] T011 [US10] Refactor `getDriveIdentity()` in `lib/services/drive_service.dart` — use `_runPowerShell()` helper, replace string interpolation with `$args[0]` pattern for drive path, return null on failure
- [x] T012 [US10] Add serial number query to `getDriveIdentity()` in `lib/services/drive_service.dart` — query `Win32_DiskDrive` via `Win32_LogicalDiskToPartition` + `Win32_DiskDriveToDiskPartition` association chain, return `({String label, int totalBytes, String? serialNumber})`

**Group D** — Version metadata (3 tasks, sequential — T014 depends on T013; T015 must run after T014 to avoid broken import):
- [x] T013 [US11] Add `package_info_plus` dependency to `pubspec.yaml` and set version to `2.3.0+1`
- [x] T014 [US11] Update `lib/services/update_service.dart` to read version from `PackageInfo.fromPlatform()` instead of `constants.appVersion`
- [x] T015 [US11] Remove `appVersion` constant from `lib/utils/constants.dart` (safe now that T014 removed the last reference)

**Checkpoint**: All foundation fixes complete. Groups A-D can run in parallel; tasks within each group are sequential. Run `flutter analyze` to verify.

---

## Phase 2: Database & Queue Fixes (blocking prerequisites)

**Purpose**: DAO changes that multiple user stories depend on. `createJobWithFiles` (T018) is required by US1 and US2. Queue ordering (T019-T020) is required by US8.

**⚠️ CRITICAL**: US1 and US2 cannot begin until T018 (transactional creation) is complete.

- [x] T016 [US3] Add `recoverStaleJobs()` method to `lib/database/daos/job_dao.dart` — inside a `transaction()`, update all jobs with `status == inProgress` to `status = paused`, and update all job files with `status == inProgress` to `status = pending`
- [x] T017 [US3] Call `await jobDao.recoverStaleJobs()` in `lib/main.dart` — after DB init and after instance lock acquisition, before `runApp()`. Note: recovered jobs will resume via robocopy `/Z` when the operator manually starts them, so partial transfers continue rather than restart (existing robocopy flags already include `/Z`)
- [x] T018 [P] [US4] Add `createJobWithFiles(JobsCompanion job, List<JobFilesCompanion> files, int totalFiles, int totalBytes)` method to `lib/database/daos/job_dao.dart` — inside a `transaction()`, insert job, insert files via batch, update totals. Return the new job ID. Guard: if `files` is empty, throw an exception (prevents phantom zero-file jobs)
- [x] T019 [P] [US8] Add `getMaxSortOrder()` method to `lib/database/daos/job_dao.dart` — SELECT `max(sortOrder)` from jobs where status is queued or paused, return 0 if null
- [x] T020 [P] [US8] Fix `getNextQueuedJob()` in `lib/database/daos/job_dao.dart` — change `orderBy` from `[(t) => OrderingTerm.asc(t.createdAt)]` to `[(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt)]`

**Checkpoint**: DAO layer ready. T016-T017 are sequential (T017 depends on T016). T018, T019, T020 can run in parallel with each other and with T016-T017 (different methods, same file but no conflicts). Run `flutter analyze`.

---

## Phase 3: User Story 1 — Safe Batch Copy Across Identical Cards (Priority: P1) 🎯 MVP

**Goal**: Per-card subfolders in batch copy and single-job drive root prevent cross-card collision.

**Independent Test**: Insert two SD cards with overlapping DCIM structures, run "Copy All Cards", verify each card gets a `label_driveletter` subfolder.

**Depends on**: T008-T012 (PowerShell/getDriveIdentity), T018 (createJobWithFiles), T019 (getMaxSortOrder)

### Implementation for User Story 1

- [x] T021 [US1] Add `sanitizeDriveLabel(String label)` helper in `lib/services/job_queue_service.dart` — replace non-alphanumeric characters with `_`, use `Drive` as placeholder if label is empty
- [x] T022 [US1] Add `buildCardSubfolder(String drivePath)` helper in `lib/services/job_queue_service.dart` — calls `driveService.getDriveIdentity(drivePath)`, sanitizes label, constructs `${sanitizedLabel}_${driveLetter}` format
- [x] T023 [US1] Refactor `createBatchTransferJobs()` in `lib/services/job_queue_service.dart` — for each drive, call `buildCardSubfolder()`, prepend subfolder to all relative paths via `p.join(destination, subfolder, relativePath)`, store full subfolder path in job's `destinationPath`
- [x] T024 [US1] Update `createBatchTransferJobs()` in `lib/services/job_queue_service.dart` to use `jobDao.createJobWithFiles()` instead of three separate calls, and assign sequential `sortOrder` values (`baseOrder + 1`, `baseOrder + 2`, etc. computed from `jobDao.getMaxSortOrder()` once before the loop)
- [x] T025 [US1] Add per-card subfolder logic for single-job creation from drive root in `lib/ui/screens/create_job_screen.dart` — when source is a removable drive, apply same `label_driveletter` subfolder construction before building file entries
- [x] T026 [US1] Update single-job creation in `lib/ui/screens/create_job_screen.dart` to use `jobDao.createJobWithFiles()` instead of three separate calls, and assign `sortOrder = await jobDao.getMaxSortOrder() + 1`

**Checkpoint**: Batch copy and single-job drive root both create per-card subfolders. No cross-card collision possible. Jobs created atomically with correct sortOrder.

---

## Phase 4: User Story 2 — Existing Destination File Protection (Priority: P1)

**Goal**: Detect existing files at destination paths before creating any transfer job. Present conflict resolution dialog.

**Independent Test**: Create a job targeting a destination with existing files. Verify the conflict dialog appears with all options (skip, rename, new folder, overwrite, cancel).

### Implementation for User Story 2

- [x] T027 [US2] Create `ConflictResolutionDialog` widget in `lib/ui/widgets/conflict_dialog.dart` — modal dialog listing conflicting files with options: Skip existing, Rename (auto-suffix `_1`, `_2`), Choose new folder, Overwrite (requires typing "OVERWRITE"), Cancel. Returns enum `ConflictResolution { skip, rename, newFolder, overwrite, cancel }`
- [x] T028 [US2] Add conflict detection to single-job creation in `lib/ui/screens/create_job_screen.dart` — after building file list, check `File(dest).existsSync()` for each entry. If conflicts found, show `ConflictResolutionDialog`. Handle each resolution: filter files (skip), rename conflicting destinations with auto-suffix (rename), re-pick folder (newFolder), proceed (overwrite), abort (cancel). Zero-file guard: if all files filtered out after skip/rename, show "All files already exist at destination — no files to transfer" SnackBar and do NOT create job
- [x] T029 [US2] Add conflict resolution callback to `createBatchTransferJobs()` in `lib/services/job_queue_service.dart` — add parameter `Future<ConflictResolution> Function(List<String> conflicts)? onConflict`. Method builds complete file list for ALL cards (with per-card subfolders), checks all destination paths for existing files. If conflicts found and callback provided, awaits callback to get resolution. Applies resolution inline (skip: remove conflicting files; rename: update destination paths with `_1`, `_2` suffix; newFolder/overwrite/cancel: return to caller). Cards with zero files after resolution are skipped. This matches the existing `onProgress` callback pattern used in transfer service
- [x] T030 [US2] Wire conflict callback from `createBatchTransferJobs()` in `lib/ui/screens/home_screen.dart` — pass an `onConflict` callback that shows `ConflictResolutionDialog` and returns the user's choice. Handle `newFolder` by re-picking destination and re-calling batch creation. Handle `cancel` by aborting. If all files across all cards were removed by skip/rename, show "All files already exist" SnackBar

**Checkpoint**: No transfer job can be created without conflict detection. Skip-all creates zero jobs (not phantom jobs). Rename appends auto-suffix. Batch preflight is a single global pass before any job creation.

---

## Phase 5: User Story 5 — SD Erase Safety (Priority: P2)

**Goal**: Erase re-verifies drive identity (serial number), requires typed confirmation, and warns on size-only verification.

**Independent Test**: Verify erase dialog shows size-only warning when applicable, requires typed label, and aborts if drive identity changes.

### Implementation for User Story 5

- [x] T031 [US5] Refactor `_eraseSourceDrive()` in `lib/ui/screens/job_detail_screen.dart` — store pre-dialog identity (label, totalBytes, serialNumber) from `getDriveIdentity()`. After confirmation dialog returns true, re-call `getDriveIdentity()`. Compare serial number first (if available), then label + totalBytes as fallback. If mismatch, show "Drive changed — erase aborted" snackbar and return without erasing
- [x] T032 [US5] Add typed confirmation to erase dialog in `lib/ui/screens/job_detail_screen.dart` — add a `TextField` to the `ConfirmationDialog` content requiring operator to type the drive label or path. Erase button stays disabled until typed text matches
- [x] T033 [US5] Add size-only verification warning inside erase dialog in `lib/ui/screens/job_detail_screen.dart` — when `job.verificationMode == VerificationMode.size`, add a prominent orange `Container` with warning text "Files were verified by size only, not content hash. Proceed with caution." inside the dialog body, above the typed confirmation field

**Checkpoint**: Erase is protected by serial number re-verification, typed confirmation, and size-only warning. TOCTOU gap closed.

---

## Phase 6: User Story 6 — Reliable Subprocess Management (Priority: P2)

**Goal**: All subprocesses drain both streams, SHA-256 hashing is cancellable, and shutdown is graceful.

**Independent Test**: Stop queue during SHA-256 hashing of a large file — verify hash process is killed within 5 seconds and file is marked pending. Close app window during transfer — verify graceful shutdown completes.

### Implementation for User Story 6

- [x] T034 [US6] Add `_hashRunner` ProcessRunner field to `lib/services/transfer_service.dart` — separate from the transfer ProcessRunner, used exclusively for SHA-256 hashing
- [x] T035 [US6] Rewrite `computeFileHash()` in `lib/services/transfer_service.dart` to use `_hashRunner.run()` — capture hash from stdout callback instead of `Process.run()` return. Return hash string or null on failure/cancellation
- [x] T036 [US6] Update `cancel()` in `lib/services/transfer_service.dart` to also kill `_hashRunner` — ensures stopping queue or shutting down kills both transfer and hash subprocesses
- [x] T037 [US6] Update hash cancellation handling in `lib/services/job_queue_service.dart` — after `_transferService.cancel()` kills hash, mark the current file as `pending` (not `completed`). Ensure this DB write completes before returning from the cancellation path
- [x] T038 [US6] Make `stopProcessing()` return `Future<void>` in `lib/services/job_queue_service.dart` — add a `Completer<void>` field. Set it when `stopProcessing()` is called. Resolve it at the end of the processing loop AFTER the current iteration's file status writes complete. Return the completer's future
- [x] T039 [US6] Add `WindowListener` mixin to `_ShellScreenState` in `lib/ui/screens/shell_screen.dart` — call `windowManager.setPreventClose(true)` and `windowManager.addListener(this)` in `initState()`. Implement `onWindowClose()` to call `_gracefulShutdown()` then `windowManager.destroy()`
- [x] T040 [US6] Rewrite `_gracefulShutdown()` in `lib/ui/screens/shell_screen.dart` — depends on T038 (`stopProcessing()` returning `Future<void>`). `await jobQueueService.stopProcessing()` (no timeout on state persistence), then close log, release lock, close DB in order. Wrap entire sequence in 30-second safety timeout. Wire tray quit handler to call this same method. Remove bare `exit(0)` from window close path; tray quit calls `_gracefulShutdown()` then `exit(0)`

**Checkpoint**: Subprocesses never hang on pipe buffer. Hashing is cancellable. Shutdown is graceful for both window close and tray quit. DB is never closed while writes are pending.

---

## Phase 7: User Story 8 — Queue Processing Matches Display Order (Priority: P3)

**Goal**: Queue processor uses sortOrder for job priority, matching the UI display.

**Independent Test**: Reorder jobs via drag-and-drop, start queue, verify processing follows the displayed order.

### Implementation for User Story 8

No implementation tasks — T020 (Phase 2) fixed `getNextQueuedJob()` ordering, T024/T026 set sortOrder on creation. Verification is covered by T046 (end-to-end manual test).

**Checkpoint**: DAO fix + creation fix = queue ordering works. Verified in Phase 9.

---

## Phase 8: User Story 9 — Correct Chained Compression Paths (Priority: P3)

**Goal**: Chained compression preserves folder structure instead of flattening to basenames.

**Independent Test**: Run transfer-and-compress with duplicate basenames in different folders. Verify compressed output preserves the relative path.

### Implementation for User Story 9

- [x] T041 [US9] Fix `_createChainedCompressionJob()` in `lib/services/job_queue_service.dart` — at line 452, replace `p.join(outputPath, f.fileName)` with `p.join(outputPath, p.relative(f.destinationFilePath, from: transferJob.destinationPath))` to preserve relative folder structure in compression output

**Checkpoint**: No two compressed output files target the same path. Folder hierarchy from transfer is preserved.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Final validation across all stories.

- [x] T042 Run `dart run build_runner build` in project root to regenerate Drift code — required because T016-T020 added/modified DAO methods in `lib/database/daos/job_dao.dart`, which generates `lib/database/daos/job_dao.g.dart`
- [x] T043 Run `flutter analyze` in project root and fix any warnings or errors in files modified by this feature: `lib/utils/process_runner.dart`, `lib/utils/instance_lock.dart`, `lib/services/drive_service.dart`, `lib/services/transfer_service.dart`, `lib/services/update_service.dart`, `lib/services/job_queue_service.dart`, `lib/database/daos/job_dao.dart`, `lib/ui/screens/create_job_screen.dart`, `lib/ui/screens/job_detail_screen.dart`, `lib/ui/screens/shell_screen.dart`, `lib/ui/screens/home_screen.dart`, `lib/ui/widgets/conflict_dialog.dart`, `lib/main.dart`, `lib/utils/constants.dart`
- [x] T044 Verify `pubspec.yaml` version is `2.3.0+1` (should already be set by T013)
- [x] T045 Run `flutter test` in project root — fix `test/widget_test.dart` if it fails due to uninitialized global services (known issue from review)
- [x] T046 Verify quickstart.md manual test plan end-to-end on Windows — test: (1) batch copy with 2+ identical-structure cards → per-card subfolders, (2) single-job from drive root → subfolder created, (3) job to destination with existing files → conflict dialog with all 5 options, (4) skip-all → no job created, (5) kill app during transfer → restart → job recovered as paused, (6) stop queue during SHA-256 hashing → hash killed within 5s, (7) close window during transfer → graceful shutdown, (8) tray quit during transfer → graceful shutdown, (9) launch second instance → error dialog, (10) drag-reorder queue → processing follows display order, (11) transfer-and-compress with duplicate basenames → folder structure preserved, (12) version matches 2.3.0 in update checker

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Foundation)**: No inter-phase dependencies. Four groups (A-D) run in parallel; tasks within each group are sequential (same file)
- **Phase 2 (Database)**: T016-T017 depend on T002-T007 (instance lock, for startup recovery ordering). T018-T020 have no Phase 1 dependencies. T016-T017 are sequential; T018, T019, T020 can run in parallel with each other
- **Phase 3 (US1)**: Depends on T008-T012 (PowerShell/getDriveIdentity), T018 (createJobWithFiles), T019 (getMaxSortOrder)
- **Phase 4 (US2)**: Depends on Phase 3 (US1 — needs per-card subfolder construction for batch preflight)
- **Phase 5 (US5)**: Depends on T012 (serial number from getDriveIdentity)
- **Phase 6 (US6)**: T034-T037 depend on T001 (ProcessRunner fix). T038 depends on T037 (stopProcessing API change). T039-T040 depend on T038
- **Phase 7 (US8)**: No tasks — verification covered by T046
- **Phase 8 (US9)**: No dependencies — can run anytime
- **Phase 9 (Polish)**: Depends on all previous phases

### User Story Dependencies

- **US1 (P1)**: Depends on A3 (T008-T012) + B2 (T018) + B3 (T019) → starts after Phase 2
- **US2 (P1)**: Depends on US1 (batch path construction) → starts after Phase 3
- **US3 (P1)**: Depends on A2 (T002-T007) → T016-T017 after Phase 1
- **US4 (P1)**: No dependencies → T018 in Phase 2
- **US5 (P2)**: Depends on A3 (T012) → can start after Phase 1
- **US6 (P2)**: Depends on A1 (T001) → E1 (T034-T037) after Phase 1, E2 (T038-T040) after E1
- **US7 (P2)**: No dependencies → Phase 1
- **US8 (P3)**: Verification only → covered by T046
- **US9 (P3)**: No dependencies → T041 anytime
- **US10 (P3)**: No dependencies → Phase 1
- **US11 (P3)**: No dependencies → Phase 1

### Parallel Opportunities

- **Phase 1**: 4 groups run in parallel (A: process_runner, B: instance_lock, C: drive_service, D: version)
- **Phase 2**: T016-T017 sequential; T018, T019, T020 parallel with each other and with T016-T017
- **Phase 3 + Phase 5 + Phase 8**: Can run in parallel after their Phase 1/2 dependencies are met
- **Phase 6 (E1 portion, T034-T037)**: Can run in parallel with Phase 3/4/5 after T001

---

## Parallel Example: Phase 1

```bash
# Four groups launch simultaneously (tasks within each group are sequential):
Group A — T001: lib/utils/process_runner.dart
Group B — T002→T003→T004→T005→T006→T007: lib/utils/instance_lock.dart + lib/main.dart
Group C — T008→T009→T010→T011→T012: lib/services/drive_service.dart
Group D — T013→T014→T015: pubspec.yaml + update_service.dart + constants.dart
```

---

## Implementation Strategy

### MVP First (US1 + US2 — data loss prevention)

1. Complete Phase 1: Foundation Fixes (4 parallel groups)
2. Complete Phase 2: Database & Queue Fixes
3. Complete Phase 3: US1 — Per-card subfolders (batch + single)
4. Complete Phase 4: US2 — Conflict detection
5. **STOP and VALIDATE**: Test batch copy with identical cards, test conflict dialog
6. This alone prevents the two highest-severity data loss bugs

### Incremental Delivery

1. Foundation + Database → infrastructure ready
2. US1 + US2 → data loss prevention (MVP)
3. US3 + US4 → crash recovery + transactional creation (already done in Phase 2)
4. US5 → erase safety
5. US6 → subprocess reliability + graceful shutdown
6. US7-US11 → already done in Phase 1
7. Polish → final validation

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks in the same phase
- Tasks without [P] in the same file group are sequential — they edit the same file
- [Story] label maps task to specific user story for traceability
- No test tasks generated (not requested in spec)
- US3 (crash recovery) and US4 (transactional creation) are handled in Phase 2 as foundational prerequisites since they're DAO-level changes other stories depend on
- US7, US10, US11 are handled in Phase 1 as foundation fixes (isolated utility/service changes)
- Total: 46 tasks across 9 phases
