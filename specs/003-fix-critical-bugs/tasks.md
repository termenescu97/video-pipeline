# Tasks: Critical Bug Fixes

**Input**: Design documents from `specs/003-fix-critical-bugs/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: Not requested.

**Organization**: Tasks grouped by user story. Since these are bug fixes to existing code, setup and foundational phases are minimal.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: Shared infrastructure changes that multiple bug fixes depend on

- [ ] T001 Create singleton service instances (JobQueueService, TransferService, CompressionService, SlackService, DriveService, all DAOs) in lib/main.dart
- [ ] T002 Add `updateJobTotals(int jobId, int totalFiles, int totalBytes)` method to lib/database/daos/job_dao.dart
- [ ] T003 Update `getNextQueuedJob()` to also pick up paused jobs (status == queued OR status == paused) in lib/database/daos/job_dao.dart
- [ ] T004 Add `import 'package:path/path.dart' as p;` to lib/services/job_queue_service.dart
- [ ] T005 Regenerate Drift code with `dart run build_runner build`

---

## Phase 2: Foundational — Remove Duplicate Service Instances

**Purpose**: All screens must use singletons before story-specific fixes can work correctly

**CRITICAL**: Must complete before user story work begins

- [ ] T006 [P] Update lib/ui/screens/home_screen.dart to import and use singleton services from main.dart instead of creating local instances in initState()
- [ ] T007 [P] Update lib/ui/screens/create_job_screen.dart to import and use singleton services from main.dart instead of creating local instances in initState()
- [ ] T008 [P] Update lib/ui/screens/job_detail_screen.dart to import and use singleton services from main.dart instead of creating local instances in initState()
- [ ] T009 [P] Update lib/ui/screens/settings_screen.dart to import and use singleton services from main.dart instead of creating local instances in initState()

**Checkpoint**: All screens share singleton service instances. No duplicate processing possible.

---

## Phase 3: User Story 1 — Files Actually Transferred (Priority: P1)

**Goal**: Jobs enumerate video files at creation time and the pipeline processes them.

**Independent Test**: Create a transfer job for a source with video files. Start the queue. Verify files appear on the destination.

- [ ] T010 [US1] In lib/ui/screens/create_job_screen.dart `_createJob()`, after inserting the job, scan source path for video files using DriveService.listVideoFiles(), create JobFilesCompanion entries with proper paths via p.join(), insert via JobFileDao.insertFiles(), update job totals via JobDao.updateJobTotals()
- [ ] T011 [US1] In lib/ui/screens/create_job_screen.dart `_createJob()`, if zero video files found in source, show error snackbar and delete the just-created job (or don't create it)
- [ ] T012 [US1] Update lib/services/drive_service.dart `listVideoFiles()` to use constants from lib/utils/constants.dart for video extensions instead of hardcoded strings, and use p.extension() for robust extension matching

**Checkpoint**: Jobs are created with accurate file lists. Queue processes actual files.

---

## Phase 4: User Story 2 — Queue Processes Without Duplication (Priority: P1)

**Goal**: Only one queue processing loop runs at any time.

**Independent Test**: Start queue, navigate away and back, verify no duplicate processing.

- [ ] T013 [US2] Already fixed by Phase 2 (singleton JobQueueService). Verify in lib/ui/screens/home_screen.dart that `_isProcessing` state is read from the singleton `jobQueueService.isProcessing` rather than local state, so it survives navigation

**Checkpoint**: Navigation does not spawn duplicate queue processors.

---

## Phase 5: User Story 3 — Transfer Verification (Priority: P1)

**Goal**: Every transferred file is verified by size comparison. Results reported accurately.

**Independent Test**: Transfer files, verify that file statuses reflect actual size comparison results.

- [ ] T014 [US3] In lib/services/job_queue_service.dart `_processTransfer()`, after successful `transferFile()`, call `transferService.verifyTransfer()` with source and destination paths. Pass actual result to `markFileCompleted(verified: actualResult)`. If verification fails, mark file as failed with error "Verification failed: size mismatch"
- [ ] T015 [US3] Update lib/services/slack_service.dart `notifyTransferCompleted()` to accept a `bool allVerified` parameter and report actual verification status instead of hardcoded "Verification: Passed"
- [ ] T016 [US3] In lib/services/job_queue_service.dart `_createChainedCompressionJob()`, filter files on `f.status == FileStatus.completed && f.verified == true` (not just completed) so unverified files are excluded from compression

**Checkpoint**: Transferred files have real verification status. Slack reports truth. Chained compression only includes verified files.

---

## Phase 6: User Story 4 — Accurate Job Status (Priority: P2)

**Goal**: Partial compression failures and stopped-queue interruptions are reflected accurately in job status.

**Independent Test**: (a) Compression with failed files shows partial failure status. (b) Stopping queue mid-job marks it as paused.

- [ ] T017 [US4] In lib/services/job_queue_service.dart `_processCompression()`, after the file loop, count failed files. If any failed, mark job as failed with error "X/Y files compressed, Z failed" instead of marking as completed
- [ ] T018 [US4] In lib/services/job_queue_service.dart `_processTransfer()`, after the file loop, check if interrupted by `!_isProcessing`. If so, mark job as `paused` via `jobDao.updateJobStatus(job.id, JobStatus.paused)` and return without sending completion notification
- [ ] T019 [US4] In lib/services/job_queue_service.dart `_processCompression()`, after the file loop, check if interrupted by `!_isProcessing`. If so, mark job as `paused` and return without sending completion notification

**Checkpoint**: Job status always reflects reality. Paused jobs resume when queue restarts.

---

## Phase 7: User Story 5 — Windows Path Joining (Priority: P2)

**Goal**: All file paths use proper platform-aware construction.

**Independent Test**: Create a transfer+compress job. Verify compression output paths are correct Windows paths.

- [ ] T020 [US5] In lib/services/job_queue_service.dart `_createChainedCompressionJob()`, replace `'$outputPath/${f.fileName}'` with `p.join(outputPath, f.fileName)`
- [ ] T021 [US5] In lib/ui/screens/create_job_screen.dart `_createJob()` file enumeration, use `p.join(destinationPath, fileName)` when constructing destination file paths for JobFiles

**Checkpoint**: All paths are Windows-compatible.

---

## Phase 8: Polish

**Purpose**: Final validation

- [ ] T022 Run `flutter analyze` and fix any issues
- [ ] T023 Run `dart run build_runner build` to regenerate Drift code if any DAO changes were made after T005

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Singletons)**: Depends on Phase 1 — BLOCKS all user stories
- **Phase 3 (US1 - Files)**: Depends on Phase 2
- **Phase 4 (US2 - No Duplication)**: Depends on Phase 2 (mostly already solved by it)
- **Phase 5 (US3 - Verification)**: Depends on Phase 2; independent of US1
- **Phase 6 (US4 - Status)**: Depends on Phase 2; independent of US1/US3
- **Phase 7 (US5 - Paths)**: Depends on Phase 2; independent of others
- **Phase 8 (Polish)**: Depends on all previous phases

### Parallel Opportunities

- T006, T007, T008, T009 (Phase 2): all modify different screen files
- Phases 3, 5, 6, 7 (US1, US3, US4, US5) modify different parts of `job_queue_service.dart` — should be done sequentially to avoid conflicts
- Phase 4 (US2) is mostly a verification step after Phase 2

---

## Implementation Strategy

### MVP First

1. Complete Phase 1 + 2 (singletons) → race condition fixed
2. Complete Phase 3 (file enumeration) → pipeline actually works
3. **STOP and VALIDATE**: Create a job, start queue, verify files transfer
4. Continue with Phases 5-7 (verification, status, paths)
5. Polish and release

---

## Notes

- All changes are to existing files — no new files created
- The most impactful fix is Phase 3 (file enumeration) — without it the app is a no-op
- Phase 2 (singletons) prevents the race condition and must be done first
- Tasks T018/T019 both modify `job_queue_service.dart` — do them sequentially
