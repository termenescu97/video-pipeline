# Tasks: Critical Bug Fixes

**Input**: Design documents from `specs/007-critical-bug-fixes/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No automated tests — manual testing on Windows 11 per project convention.

**Organization**: Tasks grouped by user story (each maps to one QA bug). No setup or foundational phase needed — all fixes are independent modifications to existing files.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: User Story 1 - Safe transfer with duplicate filenames (Priority: P1) 🎯 MVP

**Goal**: Preserve full relative subdirectory structure from source drive root when constructing destination file paths, preventing same-name files from overwriting each other.

**Independent Test**: Create a source folder with `subA/IMG_0001.MOV` and `subB/IMG_0001.MOV`. Run a transfer job. Verify both files exist at destination under `destination/subA/IMG_0001.MOV` and `destination/subB/IMG_0001.MOV`.

### Implementation for User Story 1

- [x] T001 [P] [US1] Fix destination path in batch transfer: replace `p.basename(entity.path)` with `p.relative(entity.path, from: drivePath)` for `destinationFilePath` in `lib/services/job_queue_service.dart` (lines 276-283)
- [x] T002 [P] [US1] Fix destination path in single job creation: replace `p.basename(entity.path)` with `p.relative(entity.path, from: sourcePath)` for `destinationFilePath` in `lib/ui/screens/create_job_screen.dart` (lines 488-494)

**Checkpoint**: Transfer jobs preserve subdirectory structure. Duplicate filenames in different folders no longer overwrite each other.

---

## Phase 2: User Story 2 - Accurate file verification status (Priority: P1)

**Goal**: Ensure verification result is checked before writing any file status to the database — never mark a file as completed then overwrite it as failed.

**Independent Test**: Simulate a transfer where a file fails size verification. Confirm the file is marked as "failed" in the database, never transitioning through "completed."

### Implementation for User Story 2

- [x] T003 [US2] Fix verify-then-status logic: restructure the if/else block at lines 130-145 in `lib/services/job_queue_service.dart` to check `verified` first, then call either `markFileCompleted` (if true) or `markFileFailed` (if false) — matching the compression flow pattern at lines 199-207

**Checkpoint**: File status is written exactly once per file. No file is ever marked completed with unverified data.

---

## Phase 3: User Story 3 - Complete progress reporting (Priority: P1)

**Goal**: Guarantee all subprocess stdout/stderr output is fully consumed before the exit code is processed, so no progress lines (including the final 100%) are lost.

**Independent Test**: Run a transfer or compression job. Verify the progress reaches 100% and the final summary line is captured before the job result is determined.

### Implementation for User Story 3

- [x] T004 [US3] Replace fire-and-forget `.listen()` with awaitable `Stream.forEach()` for both stdout and stderr in `lib/utils/process_runner.dart` (lines 17-31). Use `Future.wait([stdoutDone, stderrDone])` before `await process.exitCode`

**Checkpoint**: All subprocess output lines are processed before exit code is checked. Progress bar reaches 100%.

---

## Phase 4: User Story 4 - Graceful shutdown from system tray (Priority: P2)

**Goal**: Replace `exit(0)` with a graceful shutdown sequence that stops the queue, marks in-progress jobs as paused, cancels subprocesses, and closes the database.

**Independent Test**: Start a transfer job, quit via system tray. Verify (a) no orphaned robocopy process, (b) database intact, (c) job marked as paused/retryable.

### Implementation for User Story 4

- [x] T005 [US4] Create async `_gracefulShutdown()` method in `lib/ui/screens/shell_screen.dart` that calls `jobQueueService.stopProcessing()`, `await database.close()`, then `exit(0)` — replacing the direct `exit(0)` call at line 64
- [x] T006 [US4] Verify that `jobQueueService` and `database` globals from `lib/main.dart` are accessible in shell_screen.dart (add import if needed)

**Checkpoint**: Tray quit stops all processes, closes database cleanly. Job is retryable on next launch.

---

## Phase 5: User Story 5 - Functional compression dropdown (Priority: P2)

**Goal**: Fix the compile error in the HandBrake preset dropdown so the job creation form renders correctly.

**Independent Test**: Open job creation screen, select compression job type, verify preset dropdown renders and selection works.

### Implementation for User Story 5

- [x] T007 [P] [US5] SKIPPED — `initialValue:` is correct in Flutter 3.41.9 (`value` is deprecated). QA review was wrong on this one. No change needed.

**Checkpoint**: Preset dropdown renders without errors for compression and copy-and-compress job types.

---

## Phase 6: User Story 6 - Type-safe batch copy (Priority: P2)

**Goal**: Change the batch transfer parameter from `List<dynamic>` to `List<DetectedDrive>` to eliminate runtime type casting.

**Independent Test**: Click "Copy All Cards" with 2+ detected drives. Verify jobs are created without runtime errors.

### Implementation for User Story 6

- [x] T008 [US6] Change parameter type from `List<dynamic>` to `List<DetectedDrive>` in `createBatchTransferJobs` at line 239 of `lib/services/job_queue_service.dart`, remove `as String` cast at line 246, and add import for `DetectedDrive` if not already present

**Checkpoint**: Batch copy uses compile-time type checking. No runtime casts.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final verification across all fixes.

- [x] T009 Run `flutter analyze` to verify zero analysis errors across all modified files
- [x] T010 Update known issues section in `CLAUDE.md` to mark the 6 critical bugs as fixed

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phases 1-6**: All independent — no phase depends on another. Can be executed in any order.
- **Phase 7 (Polish)**: Depends on all phases 1-6 being complete.

### User Story Dependencies

- **US1** (duplicate filenames): Independent. Touches job_queue_service.dart and create_job_screen.dart.
- **US2** (verify race): Independent. Touches job_queue_service.dart (different lines from US1).
- **US3** (stream awaiting): Independent. Touches process_runner.dart only.
- **US4** (graceful shutdown): Independent. Touches shell_screen.dart and main.dart only.
- **US5** (dropdown param): Independent. Touches create_job_screen.dart (different line from US1).
- **US6** (typed batch param): Independent. Touches job_queue_service.dart (different lines from US1/US2).

### Parallel Opportunities

All user story phases can run in parallel since they modify different lines/methods within the affected files:

```
Phase 1 (US1) ──┐
Phase 2 (US2) ──┤
Phase 3 (US3) ──┼──→ Phase 7 (Polish)
Phase 4 (US4) ──┤
Phase 5 (US5) ──┤
Phase 6 (US6) ──┘
```

Within Phase 1, T001 and T002 can run in parallel (different files).

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Fix duplicate filename overwrites (highest data-loss risk)
2. **STOP and VALIDATE**: Test with duplicate filenames across subdirectories
3. Proceed to remaining phases

### Sequential Delivery (Recommended for Solo Developer)

1. Phase 1 (US1) → Phase 2 (US2) → Phase 6 (US6) — all touch job_queue_service.dart, do together
2. Phase 5 (US5) → merge with Phase 1's create_job_screen.dart changes
3. Phase 3 (US3) — standalone process_runner.dart fix
4. Phase 4 (US4) — standalone shell_screen.dart fix
5. Phase 7 — verify all, update docs

---

## Notes

- All tasks are modifications to existing files — no new files created
- No schema migration needed — reuses existing `paused` JobStatus
- [P] tasks = different files, no dependencies
- Commit after each phase or logical group
- Total: 10 tasks across 7 phases (6 bug fix phases + 1 polish phase)
