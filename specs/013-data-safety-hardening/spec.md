# Feature Specification: Data Safety & Reliability Hardening

**Feature Branch**: `013-data-safety-hardening`  
**Created**: 2026-05-07  
**Status**: Draft  
**Input**: 14 validated findings from GPT 5.5 adversarial code review + counter-review

## Clarifications

### Session 2026-05-07

- Q: How should per-card subfolders be named when two cards have identical labels? → A: Always use `label_driveletter` format (e.g., `EOS_DIGITAL_E/`, `EOS_DIGITAL_F/`). No fallback logic needed.
- Q: Should recovered in-progress jobs auto-resume or wait for manual start? → A: Recover to paused state. Operator must manually resume after reviewing.
- Q: Does destination conflict detection apply inside batch copy with per-card subfolders? → A: Yes, conflict detection applies universally to all job creation (single and batch), including inside per-card subfolders.

## User Scenarios & Testing

### User Story 1 - Safe Batch Copy Across Identical Cards (Priority: P1)

An operator shoots with two Canon cameras. Both SD cards contain `DCIM/100CANON/C0001.MP4`. The operator inserts both cards, clicks "Copy All Cards", and expects all footage from both cards to be preserved at the destination without any file being overwritten.

**Why this priority**: Silent footage loss is the highest-severity risk. Irreplaceable footage from a shoot day can be permanently destroyed with no warning.

**Independent Test**: Insert two SD cards with overlapping folder structures, run batch copy, verify all files from both cards exist at the destination with no overwrites.

**Acceptance Scenarios**:

1. **Given** two SD cards with identical DCIM folder structure, **When** the operator runs "Copy All Cards", **Then** each card's files are placed in a separate per-card subfolder at the destination using `label_driveletter` format (e.g., `EOS_DIGITAL_E/`, `EOS_DIGITAL_F/`).
2. **Given** a single job created from a drive root, **When** the destination already contains files from a previous card with the same folder structure, **Then** the system detects the collision and creates a distinct subfolder.
3. **Given** batch copy completes, **Then** the destination folder names use the `label_driveletter` format to clearly identify which card each subfolder came from.

---

### User Story 2 - Existing Destination File Protection (Priority: P1)

An operator accidentally selects a destination folder that already contains production files from a previous shoot. The system must detect the conflict before any transfer starts and require the operator to explicitly resolve it — not silently overwrite.

**Why this priority**: Overwriting existing production files violates the constitution's human-in-the-loop principle and can destroy finalized work.

**Independent Test**: Create a job where destination files already exist, verify the system blocks and presents conflict resolution options before any file is copied.

**Acceptance Scenarios**:

1. **Given** a job is about to be created and some destination file paths already exist, **When** the operator clicks "Create Job", **Then** the system shows a conflict dialog listing the affected files.
2. **Given** a conflict is detected, **When** the operator chooses "Skip existing", **Then** only new files are queued for transfer.
3. **Given** a conflict is detected, **When** the operator chooses "Choose new folder", **Then** the folder picker opens and the job is re-targeted.
4. **Given** a conflict is detected, **When** the operator chooses "Overwrite", **Then** the operator must type "OVERWRITE" to confirm.

---

### User Story 3 - Crash Recovery for In-Progress Jobs (Priority: P1)

The operator is transferring footage when the PC loses power. On restart, the interrupted job should not be stranded — the app must detect it and resume it automatically, leveraging robocopy's `/Z` resumable flag.

**Why this priority**: Without recovery, a crashed transfer is silently abandoned. The operator may not notice, leading to incomplete footage on the destination drive.

**Independent Test**: Simulate a crash by killing the app during transfer, restart it, verify the interrupted job is recovered and resumes.

**Acceptance Scenarios**:

1. **Given** a job was in-progress when the app crashed, **When** the app restarts, **Then** the job and its in-progress files are moved to paused state. The operator must manually resume after reviewing.
2. **Given** a recovered job is manually resumed by the operator, **When** robocopy runs with `/Z`, **Then** partially transferred files continue from where they left off rather than restarting.
3. **Given** multiple jobs were in-progress at crash time, **When** the app restarts, **Then** all stranded jobs are recovered to paused state.

