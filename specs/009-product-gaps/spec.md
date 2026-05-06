# Feature Specification: High-Priority Product Gaps

**Feature Branch**: `009-product-gaps`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Fix 6 high-priority product/UX gaps from the v2.0.0 PM review — progress wiring, logging, single-instance lock, Slack banner, onboarding, and repo placeholder"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Progress bar shows transfer speed, ETA, and current filename (Priority: P1)

The operator starts a transfer or compression job and watches the detail screen. They expect to see the current file being processed, the transfer speed (MB/s), and an estimated time remaining — not just a percentage and file count. This is the #1 adoption risk: TeraCopy (the tool being replaced) shows this information by default.

**Why this priority**: Without speed and ETA, the operator has no way to judge whether a transfer is healthy or stalled. They lose visibility they had with TeraCopy, making the new tool feel like a downgrade.

**Independent Test**: Start a transfer job with multiple files. Observe the detail screen. Verify the progress bar shows the current filename, speed in MB/s (or FPS for compression), and estimated time remaining — all updating in real time.

**Acceptance Scenarios**:

1. **Given** a transfer job is in progress, **When** the operator views the job detail screen, **Then** the progress bar displays the current filename being transferred, the speed in MB/s, and the estimated time remaining.
2. **Given** a compression job is in progress, **When** the operator views the detail screen, **Then** the progress bar displays the current filename, encoding speed (FPS), and estimated time remaining.
3. **Given** the transfer speed fluctuates, **When** the progress bar updates, **Then** the ETA adjusts smoothly without erratic jumps.
4. **Given** a job is queued but not yet started, **When** the operator views the detail screen, **Then** no speed or ETA is shown — only "Waiting."

---

### User Story 2 - Operations are logged to a local file (Priority: P1)

The operator or team lead needs to review what happened during an overnight batch run. They open a local log file and see timestamped entries for every significant event: job started, file transferred, file failed, compression complete, Slack notification sent or failed, app launched, app closed.

**Why this priority**: Without a local log, Slack is the only record. If the webhook is misconfigured or the network is down, there's zero visibility into what happened. Debugging becomes guesswork.

**Independent Test**: Run a transfer job. Open the log file. Verify it contains timestamped entries for job start, each file transfer (success or fail), and job completion.

**Acceptance Scenarios**:

1. **Given** a transfer job completes, **When** the operator opens the log file, **Then** it contains timestamped entries for: job started, each file transferred (with source and destination), verification result, and job completed.
2. **Given** a Slack notification fails to send, **When** the operator checks the log, **Then** the failure is recorded with the error details.
3. **Given** the app has been running for weeks, **When** the log file grows, **Then** it rotates or limits size to prevent filling the disk.
4. **Given** the operator launches the app, **When** they look for the log, **Then** it is in a predictable, easily accessible location.

---

### User Story 3 - Only one instance of the app can run at a time (Priority: P2)

The operator accidentally double-clicks the app shortcut, launching two instances. The second instance detects the first is already running, shows a clear message, and exits — preventing database corruption from concurrent access.

**Why this priority**: Two instances sharing the same SQLite file can cause lock contention, corrupted writes, and job processing conflicts. This is a silent data corruption risk.

**Independent Test**: Launch the app. While it's running, launch a second instance. Verify the second instance shows an error message and exits without touching the database.

**Acceptance Scenarios**:

1. **Given** the app is already running, **When** the operator launches a second instance, **Then** the second instance displays a message explaining another instance is already running and exits.
2. **Given** the app crashes (lock file left behind), **When** the operator launches the app again, **Then** the stale lock is detected and cleaned up, allowing the app to start normally.
3. **Given** the app is closed normally, **When** the lock file is checked, **Then** it has been cleaned up.

---

### User Story 4 - Banner warns when Slack webhook is not configured (Priority: P2)

The operator creates jobs and starts the queue but never configured the Slack webhook URL. A persistent banner on the home screen warns them that Slack notifications are disabled, with a quick link to settings.

**Why this priority**: Without this banner, the operator assumes Slack is working. They walk away trusting they'll get notified, but no notifications are ever sent.

**Independent Test**: Clear the Slack webhook URL in settings. Return to the home screen. Verify a persistent banner appears. Configure the URL. Verify the banner disappears.

**Acceptance Scenarios**:

1. **Given** the Slack webhook URL is empty, **When** the operator views the home screen, **Then** a persistent banner warns that Slack notifications are disabled.
2. **Given** the banner is showing, **When** the operator taps it, **Then** they are taken to the settings screen.
3. **Given** the operator configures a valid webhook URL, **When** they return to the home screen, **Then** the banner is gone.

---

### User Story 5 - First-run guidance helps new users get started (Priority: P2)

The operator launches the app for the first time. Instead of an empty queue with no context, they see a welcome state that explains what the app does, suggests inserting an SD card to start, and prompts them to configure Slack in settings.

**Why this priority**: An empty screen with no guidance is confusing for non-technical video editors. A clear welcome state reduces the time to first successful transfer.

**Independent Test**: Launch the app with a fresh database (no jobs, no settings configured). Verify a welcome/guidance state appears. Create the first job. Verify the guidance disappears and the normal queue view shows.

