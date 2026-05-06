# Feature Specification: Polish & Code Quality

**Feature Branch**: `005-polish-code-quality`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "19 polish and code quality items identified during architecture and UX review"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Code Deduplication and Consistency (Priority: P1)

A developer working on the codebase finds that common operations (formatting file sizes, getting job type labels, getting status colors, streaming subprocess output) are defined in one place and reused everywhere. There are no duplicated switch statements, no copy-pasted formatting logic, and no inconsistent representations of the same data across different screens.

**Why this priority**: Duplicated code leads to bugs when one copy is updated but another is forgotten. This is the foundation for maintainability.

**Independent Test**: Search the codebase for file size formatting — verify it appears only in the shared utility. Search for job type label switches — verify only the extension method exists.

**Acceptance Scenarios**:

1. **Given** any screen displays a file size, **When** the formatting logic is traced, **Then** it calls a single shared formatting function
2. **Given** any screen displays a job type label, **When** the label logic is traced, **Then** it calls a single shared extension method
3. **Given** any screen displays a job status with color, **When** the mapping is traced, **Then** it uses a single shared extension method
4. **Given** transfer or compression services stream subprocess output, **When** the streaming logic is traced, **Then** both use a shared utility for process output handling
5. **Given** any code references video file extensions, **When** the extensions are traced, **Then** they come from the shared constants (not hardcoded)

---

### User Story 2 - Desktop Power User Features (Priority: P2)

A video team member who uses the app daily can operate it efficiently using keyboard shortcuts. They press Ctrl+N to create a new job, Ctrl+Enter to start the queue, and Delete to remove a selected job. They can right-click a job card to get a context menu with quick actions (View Details, Delete, Retry). The queue can be reordered by dragging jobs up and down. When the app is minimized, a system tray icon shows progress.

**Why this priority**: These are quality-of-life features for daily desktop use. They don't change functionality but significantly improve efficiency for repeat users.

**Independent Test**: Press Ctrl+N — verify create job opens. Right-click a job — verify context menu appears. Drag a job in the queue — verify it reorders. Minimize the app — verify system tray icon with progress.

**Acceptance Scenarios**:

1. **Given** the app is focused, **When** the user presses Ctrl+N, **Then** the create job panel opens
2. **Given** the app is focused, **When** the user presses Ctrl+Enter, **Then** queue processing starts or stops
3. **Given** a job is selected, **When** the user presses Delete, **Then** a confirmation dialog appears to remove it
4. **Given** a job card is visible, **When** the user right-clicks it, **Then** a context menu shows: View Details, Delete, Retry (if failed)
5. **Given** multiple queued jobs exist, **When** the user drags a job card up or down, **Then** the queue order updates
6. **Given** the app is minimized, **When** a job is processing, **Then** a system tray icon shows progress status
7. **Given** the app is minimized, **When** a job completes or fails, **Then** the system tray shows a notification

---

### User Story 3 - Visual Polish and Terminology (Priority: P2)

The app uses consistent, meaningful colors for statuses — defined once and used everywhere. The "Both" label in the job type selector is renamed to "Copy & Compress" for clarity. The FAB (floating action button) is removed since "New Job" is already in the toolbar. The first job creation includes a hint about starting the queue. Drive refresh shows a completion message.

**Why this priority**: Visual consistency and clear terminology reduce confusion for non-technical users and make the app feel professional.

**Independent Test**: Check all status colors across screens — verify they match. Read the job type selector — verify "Copy & Compress" label. Create a first job — verify hint about queue start.

**Acceptance Scenarios**:

1. **Given** any screen shows a status color, **When** compared across screens, **Then** the same status always uses the same color (defined centrally)
2. **Given** the create job screen is open, **When** the user views the job type selector, **Then** the third option reads "Copy & Compress" (not "Both")
3. **Given** jobs exist in the queue, **When** the user views the home screen, **Then** there is no floating action button (New Job is in the toolbar)
4. **Given** the user creates their first job, **When** the snackbar appears, **Then** it says "Job added to queue. Press Start to begin processing"
5. **Given** the user refreshes the drive list, **When** the scan completes, **Then** a message shows how many drives were found (or "no drives found")