---

### User Story 4 - Transactional Job Creation (Priority: P1)

When an operator creates a job, all database records (job row, file rows, totals) must be written atomically. A crash mid-creation must not leave a half-created job that later gets marked "completed" without transferring any files.

**Why this priority**: A phantom job that appears completed but transferred nothing is a silent data loss scenario — the operator believes footage was copied when it was not.

**Independent Test**: Verify that job creation writes are wrapped in a single transaction by checking that either all records exist or none do after an interrupted creation.

**Acceptance Scenarios**:

1. **Given** the operator creates a job, **When** the job, files, and totals are saved, **Then** all writes occur in a single database transaction.
2. **Given** a crash occurs during job creation, **When** the app restarts, **Then** no partial job records exist in the database.

---

### User Story 5 - SD Erase Safety (Priority: P2)

Before erasing an SD card, the system must re-verify that the physical device at the drive letter is the same one the operator confirmed. Additionally, if the operator used size-only verification, the erase dialog must clearly warn that content integrity was not fully verified.

**Why this priority**: Erasing the wrong card or erasing before confirming content integrity destroys irreplaceable footage. The current flow has a time-of-check-to-time-of-use gap and a weak verification gate.

**Independent Test**: Verify that erase re-checks drive identity after confirmation, and that size-only verified jobs show an explicit warning before erase.

**Acceptance Scenarios**:

1. **Given** the operator confirms erase, **When** the system is about to delete, **Then** it re-reads the drive identity and compares it to the pre-dialog identity. If they differ, the erase is aborted with a warning.
2. **Given** the operator confirmed erase but the card was physically swapped during the dialog, **Then** the system detects the identity mismatch and refuses to erase.
3. **Given** a job was verified with size-only mode, **When** the operator attempts to erase the source card, **Then** the dialog shows a prominent warning: "Files were verified by size only, not content hash. Proceed with caution."
4. **Given** a job was verified with SHA-256, **When** the operator attempts erase, **Then** no extra warning is shown (full verification passed).
5. **Given** the erase confirmation dialog, **When** the operator confirms, **Then** the operator must type the drive label or path to proceed.

---

### User Story 6 - Reliable Subprocess Management (Priority: P2)

All subprocess interactions (transfers, compression, hashing) must be safe from pipe hangs, must be cancellable, and must be properly awaited during shutdown.

**Why this priority**: A hung subprocess blocks the entire queue silently. An uncancellable 50GB hash operation prevents clean shutdown. A shutdown that doesn't await the queue loop can corrupt the database.

**Independent Test**: Verify that stopping the queue during SHA-256 hashing cancels the hash process; verify that closing the app waits for the queue to finish writing state before closing the database.

**Acceptance Scenarios**:

1. **Given** a subprocess is running (transfer, compression, or hashing), **When** it writes to stdout or stderr, **Then** both streams are always consumed regardless of whether the app uses the output.
2. **Given** a 50GB file is being SHA-256 hashed, **When** the operator stops the queue, **Then** the hash process is killed within 5 seconds and the file is marked for re-verification.
3. **Given** the operator closes the app window, **When** jobs are processing, **Then** the app intercepts the close, stops the queue, awaits state persistence, and only then closes the database and exits.
4. **Given** the operator quits via system tray, **Then** the same graceful shutdown sequence applies.

---

### User Story 7 - Single-Instance Safety (Priority: P2)

Only one instance of the app may run against a given database. If a second instance is launched, it must fail immediately with a clear message rather than silently proceeding.

**Why this priority**: Two instances writing to the same SQLite database will corrupt it, potentially losing all job history and state.

**Independent Test**: Launch two instances, verify the second one is blocked with an error message.

**Acceptance Scenarios**:

