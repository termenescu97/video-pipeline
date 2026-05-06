# Feature Specification: Core UX Improvements

**Feature Branch**: `004-core-ux-improvements`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "16 core UX improvements identified during architecture and UX review of v1.1.0"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Batch Copy All Cards (Priority: P1)

A video team member returns from a shoot with 4 SD cards. They insert all cards into the hub, open the app, and see a prominent "Copy All Cards" button. They tap it, select a destination folder once, and the app automatically creates one transfer job per detected card. All 4 jobs appear in the queue, ready to process.

**Why this priority**: This is the primary use case. Without it, the team must create 4 separate jobs manually — slower than their old TeraCopy workflow.

**Independent Test**: Insert multiple SD cards, tap "Copy All Cards," pick a destination, verify one job per card is created in the queue with correct source paths and file lists.

**Acceptance Scenarios**:

1. **Given** multiple SD cards are inserted, **When** the user taps "Copy All Cards," **Then** a destination picker opens
2. **Given** the user selects a destination, **When** they confirm, **Then** one transfer job per detected card is created in the queue
3. **Given** no SD cards are detected, **When** the user taps "Copy All Cards," **Then** a message says "No removable drives detected"
4. **Given** jobs are created via batch, **When** the user views the queue, **Then** each job shows the correct card label and file count

---

### User Story 2 - Disk Space Awareness (Priority: P1)

When creating a job, the user sees the available free space on the destination drive next to the folder picker. If the total size of source files exceeds available space, a warning is displayed before job creation. The user can still proceed (they may know files will be deleted to make room), but they are informed.

**Why this priority**: Without this, users discover "disk full" only when the transfer fails partway through a 100 GB file, wasting hours.

**Independent Test**: Select a destination with limited free space, create a job with source files exceeding that space, verify the warning appears.

**Acceptance Scenarios**:

1. **Given** a destination folder is selected, **When** the folder picker confirms, **Then** the available free space is displayed next to the path (e.g., "2.3 TB free")
2. **Given** source files total 500 GB and destination has 400 GB free, **When** the user tries to create the job, **Then** a warning says "Source files (500 GB) exceed available space (400 GB)"
3. **Given** the warning is shown, **When** the user confirms they want to proceed anyway, **Then** the job is created normally

---

### User Story 3 - Retry Failed Jobs (Priority: P1)

A transfer or compression job has failed. The user opens the job detail screen and sees a "Retry" button. They tap it, confirm, and the job is re-queued. Only the files that failed are reprocessed — already-completed files are skipped.

**Why this priority**: Without retry, failures are a dead end. The user must delete the job and recreate it from scratch, losing per-file progress.

**Independent Test**: Create a job, simulate a failure, tap Retry, verify the job re-enters the queue and only failed files are reprocessed.

**Acceptance Scenarios**:

1. **Given** a job has failed, **When** the user views the job detail, **Then** a "Retry" button is visible
2. **Given** the user taps "Retry," **When** they confirm, **Then** the job status changes to "queued" and failed files are reset to "pending"
3. **Given** a retried job is processed, **When** it reaches already-completed files, **Then** those files are skipped
4. **Given** a job is in progress or completed, **When** the user views the job detail, **Then** no "Retry" button is shown

---

### User Story 4 - Real-Time Progress with Time Estimates (Priority: P1)

During an active transfer or compression, the user sees: current file name being processed, percentage complete, elapsed time, estimated time remaining, and transfer speed (MB/s) or compression speed (FPS). This information is visible on both the job detail screen and the job card in the queue.

**Why this priority**: For 50-100 GB files, "how much longer?" is the most important question. Without ETA, users can't plan their time or detect stuck operations.

**Independent Test**: Start a transfer job, verify the progress bar shows current file name, percentage, ETA, and speed. Start a compression job, verify it shows percentage, FPS, and ETA.

**Acceptance Scenarios**:

1. **Given** a transfer is in progress, **When** the user views the job detail, **Then** they see: current file name, percentage, elapsed time, ETA, and speed (MB/s)
2. **Given** a compression is in progress, **When** the user views the job detail, **Then** they see: current file name, percentage, elapsed time, ETA, and FPS
3. **Given** a job is in progress, **When** the user views the queue list, **Then** the job card shows a progress percentage and current file name
4. **Given** no operation is active, **When** the user views a queued job, **Then** no progress information is shown (just "Queued" status)

---

### User Story 5 - Immediate Stop (Subprocess Cancellation) (Priority: P2)

The user taps "Stop Queue" and the currently running transfer or compression stops within seconds — not after the current multi-hour file operation completes. The interrupted file is marked as incomplete so it can be resumed later.

**Why this priority**: Without subprocess cancellation, "Stop" appears broken. A 100 GB robocopy or compression can take hours to finish, and the user has no way to interrupt it.

**Independent Test**: Start a transfer of a large file, tap Stop, verify the process terminates within 5 seconds and the file is marked as incomplete.

**Acceptance Scenarios**:

