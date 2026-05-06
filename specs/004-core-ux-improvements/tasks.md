# Tasks: Core UX Improvements

**Input**: Design documents from `specs/004-core-ux-improvements/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: Not requested.

**Organization**: Tasks grouped by user story in priority order.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: New dependencies, shared utilities, and infrastructure

- [ ] T001 Add `window_manager` dependency to pubspec.yaml and run `flutter pub get`
- [ ] T002 [P] Create lib/utils/format_utils.dart with `formatBytes(int bytes)`, `formatDuration(Duration d)`, `formatSpeed(double bytesPerSecond)` helpers
- [ ] T003 [P] Create lib/utils/error_mapper.dart with `mapError(String rawError)` that returns `({String message, String details})` — map common Windows errors (access denied, disk full, path not found, SD removed) to human-friendly messages
- [ ] T004 [P] Add `getDiskFreeSpace(String path)` method to lib/services/drive_service.dart — use PowerShell `Get-PSDrive` to query free bytes for a given drive letter
- [ ] T005 [P] Add `getDriveIdentity(String drivePath)` method to lib/services/drive_service.dart — returns `({String label, int totalBytes})` for drive verification before erase
- [ ] T006 Add `watchCompletedJobs()` stream method to lib/database/daos/job_dao.dart — returns jobs with status completed or failed, ordered by completedAt descending
- [ ] T007 Add `resetJobForRetry(int jobId)` method to lib/database/daos/job_dao.dart — sets job status to queued, clears errorMessage; also reset failed/pending files in that job to pending via JobFileDao
- [ ] T008 Initialize window_manager in lib/main.dart — set minimum size 800x600, set title "Video Pipeline"

---

## Phase 2: Foundational — Subprocess Cancellation

**Purpose**: Store process references and add cancel methods — required before UI can wire stop properly

- [ ] T009 Refactor lib/services/transfer_service.dart — store `Process?` reference as instance field, add `cancel()` method that calls `process?.kill()`, clear reference after process exits
- [ ] T010 Refactor lib/services/compression_service.dart — store `Process?` reference as instance field, add `cancel()` method that calls `process?.kill()`, clear reference after process exits
- [ ] T011 Update lib/services/job_queue_service.dart `stopProcessing()` — call `_transferService.cancel()` and `_compressionService.cancel()` in addition to setting `_isProcessing = false`
- [ ] T012 Add `createBatchTransferJobs(List<DetectedDrive> drives, String destination)` method to lib/services/job_queue_service.dart — creates one transfer job per drive with file enumeration (reuse logic from create_job_screen)

**Checkpoint**: Services support cancellation and batch job creation.

---

## Phase 3: User Story 1 — Batch Copy All Cards (Priority: P1)

**Goal**: One-tap batch copy for all detected SD cards.

**Independent Test**: Insert multiple cards, tap "Copy All Cards," verify one job per card created.

- [ ] T013 [US1] Add "Copy All Cards" button to lib/ui/screens/home_screen.dart — prominent button above the queue list, calls DriveService to detect drives, shows destination picker, then calls JobQueueService.createBatchTransferJobs()
- [ ] T014 [US1] Handle edge cases in batch creation: skip cards with zero video files (show count of skipped), show snackbar with result ("Created 3 jobs from 4 cards — 1 card had no video files")

**Checkpoint**: Batch copy works end-to-end.

---

## Phase 4: User Story 2 — Disk Space Awareness (Priority: P1)

**Goal**: Show free space on destination, warn if insufficient.

**Independent Test**: Select a destination, verify free space displayed. Create a job exceeding space, verify warning.

- [ ] T015 [US2] In lib/ui/screens/create_job_screen.dart, after destination folder is selected, query free space via DriveService.getDiskFreeSpace() and display it next to the path (e.g., "2.3 TB free")
- [ ] T016 [US2] In lib/ui/screens/create_job_screen.dart `_createJob()`, after enumerating files, compare total size against free space. If exceeds, show warning dialog with sizes — user can proceed or cancel

**Checkpoint**: Users see free space and get warned before overflow.

---

## Phase 5: User Story 3 — Retry Failed Jobs (Priority: P1)

**Goal**: One-tap retry for failed jobs.

**Independent Test**: Fail a job, tap Retry, verify it re-queues and only processes failed files.

- [ ] T017 [US3] Add "Retry" button to lib/ui/screens/job_detail_screen.dart — visible only when job.status == failed. On tap, call JobDao.resetJobForRetry(), show snackbar "Job re-queued for retry"
- [ ] T018 [US3] In lib/services/job_queue_service.dart, ensure retried jobs work correctly — the existing file loop already skips completed files, so resetting failed files to pending is sufficient

**Checkpoint**: Failed jobs can be retried without recreation.

---

## Phase 6: User Story 4 — Progress with Time Estimates (Priority: P1)

**Goal**: ETA, elapsed, speed, current file name visible during operations.

**Independent Test**: Start a transfer, verify ETA/speed/file name shown in progress bar.

- [ ] T019 [US4] Update lib/ui/widgets/progress_bar.dart — add optional fields: `elapsedTime`, `eta`, `speed`, and update the widget layout to display them below the bar
- [ ] T020 [US4] Update lib/services/transfer_service.dart — track start time, calculate elapsed/speed/ETA based on completedBytes vs totalBytes, expose these via a progress stream or callback
- [ ] T021 [US4] Update lib/services/compression_service.dart — expose HandBrake's parsed FPS and ETA (already parsed in handbrake_parser.dart) via the progress callback
- [ ] T022 [US4] Update lib/ui/screens/job_detail_screen.dart — pass current file name, ETA, elapsed, and speed to PipelineProgressBar widget

**Checkpoint**: Users see full progress details during operations.

---

## Phase 7: User Story 5 — Immediate Stop (Priority: P2)

**Goal**: Stop Queue terminates running subprocess within 5 seconds.

**Independent Test**: Start a transfer, tap Stop, verify process dies within 5 seconds.

- [ ] T023 [US5] Update lib/ui/screens/home_screen.dart — when Stop is tapped, show snackbar "Stopping queue..." and call jobQueueService.stopProcessing() which now also kills subprocesses (wired in T011)
- [ ] T024 [US5] In lib/services/job_queue_service.dart, after subprocess cancellation in _processTransfer/_processCompression, mark the interrupted file as pending (not failed) so it can be resumed

**Checkpoint**: Stop Queue is responsive and files can be resumed.

---

## Phase 8: User Story 6 — Safe SD Card Erasure (Priority: P2)

**Goal**: Erase gated on verification, drive identity checked, button at bottom.

**Independent Test**: Complete a verified transfer, verify erase button at bottom. Swap drives, verify erase is blocked.

- [ ] T025 [US6] In lib/ui/screens/job_detail_screen.dart, move erase button to the very bottom of the page (after file list)
- [ ] T026 [US6] In lib/ui/screens/job_detail_screen.dart, gate erase button: only enabled when ALL files have verified == true. Show disabled message "Cannot erase — some files not verified" otherwise
- [ ] T027 [US6] In lib/ui/screens/job_detail_screen.dart `_eraseSourceDrive()`, before erasing: call DriveService.getDriveIdentity() and compare label/size against the original source. If mismatch, show warning "Drive appears different from original source" and block erase
- [ ] T028 [US6] Update the erase confirmation dialog to show drive label and size alongside path

**Checkpoint**: Erase is safe — verified, identity-checked, clearly positioned.

---

## Phase 9: User Story 7 — Master-Detail Layout (Priority: P2)

**Goal**: Two-panel layout — queue on left, detail/create on right.

**Independent Test**: Click a job, verify detail opens on right while queue stays visible on left.

- [ ] T029 [US7] Create lib/ui/screens/shell_screen.dart — StatefulWidget with Row layout: SizedBox(width: 320) for left panel + VerticalDivider + Expanded for right panel. Holds selectedJobId and showCreateJob state
- [ ] T030 [US7] Refactor lib/ui/screens/home_screen.dart to be embeddable as left panel — accept callbacks for onJobSelected, onCreateJob, onBatchCopy. Remove its own Scaffold/AppBar (ShellScreen provides those)
- [ ] T031 [US7] Update lib/app.dart — route to ShellScreen instead of HomeScreen. Keep Settings as a pushed route (dialog-style)
- [ ] T032 [US7] Update lib/ui/screens/create_job_screen.dart to work as an embeddable panel (no Scaffold) when used inside ShellScreen, or as standalone when pushed

**Checkpoint**: Master-detail layout works. Queue visible alongside detail.

---

## Phase 10: User Story 8 — Job History + Better Cards (Priority: P3)

**Goal**: Completed jobs visible in history. Job cards show short paths.

**Independent Test**: Complete a job, verify it appears in History. Hover card path, verify tooltip.

- [ ] T033 [US8] In lib/ui/screens/home_screen.dart (left panel), add a "History" section below the active queue — show completed/failed jobs from jobDao.watchCompletedJobs() in a collapsed/expandable list
- [ ] T034 [US8] Update lib/ui/widgets/job_card.dart `_jobSubtitle()` — show only last folder name from source and destination paths. Wrap the subtitle Text in a Tooltip widget showing the full path

**Checkpoint**: History visible, cards readable.

---

## Phase 11: User Story 9 — Error Guidance + System Checks (Priority: P3)

**Goal**: Human-friendly errors, HandBrake check, SD removal detection.

**Independent Test**: Trigger errors, verify friendly messages. Uninstall HandBrake, verify banner.

- [ ] T035 [US9] In lib/ui/screens/job_detail_screen.dart, replace raw `job.errorMessage` display with error_mapper output — show friendly message prominently, raw error in expandable "Technical Details"
- [ ] T036 [US9] In lib/ui/screens/create_job_screen.dart, on init check `compressionService.isHandbrakeInstalled()` — if not installed, show a prominent banner at top and disable Compress/Both segment buttons
- [ ] T037 [US9] In lib/services/job_queue_service.dart, detect SD card removal errors specifically (check for path-not-found errors on removable drives) and set a specific error message: "SD card disconnected. Re-insert and retry"

**Checkpoint**: Errors are understandable. Missing tools detected.

---

## Phase 12: User Story 10 — Small UX Fixes (Priority: P3)

**Goal**: Minimum window size, job creation error handling, queue feedback, current file name.

**Independent Test**: Resize window below 800x600 — verify blocked. Start queue — verify snackbar.

- [ ] T038 [US10] Minimum window size already handled by T008 — verify it works
- [ ] T039 [US10] In lib/ui/screens/home_screen.dart `_toggleProcessing()`, add snackbar feedback: "Queue started — processing X jobs" or "Queue stopped"
- [ ] T040 [US10] In lib/ui/screens/create_job_screen.dart `_createJob()`, wrap entire method body in try-catch, show error snackbar on failure: "Failed to create job — [reason]"

**Checkpoint**: All small fixes in place.

---

## Phase 13: Polish

**Purpose**: Final validation

- [ ] T041 Run `flutter analyze` and fix any issues
- [ ] T042 Run `dart run build_runner build` to regenerate Drift code if needed

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Subprocess Cancel)**: Depends on Phase 1
- **Phases 3-6 (US1-US4)**: Depend on Phase 1; can run in parallel (different files) but US4 touches the same services as Phase 2, so do sequentially
- **Phase 7 (US5 - Stop)**: Depends on Phase 2
- **Phase 8 (US6 - Erase)**: Depends on Phase 1 (drive identity method)
- **Phase 9 (US7 - Layout)**: Depends on Phase 1; impacts Phases 3, 10, 11 (screen changes) so do after those
- **Phases 10-12**: Depend on Phase 9 (layout) for proper panel integration
- **Phase 13**: After everything

### Recommended Order

1. Phase 1 (Setup) → Phase 2 (Cancel) → Phase 3 (Batch) → Phase 4 (Disk Space) → Phase 5 (Retry) → Phase 6 (Progress)
2. Phase 7 (Stop) → Phase 8 (Erase)
3. Phase 9 (Layout) → Phase 10 (History) → Phase 11 (Errors) → Phase 12 (Small fixes)
4. Phase 13 (Polish)

---

## Notes

- Phase 9 (master-detail layout) is the biggest structural change — it refactors how screens are composed
- All other phases are additive changes to existing files
- Total: 42 tasks across 13 phases
