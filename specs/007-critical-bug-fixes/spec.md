# Feature Specification: Critical Bug Fixes

**Feature Branch**: `007-critical-bug-fixes`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Fix 6 critical data-loss and crash bugs identified in the v2.0.0 QA/PM review"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Safe transfer of files with duplicate names across subdirectories (Priority: P1)

An operator inserts an SD card that has multiple subdirectories (e.g., `DCIM/100CANON/`, `DCIM/101CANON/`) containing video files with the same filename (e.g., `IMG_0001.MOV` in both). They create a transfer job and expect all files to arrive intact at the destination without any being silently overwritten.

**Why this priority**: Data loss — files are permanently destroyed with no warning. This is the highest-impact bug because the operator believes the transfer succeeded while footage is missing.

**Independent Test**: Insert or simulate an SD card with two subdirectories each containing a file named `IMG_0001.MOV`. Run a transfer job. Verify both files exist at the destination with correct sizes.

**Acceptance Scenarios**:

1. **Given** a source drive with `DCIM/100CANON/IMG_0001.MOV` and `DCIM/101CANON/IMG_0001.MOV`, **When** the operator creates and runs a transfer job, **Then** both files are transferred preserving the full relative path from the drive root (e.g., `destination/DCIM/100CANON/IMG_0001.MOV` and `destination/DCIM/101CANON/IMG_0001.MOV`).
2. **Given** a source drive with files at varying nesting depths, **When** the operator runs a transfer job, **Then** the relative folder structure from the source root is mirrored at the destination.
3. **Given** a batch "Copy All Cards" operation with multiple cards each having identically-named files, **When** the operator runs the batch, **Then** every file from every card is preserved without overwrites.

---

### User Story 2 - Accurate file verification status after transfer (Priority: P1)

After a transfer completes, the operator checks the job detail screen to confirm all files were verified. If a file fails verification (size mismatch), it must be clearly marked as failed — never as completed.

**Why this priority**: Data integrity — a file marked "completed" with bad data gives false confidence. The operator may erase the SD card believing the transfer is safe, losing the only good copy.

**Independent Test**: Simulate a transfer where one file's destination copy is truncated (size mismatch). Verify the file is marked as "failed" in the database and UI, never as "completed."

**Acceptance Scenarios**:

1. **Given** a file that transfers successfully and passes size verification, **When** the system records the result, **Then** the file is marked as completed exactly once.
2. **Given** a file that transfers but fails size verification, **When** the system records the result, **Then** the file is marked as failed with a reason, and is never first marked as completed.
3. **Given** an app crash during the verification step, **When** the app restarts, **Then** no file is left in a "completed" state with unverified data — unverified files remain in "pending" or "in progress" status.

---

### User Story 3 - Complete progress reporting during transfers and compressions (Priority: P1)

The operator watches the progress screen during a long transfer or compression. They expect to see the progress reach 100% and the final status update when the operation completes — not have the progress bar freeze at 99% or miss the completion signal.

**Why this priority**: Missing the final progress lines means the UI shows stale data. This erodes trust in the tool and makes the operator unsure whether the operation actually finished.

**Independent Test**: Run a transfer or compression job and verify the last progress line (100%) is captured and displayed before the exit code is processed.

**Acceptance Scenarios**:

1. **Given** a running robocopy transfer, **When** robocopy finishes, **Then** all output lines including the final summary are processed before the app checks the exit code.
2. **Given** a running HandBrakeCLI compression, **When** compression finishes, **Then** the 100% progress line is captured and displayed before the app processes the result.
3. **Given** a subprocess that produces a burst of output just before exiting, **When** the process ends, **Then** no output lines are lost.

---

### User Story 4 - Graceful app shutdown from system tray (Priority: P2)

The operator right-clicks the system tray icon and selects "Quit." They expect the app to cleanly finish or stop any in-progress work before closing — not leave orphaned processes running or risk database corruption.

**Why this priority**: An ungraceful exit can corrupt the SQLite database (losing job history) and leave robocopy or HandBrakeCLI processes running indefinitely in the background, consuming disk I/O and CPU.

**Independent Test**: Start a transfer job, then quit via system tray. Verify that (a) the robocopy process is terminated, (b) the database is closed cleanly, and (c) no orphaned processes remain.

**Acceptance Scenarios**:

1. **Given** a transfer job is in progress, **When** the operator quits via system tray, **Then** the queue is stopped, the active job is marked as "stopped" (retryable on next launch), active subprocesses are cancelled, and the database is closed before the app exits.
2. **Given** no jobs are running, **When** the operator quits via system tray, **Then** the database is closed and the app exits cleanly.
3. **Given** a compression job is in progress, **When** the operator quits via system tray, **Then** the HandBrakeCLI process is terminated before exit.

---