1. **Given** a transfer is in progress, **When** the user taps "Stop Queue," **Then** the running subprocess is terminated within 5 seconds
2. **Given** a compression is in progress, **When** the user taps "Stop Queue," **Then** the running subprocess is terminated within 5 seconds
3. **Given** a subprocess was killed, **When** the job is paused, **Then** the interrupted file is marked as "pending" (not "completed" or "failed") so it can be retried
4. **Given** a paused job is resumed, **When** the queue restarts, **Then** the interrupted file is reprocessed from scratch (robocopy handles partial file resume via /Z flag)

---

### User Story 6 - Safe SD Card Erasure (Priority: P2)

Before erasing an SD card, the system verifies that: (a) all files from that card were successfully transferred AND verified, (b) the SD card is still the same physical device (not a different drive that got the same letter). The confirmation dialog shows the drive label and size, not just the path. The erase button appears at the bottom of the job detail screen, after the file list, so the user reviews files before seeing the destructive action.

**Why this priority**: This is the most dangerous operation in the app. False verification status or drive letter reuse could cause irreversible data loss.

**Independent Test**: Complete a verified transfer, verify the erase button appears at the bottom with drive label. Remove the SD card and insert a different one at the same letter, verify the erase is blocked or warns.

**Acceptance Scenarios**:

1. **Given** a transfer completed with all files verified, **When** the user views job detail, **Then** the "Erase SD Card" button appears at the bottom, after the file list
2. **Given** a transfer completed with some files unverified, **When** the user views job detail, **Then** the erase button is disabled with a message "Cannot erase — some files not verified"
3. **Given** the user clicks erase, **When** the confirmation dialog appears, **Then** it shows the drive label, size, and path (not just path)
4. **Given** the original SD card was removed and a different drive mounted at the same letter, **When** the system checks before erasing, **Then** a warning says "Drive appears different from the original source — erase blocked"

---

### User Story 7 - Desktop Master-Detail Layout (Priority: P2)

The app uses a two-panel layout: the job queue list stays visible on the left, and job detail/create job screens appear on the right. The user can monitor the queue while viewing a specific job's progress, without losing context by navigating away.

**Why this priority**: The current mobile-style push/pop navigation means users lose sight of the queue when viewing details. Desktop apps should show context alongside detail.

**Independent Test**: Click a job in the queue, verify the detail panel opens on the right while the queue remains visible on the left. Create a new job, verify the form appears on the right while the queue is still visible.

**Acceptance Scenarios**:

1. **Given** the app is open, **When** the user views the home screen, **Then** a two-panel layout shows the queue list on the left
2. **Given** jobs exist in the queue, **When** the user clicks a job, **Then** the job detail appears in the right panel (queue stays visible)
3. **Given** the user clicks "New Job," **When** the create job form opens, **Then** it appears in the right panel (queue stays visible)
4. **Given** the right panel shows a job detail, **When** the user clicks a different job in the queue, **Then** the right panel updates to show the newly selected job

---

### User Story 8 - Job History and Better Job Cards (Priority: P3)

Completed and failed jobs are preserved in a "History" section below the active queue (or in a separate tab). The user can review past jobs to check what was already processed. Job cards show short, readable path labels (last folder name) with the full path available on hover.

**Why this priority**: Without history, completed jobs vanish. The team can't verify "did I already copy Card 7?" across shoot days.

**Independent Test**: Complete a job, verify it moves to the History section. Hover over a job card path, verify a tooltip shows the full path.

**Acceptance Scenarios**:

1. **Given** a job completes, **When** the user views the home screen, **Then** the job appears in a "History" section or tab
2. **Given** completed jobs exist in history, **When** the user views them, **Then** they see job type, status, date, and file counts
3. **Given** a job card is displayed, **When** the source/destination is shown, **Then** only the last folder name is displayed (e.g., "100MEDIA → Raw")
4. **Given** a job card shows short paths, **When** the user hovers over the path, **Then** a tooltip shows the full path

---

### User Story 9 - Error Guidance and System Checks (Priority: P3)

When something goes wrong, the app shows a plain-language error message with specific next steps — not a raw technical error. When the compression tool is not installed, the app shows a prominent banner with download instructions and disables compression options. When an SD card is removed mid-transfer, the error specifically identifies what happened and suggests re-inserting the card.

**Why this priority**: Non-technical video editors cannot troubleshoot raw error messages. Guided errors reduce support requests and frustration.

**Independent Test**: Trigger common errors (SD card removal, disk full, compression tool missing). Verify each produces a human-friendly message with actionable next steps.

**Acceptance Scenarios**:

1. **Given** a transfer fails due to "access denied," **When** the user views the error, **Then** the message says "The destination folder is protected. Try running the app as Administrator or choose a different folder"
2. **Given** the compression tool is not installed, **When** the user opens the create job screen, **Then** a prominent banner says "Compression requires HandBrake. Download it at handbrake.fr" and the Compress/Both options are disabled
3. **Given** an SD card is removed mid-transfer, **When** the error is detected, **Then** the message says "SD card disconnected. Please re-insert the card and tap Retry"
4. **Given** any error occurs, **When** the user views the error message, **Then** a "Technical Details" expandable section shows the raw error for IT support