**Acceptance Scenarios**:

1. **Given** the app is launched for the first time (`firstRunCompleted` flag is false), **When** the operator sees the home screen, **Then** a welcome state explains the app's purpose and suggests next steps (insert SD card, configure Slack).
2. **Given** the welcome state is showing, **When** the operator creates their first job or dismisses the welcome, **Then** the `firstRunCompleted` flag is set and the welcome state is replaced by the normal queue view.
3. **Given** the `firstRunCompleted` flag is true, **When** the operator launches the app (even with an empty queue), **Then** no welcome state is shown — the normal queue view appears.

---

### User Story 6 - Update check works with the correct repository (Priority: P2)

The operator launches the app and the auto-update check runs. It should correctly query the actual GitHub repository for new releases instead of silently failing with a 404 due to a placeholder repository name.

**Why this priority**: The update mechanism was designed to keep the team on the latest version. A placeholder URL means it never actually works, and the operator thinks they're up to date when they might not be.

**Independent Test**: Launch the app with update checking enabled. Verify the update check queries the correct repository. If a newer release exists, verify the update prompt appears.

**Acceptance Scenarios**:

1. **Given** update checking is enabled, **When** the app launches, **Then** it checks the correct repository for new releases.
2. **Given** a newer release exists on the repository, **When** the check completes, **Then** the operator is prompted to update.
3. **Given** the repository is unreachable (offline), **When** the check fails, **Then** the app continues normally without crashing.

---

### Edge Cases

- What happens when the transfer speed drops to zero (stalled)? The progress bar should show "Stalled" instead of an infinite ETA.
- What happens when the log file is locked by another process (e.g., user has it open in Notepad)? Logging should degrade gracefully without crashing.
- What happens when the lock file is on a read-only filesystem? The app should still launch with a warning, not crash.
- What happens when the Slack webhook is configured but invalid (wrong URL format)? The banner should not show — it only checks for empty.
- What happens when a user has jobs in the database but they are all completed/failed? The welcome state does NOT show — it is controlled by the `firstRunCompleted` flag, not by job count.
- What happens when the operator deletes all jobs from history? The welcome state does NOT reappear — `firstRunCompleted` is permanent.

## Clarifications

### Session 2026-05-06

- Q: Where should the log file be located? → A: Same directory as the executable (e.g., `D:\Copiatorul3000\copiatorul3000.log`). Most accessible for non-technical operators.
- Q: How should stale lock files be detected? → A: Write PID to lock file. On startup, read PID and check if that process is still running. If not, treat as stale and clean up automatically.
- Q: What triggers the first-run welcome state? → A: A `firstRunCompleted` flag in settings. Show welcome only once. Once dismissed or first job created, set the flag and never show again.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The job detail screen MUST display the current filename, transfer/encoding speed, and estimated time remaining during active transfer and compression jobs, updating in real time.
- **FR-002**: The system MUST write timestamped log entries to a local file for every significant event (job lifecycle, file operations, Slack notifications, errors, app start/stop).
- **FR-003**: The system MUST prevent multiple instances from running simultaneously by detecting an existing instance and showing a clear error message.
- **FR-004**: The home screen MUST show a persistent banner when the Slack webhook URL is empty, linking to settings for configuration.
- **FR-005**: The home screen MUST show a welcome/guidance state when no jobs exist in the database (first launch or empty history), explaining the app's purpose and suggesting next steps.
- **FR-006**: The update check MUST use the correct GitHub repository URL so that version checks succeed and the operator is prompted when updates are available.

### Key Entities

- **ProgressData**: Real-time progress information for a running job — current filename, speed (bytes/sec or FPS), estimated time remaining.
- **LogEntry**: A timestamped record of a significant event with category (info, warning, error) and message.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: During active transfers, the operator sees current filename, speed (MB/s), and ETA — matching or exceeding the information density of the tool being replaced.
- **SC-002**: Every significant event is recorded in a local log file with a timestamp, accessible at a predictable location.
- **SC-003**: Launching a second instance always shows an error and exits — zero cases of concurrent database access.
- **SC-004**: 100% of operators with an empty Slack webhook see the configuration banner on the home screen.
- **SC-005**: First-time users see guidance within 1 second of app launch — no blank empty state.
- **SC-006**: The update check successfully queries the correct repository and prompts when a new version is available.

## Assumptions

- The progress bar widget (`PipelineProgressBar`) already supports displaying speed, ETA, and filename — it just needs the data piped in from services.
- The log file is located in the same directory as the executable (e.g., `D:\Copiatorul3000\copiatorul3000.log`).
- Log rotation is handled by size limit (e.g., 10 MB max) with the oldest entries trimmed.
- The single-instance lock uses a PID-based lock file in the same directory as the executable. On startup, if a lock file exists, the app reads the PID and checks if that process is still running. Stale locks are cleaned up automatically.
- The welcome state is controlled by a `firstRunCompleted` boolean flag in settings. Once set to true (on first job creation or dismissal), it never shows again — even if all jobs are later deleted.
- The welcome state replaces the existing empty-queue state in the home screen — it's not a separate screen or dialog.
- The Slack banner checks only for an empty webhook URL, not for URL validity or reachability.