### User Story 5 - Functional compression job creation form (Priority: P2)

The operator opens the job creation form and selects "Compress" or "Copy & Compress" as the job type. They pick a HandBrake preset from the dropdown and submit the job. The form must work without errors.

**Why this priority**: A compile error in the dropdown prevents the form from rendering correctly, blocking job creation for any job that involves compression.

**Independent Test**: Open the job creation screen, select a compression job type, verify the preset dropdown displays correctly with the previously selected value, and submit the job.

**Acceptance Scenarios**:

1. **Given** the operator is on the job creation screen, **When** they select a compression job type, **Then** the HandBrake preset dropdown renders without errors and displays available presets.
2. **Given** the operator has selected a preset, **When** they navigate away and return, **Then** the dropdown shows the correct selected value.

---

### User Story 6 - Reliable batch copy of all detected cards (Priority: P2)

The operator clicks "Copy All Cards" to batch-queue all detected SD cards. The operation must complete without runtime type errors regardless of what drives are detected.

**Why this priority**: A runtime crash during the most common batch operation breaks the primary workflow and forces the operator to create individual jobs manually.

**Independent Test**: Detect 2+ SD cards, click "Copy All Cards," verify all jobs are created without errors.

**Acceptance Scenarios**:

1. **Given** 3 SD cards are detected, **When** the operator clicks "Copy All Cards," **Then** 3 transfer jobs are created in the queue without any runtime errors.
2. **Given** the drive detection returns drives of the expected type, **When** they are passed to the batch creation function, **Then** no runtime type casting is needed — the function accepts the correct type directly.

---

### Edge Cases

- What happens when a source directory contains only one level of files (no subdirectories)? The destination should have the files directly, no empty parent folders.
- What happens when the subdirectory structure is very deep (e.g., 5+ levels)? The full relative path should be preserved.
- What happens when the operator quits via system tray during database write? The shutdown sequence should wait for pending writes to complete before closing.
- What happens when robocopy or HandBrakeCLI ignores the kill signal? A timeout should be applied, followed by a force kill if necessary.

## Clarifications

### Session 2026-05-06

- Q: What is the relative path root for subdirectory preservation at destination? → A: Full relative path from drive root (e.g., `E:\DCIM\100CANON\IMG_0001.MOV` → `destination/DCIM/100CANON/IMG_0001.MOV`).
- Q: What should happen to a job's status when the operator quits via system tray mid-job? → A: Mark job as "stopped" (distinct state indicating user interruption, retryable on next launch).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST preserve the full relative subdirectory structure from the source drive root when constructing destination file paths (e.g., `E:\DCIM\100CANON\IMG_0001.MOV` → `destination\DCIM\100CANON\IMG_0001.MOV`), preventing same-name files in different subdirectories from overwriting each other.
- **FR-002**: System MUST determine verification success or failure before writing any file status to the database — a file must be written as either completed (verified) or failed (unverified), never both in sequence.
- **FR-003**: System MUST fully consume all subprocess stdout and stderr output before processing the exit code, ensuring no progress lines or completion signals are lost.
- **FR-004**: System MUST perform a graceful shutdown when the operator quits via system tray: stop queue processing, mark any in-progress job as "stopped" (retryable), cancel active subprocesses, and close the database before exiting.
- **FR-005**: System MUST use the correct parameter name for the HandBrake preset dropdown so the form renders and functions without errors.
- **FR-006**: System MUST use strongly-typed parameters for the batch job creation function, eliminating runtime type casting.

### Key Entities

- **JobFile**: Represents a single file within a job. The `destinationFilePath` field must include the relative subdirectory path, not just the filename.
- **ProcessRunner**: The shared subprocess execution utility. Must guarantee stream completion before returning exit codes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Transferring a source with duplicate filenames across subdirectories results in zero data loss — all files present at destination with matching sizes.
- **SC-002**: No file in the database is ever marked as "completed" with unverified data — verified files show "completed," unverified files show "failed."
- **SC-003**: 100% of subprocess output lines are captured and processed, including the final progress line, before the result is determined.
- **SC-004**: Quitting via system tray leaves zero orphaned robocopy or HandBrakeCLI processes and zero corrupted database state.
- **SC-005**: The job creation form renders and submits without errors for all job types (transfer, compress, copy & compress).
- **SC-006**: Batch "Copy All Cards" completes without runtime type errors for any number of detected drives.

## Assumptions

- The source drive's root for relative path calculation is the path selected by the operator (e.g., `E:\`) or the drive root for batch operations.
- Graceful shutdown has a reasonable timeout (e.g., 5 seconds) for subprocess termination before force-killing.
- The existing `markFileCompleted` and `markFileFailed` DAO methods are correct individually — only the calling logic needs to change.
- The `DetectedDrive` class is the correct type for batch operations and is already imported where needed.
