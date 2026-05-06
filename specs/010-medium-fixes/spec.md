# Feature Specification: Medium-Priority Fixes

**Feature Branch**: `010-medium-fixes`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Fix 9 medium-priority nice-to-have issues from the v2.0.0 review (QA-15 already fixed)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Last-used destination auto-fills on next job (Priority: P1)

The operator creates a transfer job and picks `D:\Footage` as the destination. Next time they create a job, the destination field already shows `D:\Footage` — no need to browse again or use favorites.

**Why this priority**: Most shoots go to the same destination. Eliminating the most repetitive click saves time on every single job.

**Independent Test**: Create a job with a destination folder. Close the job creation form. Open it again. Verify the destination field is pre-filled with the last-used path.

**Acceptance Scenarios**:

1. **Given** the operator creates a transfer job with destination `D:\Footage`, **When** they open the job creation form again, **Then** the destination field is pre-filled with `D:\Footage`.
2. **Given** the operator creates a compression job with output `D:\Compressed`, **When** they open the form for another compression job, **Then** the output field is pre-filled with `D:\Compressed`.
3. **Given** the app is restarted, **When** the operator opens the form, **Then** the last-used destination from the previous session persists.

---

### User Story 2 - Operator name appears on jobs and Slack messages (Priority: P1)

The team lead needs to know who initiated a transfer. The operator sets their name once in settings, and it appears on every Slack notification and in job history — "Operator: Alex."

**Why this priority**: Without operator tracking, the team lead must ask around to find who copied what. This is essential for accountability on shared workstations.

**Independent Test**: Set "Alex" as operator name in settings. Create and run a job. Check the Slack notification includes "Operator: Alex."

**Acceptance Scenarios**:

1. **Given** the operator has set their name to "Alex" in settings, **When** a transfer job sends a Slack notification, **Then** the notification includes "Operator: Alex."
2. **Given** no operator name is configured, **When** a Slack notification is sent, **Then** the operator field is omitted (not shown as empty).
3. **Given** the operator name is configured, **When** viewing job details, **Then** the operator name is visible.

---

### User Story 3 - Export job history as CSV (Priority: P2)

The team lead clicks "Export History" on the home screen and gets a CSV file with all completed and failed jobs — dates, file counts, sizes, statuses. They open it in Excel for a weekly report.

**Why this priority**: No way to generate reports without this. The team lead currently copies data manually from Slack messages.

**Independent Test**: Complete 3 jobs. Click "Export History." Verify a CSV file is saved with correct data for all 3 jobs.

**Acceptance Scenarios**:

1. **Given** the history contains 5 completed jobs, **When** the operator clicks "Export History," **Then** a CSV file is saved containing one row per job with: date, type, source, destination, file count, total size, status, duration, operator name.
2. **Given** the operator clicks export, **When** they choose a save location, **Then** the file is saved with a timestamped filename (e.g., `copiatorul3000-history-2026-05-06.csv`).
3. **Given** the history is empty, **When** the operator clicks export, **Then** a message says "No history to export."

---

### User Story 4 - History cards show when jobs ran (Priority: P2)

Job cards in the history section show relative timestamps — "2 hours ago," "Yesterday," "May 3." The operator can quickly see recent activity without opening each job.

**Why this priority**: Without timestamps, the history is just a list of names with no sense of when things happened.

**Independent Test**: Complete a job. Check the history card. Verify it shows a relative timestamp like "Just now" or "1 minute ago."

**Acceptance Scenarios**:

1. **Given** a job completed 5 minutes ago, **When** the operator views the history, **Then** the card shows "5 minutes ago."
2. **Given** a job completed yesterday, **When** the operator views the history, **Then** the card shows "Yesterday."
3. **Given** a job completed 3 days ago, **When** the operator views the history, **Then** the card shows "May 3" (absolute date).

---

### User Story 5 - Favorite label uses correct path parsing (Priority: P3)

The operator saves a folder as a favorite. The label auto-fills with the last folder name from the path — correctly, regardless of whether the path uses forward or backslashes.

**Why this priority**: During development on macOS, paths use forward slashes. The current code splits on backslash only, producing an incorrect label.

**Independent Test**: Save a favorite with path `/Users/test/footage`. Verify the label auto-fills as "footage," not the full path.

**Acceptance Scenarios**:

1. **Given** a path `D:\Footage\2026`, **When** the operator saves as favorite, **Then** the label auto-fills as "2026."
2. **Given** a path `/Users/test/footage`, **When** the operator saves as favorite on macOS, **Then** the label auto-fills as "footage."

---

### User Story 6 - Erase accepts lowercase drive letters (Priority: P3)

