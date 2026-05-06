# Feature Specification: High-Priority QA Bug Fixes

**Feature Branch**: `008-high-priority-qa-fixes`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Fix 8 high-priority QA bugs from the v2.0.0 review affecting reliability, data accuracy, and error handling"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Queue processes only one job at a time under rapid interaction (Priority: P1)

The operator rapidly clicks the Start button twice or triggers queue processing from multiple UI paths. The system must ensure only one processing loop runs at a time — never two concurrent loops processing the same or different jobs simultaneously.

**Why this priority**: Two concurrent loops can process the same job twice, causing duplicate file transfers, double Slack notifications, and corrupted progress tracking. This is a data integrity and reliability issue.

**Independent Test**: Rapidly call the start processing action twice in quick succession. Verify only one processing loop starts and only one job is picked up.

**Acceptance Scenarios**:

1. **Given** the queue is idle with 2 jobs queued, **When** the operator triggers start processing twice in rapid succession, **Then** only one processing loop runs and jobs are processed sequentially.
2. **Given** the queue is already processing, **When** start processing is called again, **Then** the second call is ignored with no side effects.

---

### User Story 2 - Chained compression shows accurate progress (Priority: P1)

After a transfer-and-compress job completes its transfer phase, the system automatically creates a compression job. The operator expects to see accurate progress on the compression job (e.g., "0/12 files") — not "0/0 files."

**Why this priority**: Showing 0/0 progress makes the operator think the compression job is empty or broken, eroding trust in the auto-chain feature.

**Independent Test**: Create a transfer-and-compress job with multiple files. Let the transfer complete and observe the auto-created compression job. Verify it shows the correct total file count and total bytes.

**Acceptance Scenarios**:

1. **Given** a transfer-and-compress job completes its transfer phase with 12 verified files, **When** the chained compression job is created, **Then** the compression job shows "0/12 files" and the correct total byte count.

---

### User Story 3 - Cannot create a compression job without selecting a preset (Priority: P1)

The operator selects "Compress" or "Copy & Compress" as the job type but forgets to pick a preset from the dropdown. The "Add to Queue" button must remain disabled until a preset is selected.

**Why this priority**: Submitting without a preset sends an empty string to the compression tool, which either fails silently or produces unexpected output.

**Independent Test**: Select a compression job type, leave the preset dropdown unselected, and verify the submit button is disabled.

**Acceptance Scenarios**:

1. **Given** the operator selects "Compress" as the job type, **When** no preset is selected, **Then** the "Add to Queue" button is disabled.
2. **Given** the operator selects "Copy & Compress," **When** they select a preset, **Then** the "Add to Queue" button becomes enabled.
3. **Given** the operator selects "Transfer" as the job type, **When** no preset is selected, **Then** the button is still enabled (presets are irrelevant for transfer-only jobs).

---

### User Story 4 - Drag-to-reorder moves the correct job (Priority: P1)

The operator drags a job card in the queue to reorder it. The job they dragged must end up in the expected position — not a different job that happens to share the same index in a different list.

**Why this priority**: Moving the wrong job silently corrupts the queue order. The operator doesn't notice until a job runs out of sequence, potentially wasting hours of processing time.

**Independent Test**: Queue 5 jobs, filter to show only active jobs. Drag job #3 to position #1. Verify that the correct job moved and the database reflects the new order.

**Acceptance Scenarios**:

1. **Given** 5 active jobs in the queue, **When** the operator drags job #3 to position #1, **Then** job #3 moves to position #1 and all other jobs shift accordingly.
2. **Given** a mix of active and completed jobs, **When** the operator reorders active jobs, **Then** only active job positions change — completed jobs are unaffected.

---

### User Story 5 - Retry resets progress to zero (Priority: P2)

A job fails partway through. The operator clicks "Retry." The progress bar and counters must start fresh from 0 — not carry over the previous run's completed count.

**Why this priority**: Stale progress after retry confuses the operator about actual progress. They may think files are already done when they haven't been reprocessed.

**Independent Test**: Run a job that fails at file 5/10. Retry the job. Verify the progress shows 0/10 (with the 5 previously completed files still marked as completed and skipped on re-run).

**Acceptance Scenarios**:

1. **Given** a failed job with 5/10 files completed, **When** the operator retries the job, **Then** the job's completed files counter resets to 0 and completed bytes resets to 0.
2. **Given** a retried job starts processing, **When** it encounters files already marked completed, **Then** those files are skipped and the counter increments correctly from 0.

---

### User Story 6 - Context menu retry actually works (Priority: P2)

The operator right-clicks a failed job card and selects "Retry" from the context menu. The job must be retried — not silently ignored.

**Why this priority**: A non-functional menu option is worse than no option at all. The operator believes they triggered a retry but nothing happens.

**Independent Test**: Right-click a failed job, select "Retry." Verify the job status changes to "queued" and it can be processed again.

**Acceptance Scenarios**:

1. **Given** a failed job in the queue, **When** the operator right-clicks and selects "Retry," **Then** the job is reset and re-queued for processing.
2. **Given** a completed job, **When** the operator right-clicks, **Then** the "Retry" option is not available (only failed jobs can be retried).

---

### User Story 7 - App doesn't crash when settings are missing (Priority: P2)