1. **Given** the app is running, **When** a second instance is launched, **Then** the second instance shows an error dialog and exits.
2. **Given** the lock cannot be acquired (file permissions, read-only location), **Then** the app refuses to start (fails closed) rather than proceeding without the lock.
3. **Given** a previous instance crashed and left a stale lock, **Then** the new instance detects the stale lock and recovers it.

---

### User Story 8 - Queue Processing Matches Display Order (Priority: P3)

When the operator drags a job to the top of the queue to prioritize it, the queue processor must process jobs in that order — not in creation-time order.

**Why this priority**: The reorder UI is misleading if it has no effect on processing. Operators may prioritize urgent footage and not realize it won't actually be processed first.

**Independent Test**: Reorder jobs via drag-and-drop, start the queue, verify jobs process in the displayed order.

**Acceptance Scenarios**:

1. **Given** the operator reorders the queue via drag-and-drop, **When** processing starts, **Then** jobs are processed in the displayed order (by sortOrder, then by createdAt as tiebreaker).
2. **Given** a new job is created, **Then** it receives a sortOrder value that places it at the end of the current queue.

---

### User Story 9 - Correct Chained Compression Paths (Priority: P3)

When transfer-and-compress mode creates a chained compression job, the output file paths must preserve the folder structure from the transfer — not flatten everything to the output root.

**Why this priority**: Flattening causes filename collisions when two source folders contain files with the same basename, silently overwriting one compressed file with another.

**Independent Test**: Run transfer-and-compress with source files that have duplicate basenames in different folders. Verify compressed output preserves folder structure.

**Acceptance Scenarios**:

1. **Given** a transfer-and-compress job where source files include `FolderA/C0001.MP4` and `FolderB/C0001.MP4`, **When** compression runs, **Then** output is `output/FolderA/C0001.MP4` and `output/FolderB/C0001.MP4`.
2. **Given** chained compression, **Then** no two output files target the same path.

---

### User Story 10 - Robust PowerShell Integration (Priority: P3)

All PowerShell subprocess calls in drive detection and identity must handle failures gracefully and avoid command string interpolation.

**Why this priority**: Unhandled PowerShell failures crash the UI. String interpolation in command construction is harder to audit and can introduce injection vectors.

**Independent Test**: Verify all PowerShell calls are wrapped in error handling and use argument passing instead of string interpolation.

**Acceptance Scenarios**:

1. **Given** PowerShell is unavailable or returns an error, **When** drive detection runs, **Then** the app shows a user-friendly error instead of crashing.
2. **Given** getDriveIdentity is called, **Then** the drive path is passed via `$args` rather than interpolated into the command string.

---

### User Story 11 - Accurate Version Metadata (Priority: P3)

The app must report its actual version so that the update checker compares against the correct baseline.

**Why this priority**: With version stuck at 1.0.0, the update checker always reports a false "upgrade available" for users already running the latest release.

**Independent Test**: Build the app, check that the reported version matches the release tag.

**Acceptance Scenarios**:

1. **Given** the app is built from a tagged release, **Then** the version displayed in the app and used by the update checker matches the git tag / pubspec.yaml version.
2. **Given** pubspec.yaml is updated, **Then** no separate constants.dart edit is needed (version is single-sourced).

---

### Edge Cases

- What happens when a drive label is empty or contains special characters? The label portion is sanitized (special characters removed); if the label is empty, `Drive` is used as placeholder (e.g., `Drive_E/`).
- What happens when the operator creates a single job (not batch) from a drive root that collides with an existing destination folder? The same collision detection and resolution applies.
- What happens when all files at the destination already exist? The conflict dialog shows "all files conflict" and offers the same resolution options.
- What happens when a recovered in-progress job's source card is no longer mounted? The job resumes in queued/paused state; when processing reaches it, it fails with a clear "source not found" error.
- What happens when shutdown is triggered during database recovery of stale jobs? Recovery runs before the queue starts, so shutdown during recovery aborts the recovery and exits cleanly.

## Requirements

### Functional Requirements