The operator types or pastes a lowercase drive letter (e.g., `d:\`) in the erase confirmation. The system accepts it and proceeds — not rejecting it silently.

**Why this priority**: Minor usability issue. Unlikely in practice (UI provides the path), but a defensive fix.

**Independent Test**: Attempt to erase a drive using a lowercase letter path. Verify the operation proceeds.

**Acceptance Scenarios**:

1. **Given** a drive path `d:\`, **When** the erase function validates it, **Then** it is accepted as valid.
2. **Given** a drive path `D:\`, **When** validated, **Then** it is also accepted (uppercase still works).

---

### User Story 7 - Warning when file paths approach Windows limit (Priority: P3)

During job creation, if any file's full destination path would exceed the Windows 260-character limit, the operator sees a warning before submitting.

**Why this priority**: Silent robocopy failure due to path length is hard to debug. A proactive warning saves hours of troubleshooting.

**Independent Test**: Create a job with a very long destination path (>200 characters). Add files with long names. Verify a warning appears.

**Acceptance Scenarios**:

1. **Given** a destination path + filename totaling 270 characters, **When** the operator creates a job, **Then** a warning dialog lists the files that would exceed 260 characters.
2. **Given** all paths are under 260 characters, **When** the operator creates a job, **Then** no warning appears.
3. **Given** the warning is shown, **When** the operator dismisses it, **Then** they can still proceed with the job (warning, not blocking).

---

### User Story 8 - Disk space shows "N/A" when unavailable (Priority: P3)

The disk space display shows "N/A" instead of "0 B" when the system can't determine free space (e.g., network drive, error).

**Why this priority**: "0 B" is misleading — the operator might think the drive is full when it's actually just unreadable.

**Independent Test**: Select a destination where disk space detection fails. Verify the display shows "N/A" instead of "0 B."

**Acceptance Scenarios**:

1. **Given** disk free space returns -1 (failure), **When** the UI displays it, **Then** it shows "N/A" instead of "0 B."
2. **Given** disk free space returns 0 (genuinely empty), **When** displayed, **Then** it shows "0 B" (real zero is still shown).

---

### Edge Cases

- What happens when the last-used destination folder has been deleted? The field pre-fills but the path no longer exists. The folder picker validates on job creation.
- What happens when the operator name contains special characters (e.g., emoji, quotes)? It should be stored and displayed as-is.
- What happens when exporting CSV with no completed jobs? Show a message, don't create an empty file.
- What happens when the relative timestamp crosses midnight? It should switch from "X hours ago" to "Yesterday."

## Clarifications

### Session 2026-05-06

- Q: Should selective file copy (PM-10) be included in this batch or deferred? → A: Defer to v3.0 as a standalone feature. This batch stays focused on quick wins (8 fixes).
- Q: Where should operator name be stored — on the job or read from settings? → A: Stamp on the Job record at creation time. Add `operatorName` column to Jobs table. Old jobs preserve the name even if operator changes later.
- Q: How does the operator save the CSV export? → A: Native file save dialog (same pattern as folder picker). Operator picks location and filename, with a sensible default.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST remember the last-used destination (and compression output) path and pre-fill it in the job creation form on subsequent uses, persisting across sessions.
- **FR-002**: System MUST allow the operator to set their name in settings, and include it in all Slack notifications and job metadata.
- **FR-003**: System MUST provide an "Export History" function that generates a CSV file containing all completed and failed jobs with key details.
- **FR-004**: History job cards MUST display relative timestamps showing when each job completed.
- **FR-005**: The favorite label auto-fill MUST correctly parse the last folder name from both forward-slash and backslash paths.
- **FR-006**: The drive erase validation MUST accept both uppercase and lowercase drive letters.
- **FR-007**: System MUST warn the operator during job creation if any file's destination path would exceed 260 characters.
- **FR-008**: The disk space display MUST show "N/A" when the system cannot determine free space (negative return value), and "0 B" only for genuinely zero space.

### Key Entities

- **AppSettings**: Extended with `lastUsedDestination`, `lastUsedOutput`, and `operatorName` fields.
- **Job**: Extended with `operatorName` column — stamped at creation time from the current settings value. Preserved in history even if the operator name changes later.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Last-used destination is pre-filled 100% of the time after the first job, across app restarts.
- **SC-002**: Operator name appears in every Slack notification when configured.
- **SC-003**: CSV export contains accurate data for all jobs in history, openable in Excel without formatting issues.
- **SC-004**: Every history card shows a relative timestamp that is accurate within 1 minute.
- **SC-005**: Favorite labels auto-fill correctly on both Windows and macOS paths.
- **SC-006**: Lowercase drive letters are accepted for erase operations.
- **SC-007**: Path length warnings appear for 100% of files exceeding 260 characters.
- **SC-008**: "N/A" is displayed instead of "0 B" when disk space is unavailable.

## Assumptions

- Last-used destination is stored in AppSettings (same pattern as other settings). Requires schema migration (v3→v4) to add columns.
- Operator name is stored in AppSettings and stamped on the Job record at creation time (not retroactively).
- CSV export uses a simple file save dialog to let the operator choose the save location.
- Relative timestamps use simple rules: <1h = "X min ago", <24h = "X hours ago", <48h = "Yesterday", else absolute date.
- Selective file copy (PM-10) is deferred to v3.0 — not included in this spec.
- The path length check happens after file enumeration during job creation, before inserting into the database.