The operator launches the app for the first time or after a database reset. The settings screen and any feature that reads settings must work without crashing — even if the settings row doesn't exist yet.

**Why this priority**: A crash on first launch is the worst possible first impression. The operator may think the app is broken and never try again.

**Independent Test**: Delete the settings row from the database. Launch the app or navigate to the settings screen. Verify no crash occurs and default values are shown.

**Acceptance Scenarios**:

1. **Given** no settings row exists in the database, **When** the app reads settings, **Then** it returns sensible default values without crashing.
2. **Given** no settings row exists, **When** the operator opens the settings screen, **Then** default values are displayed and the operator can save new settings.
3. **Given** settings are being watched for live updates, **When** the settings row is missing, **Then** the stream emits default values instead of throwing an error.

---

### User Story 8 - File scanning handles errors gracefully (Priority: P2)

The operator starts a scan on an SD card. During scanning, a directory is access-denied (permissions) or the card is physically removed. The app must handle this gracefully — reporting the error to the operator instead of crashing.

**Why this priority**: SD cards can be flaky (bad sectors, sudden removal). A crash during scanning forces the operator to restart the app and try again.

**Independent Test**: Simulate a directory with access-denied permissions inside a source path. Run the file scanner. Verify the app reports an error message instead of crashing.

**Acceptance Scenarios**:

1. **Given** a source path with an access-denied subdirectory, **When** the file scanner encounters it, **Then** the error is caught, the inaccessible directory is skipped, scanning continues, and after scanning completes a blocking dialog lists all skipped paths.
2. **Given** an SD card is removed during scanning, **When** the stream encounters an I/O error, **Then** scanning stops and the app shows a blocking dialog with the error details. The operator must dismiss it before proceeding.

---

### Edge Cases

- What happens when startProcessing is called from a keyboard shortcut and UI button simultaneously? Only one loop starts.
- What happens when a chained compression job has 0 verified files (all transfer files failed)? The compression job should not be created.
- What happens when the preset list is empty (HandBrake not installed)? The submit button stays disabled for compression jobs.
- What happens when all jobs in the filtered list are completed (none to reorder)? The reorder UI should be hidden or disabled.
- What happens when the settings row is created after the watch stream starts? The stream should pick up the new row automatically.

## Clarifications

### Session 2026-05-06

- Q: How should filesystem scan errors be reported to the operator? → A: Show a blocking dialog listing all skipped/inaccessible paths. The operator must dismiss it before proceeding.
- Q: Should retry reset all files or only failed ones? → A: Reset failed files to pending, keep completed files as-is (skip on re-run). Only fix the job-level counters. SHA-256 verification is a separate future feature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST ensure only one queue processing loop can run at a time, regardless of how rapidly or from how many paths the start action is triggered.
- **FR-002**: System MUST record the correct total file count and total bytes on auto-created chained compression jobs immediately after creating them.
- **FR-003**: System MUST prevent submission of compression or copy-and-compress jobs when no preset is selected.
- **FR-004**: System MUST use job identifiers (not list indices) when reordering queue items, ensuring the correct job is moved regardless of list filtering.
- **FR-005**: System MUST reset completed file count and completed byte count to zero when a job is retried.
- **FR-006**: System MUST handle the "Retry" action from the job card context menu, re-queuing the failed job for processing.
- **FR-007**: System MUST gracefully handle missing settings by returning default values instead of crashing, both for one-time reads and live-updating streams.
- **FR-008**: System MUST catch and handle filesystem errors during file scanning (access denied, I/O errors) without crashing, skipping inaccessible paths and continuing where possible. After scanning, if any paths were skipped, the system MUST show a blocking dialog listing the skipped paths that the operator must dismiss before proceeding.

### Key Entities

- **Job**: Queue item with status, progress counters (completedFiles, completedBytes, totalFiles, totalBytes), and sort order.
- **AppSettings**: Singleton configuration row that may not exist on first launch.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero duplicate processing loops can run concurrently, regardless of rapid or concurrent start triggers.
- **SC-002**: Every auto-created chained compression job shows accurate file count and byte totals from creation.
- **SC-003**: The job creation form blocks submission 100% of the time when a required preset is missing.
- **SC-004**: Drag-to-reorder moves the correct job in 100% of cases, even when the displayed list is filtered.
- **SC-005**: After retry, progress counters always start at zero — no stale data from previous runs.
- **SC-006**: Context menu "Retry" successfully re-queues the job in 100% of invocations on failed jobs.
- **SC-007**: The app never crashes when the settings row is absent — default values are always available.
- **SC-008**: File scanning never crashes on filesystem errors — errors are caught and reported to the operator.

## Assumptions

- The existing `_isProcessing` flag is the correct mechanism for preventing concurrent loops — it just needs to be set synchronously.
- The `updateJobTotals` DAO method already exists and works correctly — it's just not being called for chained compression jobs.
- The `resetJobForRetry` DAO method exists but doesn't currently reset progress counters.
- The `reorderJobs` DAO method currently accepts indices — it needs to be changed to accept job IDs.
- Default settings values (empty webhook URL, update check enabled) are reasonable for first-launch scenarios.
- Skipping inaccessible directories during scanning is preferable to aborting the entire scan.