---

### User Story 4 - Security and Stability Hardening (Priority: P1)

The app validates drive paths before executing erase commands to prevent command injection. The update check on startup is wrapped in error handling so it cannot crash the app. The settings screen saves changes only when the user finishes typing (not on every keystroke). The job detail screen watches a single job efficiently instead of loading all jobs and filtering.

**Why this priority**: Security (command injection prevention) and stability (crash prevention) are foundational. Performance (efficient queries) prevents slowdowns as the job count grows.

**Independent Test**: Attempt to erase with a malformed drive path — verify it's rejected. Kill the network before app launch — verify the app starts normally despite update check failure. Type rapidly in settings — verify database writes are batched.

**Acceptance Scenarios**:

1. **Given** an erase operation is requested, **When** the drive path does not match a valid drive letter pattern, **Then** the operation is blocked with an error
2. **Given** the app launches, **When** the update check fails (network error, database not ready), **Then** the app continues normally without crashing
3. **Given** the user types in the webhook URL field, **When** they stop typing for 500ms, **Then** the value is saved to the database (not on every keystroke)
4. **Given** the job detail screen is open, **When** it watches for changes, **Then** it queries only the single job by ID (not all jobs)

---

### Edge Cases

- What happens if keyboard shortcuts conflict with system shortcuts?
- What happens if the system tray icon fails to initialize (e.g., no system tray on the OS)?
- What happens if the user drags a job that is currently being processed?

## Requirements *(mandatory)*

### Functional Requirements

**Code Quality:**
- **FR-001**: All file size formatting MUST use a single shared utility function
- **FR-002**: All job type labels MUST use a single shared extension method
- **FR-003**: All job status labels and colors MUST use a single shared extension method
- **FR-004**: Subprocess output streaming MUST use a shared utility (process start, stdout/stderr listen, line parse, callback)
- **FR-005**: All video extension references MUST use the shared constants

**Desktop UX:**
- **FR-006**: System MUST support keyboard shortcuts: Ctrl+N (new job), Ctrl+Enter (start/stop queue), Delete (remove selected job)
- **FR-007**: System MUST show a right-click context menu on job cards with: View Details, Delete, Retry (if failed)
- **FR-008**: System MUST support drag-to-reorder for queued jobs
- **FR-009**: System MUST show a system tray icon with progress when minimized
- **FR-010**: System MUST remove the floating action button (New Job is in the toolbar)

**Visual Polish:**
- **FR-011**: All status colors MUST be defined centrally and referenced everywhere (no hardcoded color values in screen files)
- **FR-012**: The job type selector MUST label the third option as "Copy & Compress" (not "Both")
- **FR-013**: First job creation MUST show a hint about starting the queue
- **FR-014**: Drive refresh MUST show a completion message with result count

**Security & Stability:**
- **FR-015**: System MUST validate drive paths against a drive letter pattern before executing erase commands
- **FR-016**: The update check on app startup MUST be wrapped in error handling (never crash the app)
- **FR-017**: The webhook URL setting MUST use debounced saving (500ms delay after last keystroke)
- **FR-018**: The job detail screen MUST watch a single job by ID (not filter all jobs)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero duplicated formatting/label/color logic across the codebase — each pattern defined exactly once
- **SC-002**: Power users can perform all common actions (create, start, delete) without touching the mouse
- **SC-003**: 100% of status colors are consistent across all screens and widgets
- **SC-004**: Zero command injection risk — all external command inputs validated
- **SC-005**: App startup succeeds 100% of the time regardless of network status or database state

## Assumptions

- System tray support uses a community package (e.g., `system_tray` or `tray_manager`) — if unavailable on the target Windows version, this feature degrades gracefully
- Drag-to-reorder updates the job queue order in the database (requires a sort-order column or re-insertion)
- Keyboard shortcuts use standard desktop conventions and do not conflict with OS-level shortcuts
- The ProcessRunner utility is an internal refactor — no change to external behavior
- The global database wrapper is an internal refactor for testability — no change to app behavior
