# Feature Specification: UI Improvements

**Feature Branch**: `002-ui-improvements`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "UI improvements: add start queue button to home screen, add delete job from queue, fix compression-only job source picker, add snackbar feedback on job creation, add check-for-updates toggle in settings"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start Processing the Queue (Priority: P1)

A user has added one or more jobs to the queue. They want to start processing. On the home screen, they see a clearly visible "Start" button. They tap it, and the queue begins processing jobs in order. While the queue is running, the button changes to "Stop" so they can pause processing after the current job finishes.

**Why this priority**: Without this, the queue exists but cannot be started from the UI — it's the most critical missing piece.

**Independent Test**: Add a job to the queue, press Start, verify processing begins. Press Stop, verify it pauses after the current job.

**Acceptance Scenarios**:

1. **Given** jobs exist in the queue, **When** the user views the home screen, **Then** a "Start" button is visible
2. **Given** the user taps "Start," **When** queue processing begins, **Then** the button changes to "Stop"
3. **Given** the queue is processing, **When** the user taps "Stop," **Then** processing pauses after the current job completes
4. **Given** the queue is empty, **When** the user views the home screen, **Then** the "Start" button is disabled or hidden

---

### User Story 2 - Remove a Job from the Queue (Priority: P1)

A user added a job by mistake or no longer needs it. They swipe or tap a delete action on the job card in the queue. A confirmation dialog appears (human-in-the-loop). After confirming, the job is removed from the queue.

**Why this priority**: Users need a way to correct mistakes. Without this, unwanted jobs stay in the queue permanently.

**Independent Test**: Add a job, delete it via the UI, confirm the dialog, verify it disappears from the queue.

**Acceptance Scenarios**:

1. **Given** a job exists in the queue, **When** the user triggers the delete action on that job, **Then** a confirmation dialog appears
2. **Given** the confirmation dialog is shown, **When** the user confirms, **Then** the job is removed from the queue
3. **Given** the confirmation dialog is shown, **When** the user cancels, **Then** the job remains in the queue
4. **Given** a job is currently being processed, **When** the user tries to delete it, **Then** the delete action is disabled or blocked

---

### User Story 3 - Create a Compression-Only Job with Proper Source Picker (Priority: P2)

A user wants to create a compression-only job. When they select the "Compress" job type, they see a dedicated "Input Folder" picker (separate from the destination/output picker). They browse to the folder containing their video files, select it, then choose their output location and preset. The distinction between "where files come from" and "where compressed files go" is clear.

**Why this priority**: The current UX is confusing — it reuses the destination field as input for compression jobs. Fixing this prevents user errors.

**Independent Test**: Select "Compress" job type, verify a separate "Input Folder" picker appears, select an input folder and output folder, create the job, verify the paths are correct.

**Acceptance Scenarios**:

1. **Given** the user selects "Compress" job type, **When** the create job screen loads, **Then** a dedicated "Input Folder" picker is shown
2. **Given** the user selects "Compress" job type, **When** they view the form, **Then** "Input Folder" and "Output Folder" are clearly labeled and separate
3. **Given** the user fills in all fields, **When** they create the job, **Then** the source path is the input folder and the destination is the output folder

---

### User Story 4 - Feedback After Job Creation (Priority: P2)

After a user creates a job and is returned to the home screen, they see a brief confirmation message (snackbar) saying the job was added to the queue. This provides immediate visual feedback that the action succeeded.

**Why this priority**: Without feedback, the user is left wondering if their action worked, especially if the queue is long and the new job is scrolled off screen.

**Independent Test**: Create a job, verify a snackbar appears on the home screen confirming it was added.

**Acceptance Scenarios**:

1. **Given** the user fills out the create job form, **When** they tap "Add to Queue," **Then** they are returned to the home screen and a snackbar shows "Job added to queue"
2. **Given** the snackbar is shown, **When** a few seconds pass, **Then** it automatically dismisses

---

### User Story 5 - Toggle Auto-Update Check in Settings (Priority: P3)

A user opens the settings screen and sees a toggle for "Check for updates on launch." They can enable or disable it. The preference is saved and respected the next time the app starts.

**Why this priority**: Nice-to-have for users who don't want update prompts (e.g., on a metered connection or during a busy shoot day).

**Independent Test**: Toggle the setting off, restart the app, verify no update check dialog appears on launch.

**Acceptance Scenarios**:

1. **Given** the user opens settings, **When** they view the settings screen, **Then** a "Check for updates on launch" toggle is visible
2. **Given** the toggle is on, **When** the user turns it off, **Then** the preference is saved immediately
3. **Given** the toggle is off, **When** the app launches, **Then** no update check is performed

---

### Edge Cases

- What happens if the user tries to start the queue while it's already running?
- What happens if the last job is deleted while the queue is processing?
- What happens if the user creates a compression job but no video files exist in the selected input folder?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display a Start/Stop button on the home screen to control queue processing
- **FR-002**: System MUST disable or hide the Start button when the queue is empty
- **FR-003**: System MUST allow users to delete a job from the queue with a confirmation dialog
- **FR-004**: System MUST prevent deletion of a job that is currently being processed
- **FR-005**: System MUST provide a separate "Input Folder" picker when creating compression-only jobs
- **FR-006**: System MUST clearly distinguish between input folder (source of files) and output folder (where compressed files go)
- **FR-007**: System MUST show a snackbar confirmation message when a job is successfully added to the queue
- **FR-008**: System MUST provide a toggle in settings to enable/disable automatic update checking on app launch
- **FR-009**: System MUST persist the update check preference across app restarts
- **FR-010**: System MUST use the native folder picker dialog for all folder selection (no manual path entry)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can start and stop queue processing in one tap
- **SC-002**: Users can remove an unwanted job from the queue in under 10 seconds
- **SC-003**: 100% of job creation actions result in visible feedback (snackbar)
- **SC-004**: Zero confusion between input and output folders when creating compression-only jobs (clear labels, separate pickers)
- **SC-005**: All folder selections use native OS folder picker dialog — no manual path typing

## Assumptions

- These improvements apply to the existing app and do not change core pipeline behavior (transfer, compression, Slack notifications)
- The native folder picker is already integrated (file_picker package)
- The confirmation dialog widget already exists and can be reused for job deletion
- The Start/Stop state is transient (not persisted — if the app restarts, queue is stopped)