**Data Integrity — Transfer**
- **FR-001**: System MUST create a per-card subfolder in the destination when batch-copying multiple cards, using `label_driveletter` format (e.g., `EOS_DIGITAL_E/`) as the subfolder name.
- **FR-002**: System MUST detect existing files at destination paths before creating any transfer job (single or batch, including inside per-card subfolders) and present a conflict resolution dialog (skip, rename, new folder, or typed overwrite confirmation).
- **FR-003**: Chained compression output MUST preserve the relative folder structure from the transfer destination, not flatten to basenames.

**Data Integrity — Recovery**
- **FR-004**: On startup, the system MUST detect jobs left in in-progress state and move them (and their in-progress files) to paused state. The operator must manually resume.
- **FR-005**: Job creation (job record, file records, totals) MUST be written in a single atomic database transaction.

**Data Integrity — Erase**
- **FR-006**: Before executing SD card erase, the system MUST re-verify drive identity after the confirmation dialog and abort if identity has changed.
- **FR-007**: The erase confirmation dialog MUST require the operator to type the drive label or path to proceed.
- **FR-008**: When files were verified by size only (not SHA-256), the erase dialog MUST display a prominent warning about the weaker verification.

**Subprocess Reliability**
- **FR-009**: The process runner MUST always consume both stdout and stderr streams, regardless of whether callbacks are provided.
- **FR-010**: SHA-256 hashing MUST be cancellable — stopping the queue or shutting down MUST kill the hash process within 5 seconds.
- **FR-011**: App shutdown (window close or tray quit) MUST await queue processing stop and state persistence before closing the database.

**Instance & Queue Safety**
- **FR-012**: The single-instance lock MUST fail closed — if the lock cannot be acquired, the app MUST refuse to start.
- **FR-013**: The queue processor MUST order jobs by sortOrder first, then by createdAt, matching the UI display order.
- **FR-014**: New jobs MUST receive a sortOrder value that places them at the end of the current queue.

**Operational**
- **FR-015**: All PowerShell subprocess calls MUST be wrapped in error handling that surfaces user-friendly messages on failure.
- **FR-016**: getDriveIdentity MUST pass the drive path via `$args` instead of interpolating it into the command string.
- **FR-017**: The app version MUST be single-sourced from pubspec.yaml, eliminating the separate constants.dart version string.

### Key Entities

- **Job**: Extended with per-card destination subfolder logic. Recovery on startup for stale in-progress state.
- **JobFile**: Recovery on startup for stale in-progress state. Hash process must be cancellable.
- **DriveIdentity**: Re-verified before erase. Used to name per-card subfolders.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Zero footage files are silently overwritten during batch copy of cards with overlapping folder structures.
- **SC-002**: Zero footage files are silently overwritten at an existing destination without explicit operator confirmation.
- **SC-003**: 100% of in-progress jobs are recovered to a resumable state after an app crash or power loss.
- **SC-004**: Zero partial (phantom) jobs exist in the database after any crash scenario.
- **SC-005**: SD card erase is blocked if the physical device changes between confirmation and execution.
- **SC-006**: Operators see an explicit warning when erasing a source card verified only by file size.
- **SC-007**: Queue stop or app shutdown completes within 10 seconds, even during large-file SHA-256 hashing.
- **SC-008**: A second app instance is blocked from running with a clear error message.
- **SC-009**: Jobs process in the order displayed in the queue after drag-and-drop reordering.
- **SC-010**: The update checker correctly identifies when the running version matches the latest release.

## Assumptions

- The app continues to target Windows 11 only; OS-level named mutex or atomic lock file APIs are available.
- Drive labels are generally set by camera manufacturers (e.g., "EOS_DIGITAL", "LUMIX") and are usable as subfolder names after sanitizing special characters.
- The existing robocopy `/Z` flag correctly resumes partially transferred files without requiring app-side byte tracking.
- PowerShell is available on all target machines (ships with Windows 11).
- The Drift ORM supports wrapping multiple operations in a single transaction.
- The `window_manager` package supports intercepting window close events via `setPreventClose`.
