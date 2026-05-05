# Feature Specification: Video Pipeline Automation

**Feature Branch**: `001-video-pipeline-automation`
**Created**: 2026-05-05
**Status**: Clarified
**Input**: User description: "Automate video production workflow: SD card detection, file transfer, compression, with GUI and Slack notifications"

## Clarifications

### Session 2026-05-05

- Q: Are transfer and compression linked as one pipeline or independent operations? → A: Independent operations, configurable per job. User builds a job queue where each job has its own settings (source, destination, whether to auto-chain compression, preset). Some jobs may only transfer, others may chain into compression.
- Q: What defines a pipeline run for state persistence? → A: Per-job. Each job in the queue tracks its own state independently (source, destination, progress, completion). If interrupted, the app shows the job queue with each job's status and can resume incomplete ones.
- Q: Where do compressed files go? → A: User chooses output location per job. The app supports saving paths as "favorites" for quick reuse across future jobs.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Job Queue and Transfer (Priority: P1)

After a shoot, a video team member inserts multiple filled SD cards into the card hub. They open the app, see all detected SD card volumes listed, and create jobs for the queue. For each job, they select a source drive, choose a destination folder (from favorites or by browsing), and optionally configure auto-chain to compression. They click "Start" and the queue processes jobs in order, with real-time progress visible. When a job completes, they receive a Slack notification.

**Why this priority**: This is the most time-consuming manual step and the foundation of the entire pipeline. Without reliable, resumable file transfer, nothing else matters.

**Independent Test**: Can be fully tested by inserting an SD card, creating a transfer job, starting it, and verifying files arrive at the chosen destination with correct sizes. Delivers immediate value even without compression.

**Acceptance Scenarios**:

1. **Given** SD cards are inserted in the hub, **When** the user opens the app, **Then** all mounted removable drives are listed with their names and sizes
2. **Given** the user creates a job, **When** they select a source and destination (from favorites or by browsing), **Then** the job appears in the queue with its configuration
3. **Given** the user has jobs in the queue, **When** they click "Start," **Then** jobs process in order with per-job progress displayed
4. **Given** a transfer job is in progress, **When** power is lost and restored, **Then** re-opening the app shows the job queue with each job's status; incomplete jobs can be resumed
5. **Given** a job completes successfully, **When** all files are verified, **Then** a Slack notification is sent with a summary (file count, total size, duration)
6. **Given** a job fails, **When** the error is detected, **Then** the app displays the error, marks the job as failed, and sends a Slack notification with the failure details
7. **Given** a job is configured with auto-chain compression, **When** transfer completes, **Then** compression starts automatically using the job's configured preset and output location

---

### User Story 2 - Compress Transferred Files (Priority: P2)

After files are transferred, the user can create a standalone compression job (or it auto-chains from a transfer job). Each compression job specifies: input files/folder, compression preset (from dropdown), and output location (from favorites or by browsing). The app processes each video file sequentially, showing per-file progress. When all files are compressed, a Slack notification is sent.

**Why this priority**: Compression is the second stage of the pipeline. It can run independently or chained from transfer, delivering significant value by reducing file sizes before NAS upload (which remains manual).

**Independent Test**: Can be tested by creating a compression job pointing at a folder of video files, selecting a preset and output location, and verifying compressed output files are produced correctly.

**Acceptance Scenarios**:

1. **Given** the user creates a compression job, **When** they configure it, **Then** they can select a preset from a dropdown, input folder, and output location (from favorites or browsing)
2. **Given** a compression job starts, **When** processing begins, **Then** per-file progress (percentage, current file name) is displayed in real-time
3. **Given** compression is in progress, **When** the app is closed and re-opened, **Then** the job shows which files were already compressed and can resume from the next unprocessed file
4. **Given** all files compress successfully, **When** the last file finishes, **Then** a Slack notification is sent with a summary (files processed, total size before/after, duration)
5. **Given** compression fails on a file, **When** the error is detected, **Then** the app skips to the next file, logs the error, and includes it in the Slack notification

---

### User Story 3 - Erase SD Cards After Validation (Priority: P3)

After a successful transfer, the user reviews the transfer results (file count, sizes match) and decides to erase the SD cards. They click an "Erase SD Cards" button, confirm in a dialog, and the cards are wiped clean for the next shoot.

**Why this priority**: This is a convenience feature that saves manual formatting time. Lower priority because it's destructive and the team currently handles it manually without major pain.

**Independent Test**: Can be tested by transferring files, verifying them, then erasing an SD card and confirming it's empty.

**Acceptance Scenarios**:

1. **Given** a transfer has completed successfully, **When** the user views the results, **Then** an "Erase SD Cards" button becomes available
2. **Given** the user clicks "Erase SD Cards," **When** the confirmation dialog appears, **Then** the user must explicitly confirm before any erasure begins
3. **Given** the user confirms erasure, **When** the operation completes, **Then** the SD cards are empty and a confirmation message is shown
4. **Given** no transfer has been completed for the inserted cards, **When** the user views the app, **Then** the "Erase SD Cards" button is disabled/hidden

---

### User Story 4 - Monitor Pipeline via Slack (Priority: P2)

The video team receives Slack notifications at key moments: when a transfer starts, completes, or fails; when compression starts, completes, or fails. Each message includes enough context to understand what happened without opening the app.

**Why this priority**: Same priority as compression because it enables the team to walk away from the machine and still stay informed. Core to the "hands-off" value proposition.

**Independent Test**: Can be tested by triggering any pipeline phase and verifying the Slack message arrives in the correct channel with the expected content.

**Acceptance Scenarios**:

1. **Given** a transfer starts, **When** the first file begins copying, **Then** a Slack message is sent: "Transfer started — X files, Y GB total"
2. **Given** a transfer completes, **When** all files are verified, **Then** a Slack message is sent: "Transfer complete — X files, Y GB, took Z minutes"
3. **Given** a phase fails, **When** the error is captured, **Then** a Slack message is sent: "Transfer/Compression FAILED — [file name] — [error detail]"

---

### Edge Cases

- What happens when an SD card is removed mid-transfer?
- What happens when the external HDD is full and cannot accept more files?
- What happens when the external HDD is disconnected during transfer or compression?
- What happens when HandBrake is not installed on the system?
- What happens when no presets exist in the HandBrake config file?
- What happens when the Slack webhook is misconfigured or unreachable?
- What happens when two instances of the app are opened simultaneously?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST detect and list all mounted removable storage devices (SD cards) when the app is opened or refreshed
- **FR-002**: System MUST allow the user to create jobs, each with its own source, destination, and settings (preset, auto-chain option)
- **FR-003**: System MUST process jobs in queue order, copying all video files (.MOV, .MP4) from the job's source to its destination with resume capability on interruption
- **FR-004**: System MUST verify transferred files match the source (size validation at minimum)
- **FR-005**: System MUST read available compression presets from the system and display them in a dropdown
- **FR-006**: System MUST compress video files using the job's selected preset, writing output to the job's configured output location, processing one file at a time
- **FR-007**: System MUST track per-job state (queued, in-progress, completed, failed) and per-file status within each job, persisting across app restarts
- **FR-013**: System MUST allow the user to save frequently used folder paths as "favorites" for quick selection when creating jobs
- **FR-014**: System MUST support optional auto-chaining: when configured on a job, compression starts automatically after transfer completes
- **FR-008**: System MUST display real-time progress for both transfer and compression operations
- **FR-009**: System MUST send Slack notifications at each phase transition (start, complete, fail) with relevant details
- **FR-010**: System MUST allow the user to erase SD cards only after a successful, verified transfer, and only with explicit confirmation
- **FR-011**: System MUST NOT perform any destructive action without explicit user confirmation via a dialog
- **FR-012**: System MUST check for app updates on launch and prompt the user (never auto-update silently)

### Key Entities

- **Job**: A unit of work in the queue with its own configuration (source, destination, preset, auto-chain flag), status (queued/in-progress/completed/failed), and per-file tracking. A job can be transfer-only, compression-only, or transfer-with-auto-chain-compression.
- **Job Queue**: An ordered list of jobs to be processed sequentially, with state persisted across app restarts
- **Source Device**: A detected removable storage device (SD card) with name, path, capacity, and used space
- **Favorite Path**: A user-saved folder path for quick reuse when creating jobs (e.g., frequently used destination or output folders)
- **Preset**: A named HandBrake compression configuration read from the system

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Team can start the full transfer pipeline (insert cards → start transfer) in under 2 minutes of opening the app
- **SC-002**: Interrupted transfers resume from the last incomplete file, not from the beginning
- **SC-003**: Team receives Slack notifications within 30 seconds of each phase transition
- **SC-004**: Zero files are lost or corrupted during transfer (100% verification pass rate)
- **SC-005**: Team spends less than 5 minutes of manual interaction per pipeline run (versus 20+ minutes of babysitting today)
- **SC-006**: No destructive action (erase, delete, overwrite) ever occurs without the user explicitly clicking a confirmation button

## Assumptions

- The external 14TB HDD is connected and mounted before the user starts the app
- SD cards are inserted in the hub and recognized by Windows as removable drives before starting
- The team has already created at least one compression preset in HandBrake
- A Slack incoming webhook URL has been configured in the app settings
- Only one person operates the app at a time on the video production machine
- The app runs on a single machine (no multi-user or networked access)
- Internet connectivity is available for Slack notifications (but pipeline runs even without it — notifications are best-effort)