---

### User Story 10 - Small UX Fixes (Priority: P3)

The app enforces a minimum window size so layouts don't break. Job creation is wrapped in error handling with user feedback. Queue start/stop shows a snackbar confirmation. The current file name is displayed in the progress bar during active operations.

**Why this priority**: Small quality-of-life improvements that individually are minor but collectively make the app feel polished and reliable.

**Independent Test**: Resize the window to very small — verify minimum size is enforced. Start the queue — verify a snackbar confirms. Create a job with a database error — verify the error is shown.

**Acceptance Scenarios**:

1. **Given** the user resizes the window, **When** they drag below 800x600, **Then** the window stops shrinking
2. **Given** the user taps "Start Queue," **When** processing begins, **Then** a snackbar says "Queue started — processing X jobs"
3. **Given** job creation fails due to an internal error, **When** the error occurs, **Then** a snackbar shows "Failed to create job — [reason]"
4. **Given** a file is being transferred or compressed, **When** the progress bar updates, **Then** the current file name is displayed

---

### Edge Cases

- What happens if the user tries "Copy All Cards" but one card is empty (no video files)?
- What happens if disk space changes between the warning and actual transfer start (other processes writing)?
- What happens if the compression tool is installed after the app launches — does the banner update?
- What happens if the user retries a job but the source files no longer exist?
- What happens if the master-detail right panel is showing a job that gets deleted from the queue?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a "Copy All Cards" action that creates one transfer job per detected removable drive with a single destination selection
- **FR-002**: System MUST display free space on the destination drive when a destination folder is selected
- **FR-003**: System MUST warn (not block) when source file size exceeds destination free space
- **FR-004**: System MUST provide a "Retry" button on the job detail screen for failed jobs
- **FR-005**: System MUST reset only failed/pending files when retrying — completed files MUST be skipped
- **FR-006**: System MUST display current file name, percentage, elapsed time, ETA, and speed during active operations
- **FR-007**: System MUST terminate the running subprocess within 5 seconds when the user stops the queue
- **FR-008**: System MUST mark interrupted files as pending (not completed) after subprocess cancellation
- **FR-009**: System MUST verify all files before enabling the SD card erase button
- **FR-010**: System MUST re-verify drive identity (label, size) before executing an erase operation
- **FR-011**: System MUST show drive label and size in the erase confirmation dialog
- **FR-012**: System MUST display the erase button at the bottom of the job detail, after the file list
- **FR-013**: System MUST use a two-panel layout: queue list on the left, detail/create on the right
- **FR-014**: System MUST preserve the queue list visibility while showing job detail or create job forms
- **FR-015**: System MUST maintain a history of completed and failed jobs visible in the interface
- **FR-016**: System MUST show only the last folder name on job cards, with full path in a tooltip
- **FR-017**: System MUST map common error patterns to human-friendly messages with remediation steps
- **FR-018**: System MUST show a raw "Technical Details" section alongside user-friendly error messages
- **FR-019**: System MUST show a prominent banner when the compression tool is not installed, with download guidance
- **FR-020**: System MUST disable compression job options when the compression tool is not available
- **FR-021**: System MUST detect SD card removal specifically and show a targeted re-insert message
- **FR-022**: System MUST enforce a minimum window size of 800x600
- **FR-023**: System MUST handle job creation errors with user-visible feedback
- **FR-024**: System MUST show snackbar confirmation when queue processing starts or stops
- **FR-025**: System MUST display the current file name in the progress bar during active operations

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can copy all SD cards to a destination in under 30 seconds of interaction (batch action), down from 2+ minutes per card
- **SC-002**: Zero "disk full" surprises — users are warned before starting if space is insufficient
- **SC-003**: Failed jobs can be retried in one tap without recreating from scratch
- **SC-004**: Users can answer "how much longer?" at a glance during any active operation
- **SC-005**: Stop Queue terminates the running operation within 5 seconds
- **SC-006**: Zero accidental SD card erasures — erase is gated on verification and drive identity
- **SC-007**: Users can monitor the queue while viewing job details simultaneously (no context loss)
- **SC-008**: Users can check past job history to verify what has been processed
- **SC-009**: 100% of errors show human-readable messages with next steps — zero raw technical errors shown to users

## Assumptions

- The master-detail layout applies to the main window only — Settings remains a full-screen dialog or separate route
- Job history is kept in the same database table, filtered by status (completed/failed) — no separate archive
- "Copy All Cards" creates transfer-only jobs (no auto-chain compression) — user can enable compression per-job from the queue later
- Subprocess cancellation uses process kill signals — partial files are left on disk and handled on retry by robocopy's /Z flag
- The compression tool installation check happens once at app launch and when the create job screen opens (not continuously)
- Minimum window size is enforced at the OS level via window configuration, not by the app layout
