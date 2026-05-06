# Tasks: High-Priority QA Bug Fixes

**Input**: Design documents from `specs/008-high-priority-qa-fixes/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No automated tests — manual testing on Windows 11 per project convention.

**Organization**: Tasks grouped by user story (each maps to one QA bug). QA-7 is a false positive — no code change needed, documented only.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: User Story 1 - Queue race condition guard (Priority: P1)

**Goal**: Verify the queue processing guard prevents duplicate loops.

**Independent Test**: Rapidly trigger start processing twice. Confirm only one loop runs.

### Implementation for User Story 1

- [x] T001 [US1] SKIPPED — False positive. Dart's single-threaded event loop guarantees `_isProcessing` guard at lines 46-47 of `lib/services/job_queue_service.dart` works correctly. Synchronous code between `await` points cannot interleave. No change needed.

**Checkpoint**: Confirmed existing guard is correct. No code change.

---

## Phase 2: User Story 2 - Chained compression shows accurate progress (Priority: P1)

**Goal**: Auto-created chained compression jobs show correct total file count and byte totals.

**Independent Test**: Create a transfer-and-compress job. After transfer completes, verify the chained compression job shows correct totals (e.g., "0/12 files").

### Implementation for User Story 2

- [x] T002 [US2] Add `updateJobTotals` call after inserting compression files in `_createChainedCompressionJob` at the end of the method in `lib/services/job_queue_service.dart` (after line 332). Calculate total bytes from the compression files list.

**Checkpoint**: Chained compression jobs show accurate file count and byte totals from creation.

---

## Phase 3: User Story 3 - Preset validation on job creation (Priority: P1)

**Goal**: Prevent creating compression jobs without a selected preset.

**Independent Test**: Select "Compress" job type, leave preset unselected. Verify "Add to Queue" button is disabled.

### Implementation for User Story 3

- [x] T003 [P] [US3] Add preset null check to `_canCreate()` in `lib/ui/screens/create_job_screen.dart` (before the final `return true` at line 397): `if (_jobType != JobType.transfer && _selectedPreset == null) return false;`

**Checkpoint**: Submit button disabled when compression job has no preset. Transfer-only jobs unaffected.

---

## Phase 4: User Story 4 - Reorder moves the correct job (Priority: P1)

**Goal**: Drag-to-reorder uses job IDs instead of list indices, ensuring the correct job is moved even with filtered lists.

**Independent Test**: Queue 5 jobs with some completed. Drag active job #3 to position #1. Verify the correct job moved.

### Implementation for User Story 4

- [x] T004 [US4] Rewrite `reorderJobs` method in `lib/database/daos/job_dao.dart` (lines 23-47) to accept two job IDs (`int movedJobId, int targetJobId`) instead of indices. Fetch both jobs by ID, swap their `sortOrder` values in a transaction.
- [x] T005 [US4] Update the `onReorder` callback in `lib/ui/screens/home_screen.dart` (lines 116-121) to pass `activeJobs[oldIndex].id` and `activeJobs[newIndex].id` instead of raw indices.

**Checkpoint**: Reorder always moves the correct job regardless of filtering.

---

## Phase 5: User Story 5 - Retry resets progress counters (Priority: P2)

**Goal**: After retry, job progress counters start at zero.

**Independent Test**: Fail a job at 5/10 files. Retry. Verify progress shows 0/10.

### Implementation for User Story 5

- [x] T006 [P] [US5] Add `completedFiles: Value(0), completedBytes: Value(0)` to the `JobsCompanion` in `resetJobForRetry` at lines 163-167 of `lib/database/daos/job_dao.dart`

**Checkpoint**: After retry, progress bar starts at 0. Completed files are skipped and counter increments correctly.

---

## Phase 6: User Story 6 - Context menu retry works (Priority: P2)

**Goal**: Right-click "Retry" on a failed job card actually retries the job.

**Independent Test**: Right-click a failed job, select "Retry." Verify job status changes to "queued."

### Implementation for User Story 6

- [x] T007 [US6] Add `VoidCallback? onRetry` parameter to `JobCard` widget in `lib/ui/widgets/job_card.dart`. Add `if (value == 'retry') onRetry?.call();` after line 80 in `_showContextMenu`.
- [x] T008 [US6] Pass `onRetry` callback to all `JobCard` instances in `lib/ui/screens/home_screen.dart` — callback calls `jobDao.resetJobForRetry(job.id)` then shows a confirmation snackbar.

**Checkpoint**: Context menu "Retry" re-queues the failed job.

---

## Phase 7: User Story 7 - Settings don't crash on missing row (Priority: P2)

**Goal**: App handles missing settings row gracefully with defaults.

**Independent Test**: Delete settings row from database. Launch app / open settings. Verify no crash, defaults shown.

### Implementation for User Story 7

- [x] T009 [US7] Change `watchSettings()` to use `watchSingleOrNull()` and `getSettings()` to use `getSingleOrNull()` in `lib/database/daos/settings_dao.dart` (lines 13-21). Update return types to nullable.
- [x] T010 [US7] Update all callers of `watchSettings()` and `getSettings()` to handle null with sensible defaults (empty webhook URL, update check enabled). Search for usages across `lib/ui/screens/settings_screen.dart` and `lib/app.dart`.

**Checkpoint**: App launches and settings screen works even with no settings row in the database.

---

## Phase 8: User Story 8 - File scanning handles errors (Priority: P2)

**Goal**: File scanning catches filesystem errors, continues where possible, and shows a blocking dialog listing skipped paths.

**Independent Test**: Simulate access-denied directory in source. Run scan. Verify dialog shows skipped paths, found files are still returned.

### Implementation for User Story 8

- [x] T011 [US8] Change `listVideoFiles` return type in `lib/services/drive_service.dart` (lines 74-88) to `Future<({List<FileSystemEntity> files, List<String> skippedPaths})>`. Wrap the `await for` loop in try/catch, collecting errors into `skippedPaths`. Return both lists.
- [x] T012 [US8] Update all callers of `listVideoFiles` (in `lib/ui/screens/create_job_screen.dart` and `lib/services/job_queue_service.dart`) to destructure the new return type. If `skippedPaths.isNotEmpty`, show a blocking `AlertDialog` listing the skipped paths before proceeding.

**Checkpoint**: Scanning continues past errors. Operator sees exactly which paths were skipped.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Final verification across all fixes.

- [x] T013 Run `flutter analyze` to verify zero analysis errors across all modified files
- [x] T014 Update known issues section in `CLAUDE.md` to mark the 8 high-priority bugs as resolved (7 fixed + 1 false positive)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phases 1-8**: All independent — no phase depends on another. Can be executed in any order.
- **Phase 4**: T004 must complete before T005 (DAO change before UI call site).
- **Phase 6**: T007 must complete before T008 (widget change before call site).
- **Phase 7**: T009 must complete before T010 (DAO change before callers).
- **Phase 8**: T011 must complete before T012 (return type change before callers).
- **Phase 9 (Polish)**: Depends on all phases 1-8 being complete.

### Parallel Opportunities

Phases that touch completely different files can run in parallel:

```
Phase 2 (US2: job_queue_service) ──┐
Phase 3 (US3: create_job_screen) ──┤
Phase 4 (US4: job_dao + home)     ──┤
Phase 5 (US5: job_dao)            ──┼──→ Phase 9 (Polish)
Phase 6 (US6: job_card + home)    ──┤
Phase 7 (US7: settings_dao)       ──┤
Phase 8 (US8: drive_service)      ──┘
```

Note: Phase 4+5 both touch job_dao.dart (different methods). Phase 4+6 both touch home_screen.dart (different sections). Execute these sequentially within their shared files.

---

## Implementation Strategy

### Recommended Sequential Order (Solo Developer)

Group by shared files to minimize context switching:

1. **job_queue_service.dart**: T002 (US2)
2. **create_job_screen.dart**: T003 (US3)
3. **job_dao.dart**: T004 (US4), T006 (US5) — two fixes in same file
4. **home_screen.dart + job_card.dart**: T005 (US4), T007+T008 (US6) — related UI changes
5. **settings_dao.dart + callers**: T009+T010 (US7)
6. **drive_service.dart + callers**: T011+T012 (US8)
7. **Polish**: T013+T014

---

## Notes

- QA-7 (US1) is a false positive — pre-marked as done, no code change
- All tasks are modifications to existing files — no new files created
- No schema migration needed
- Total: 14 tasks across 9 phases (7 bug fix phases + 1 false positive + 1 polish)
- [P] tasks = different files, no dependencies
