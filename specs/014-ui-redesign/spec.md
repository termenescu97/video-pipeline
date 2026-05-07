# Feature Specification: UI/UX Redesign — Visual Hierarchy & Operator Trust

**Feature Branch**: `014-ui-redesign`
**Created**: 2026-05-07
**Status**: Draft
**Input**: Synthesis of two parallel UI/UX review proposals (Opus subagent + Codex subagent), with operator preferences applied

## User Scenarios & Testing

### User Story 1 — Trust at a Glance (Priority: P1)

An operator walks back to the workstation after lunch. From across the room they need to know: are the cards still copying, did everything succeed, or did something fail? Today they have to walk up to the screen and read 11pt grey labels to find out. After the redesign, a single colored state dot in the status bar plus a hero-card treatment of the active job answers that question in under one second.

**Why this priority**: This is the app's core emotional contract — "you can walk away and trust me." Today the visual signal is buried; the redesign makes it the loudest thing on screen. Without this, every other refinement is a polish on a foundation that doesn't say what's happening.

**Independent Test**: Stand 3 meters from the screen during an active transfer. Without reading any text, identify whether the queue is running, idle, or in trouble. Repeat after a job completes successfully and after a job fails.

**Acceptance Scenarios**:

1. **Given** the queue is actively transferring, **When** an operator glances at the status bar, **Then** they see a blue state dot and queue summary including the time-of-day completion estimate (e.g., "RUNNING — 2 of 3, done by 18:14").
2. **Given** all queued jobs completed successfully in the last few minutes, **When** an operator looks at the status bar, **Then** they see a green state dot and a brief celebration cue in the active-job slot of the queue ("All cards copied & verified").
3. **Given** one or more jobs have failed, **When** an operator looks at the status bar, **Then** they see a red state dot, a queue summary indicating attention is needed (e.g., "1 failed — review"), and the failed jobs grouped at the top of the queue.
4. **Given** Slack is unconfigured or HandBrake is missing, **When** an operator opens the app, **Then** the status dot is orange and a warning banner is visible on the home screen.
5. **Given** the app is running with no queued jobs, **When** the system tray icon is hovered, **Then** the tooltip mirrors the status bar text rather than showing a static "Idle" string.

---

### User Story 2 — One-Screen Common Path (Priority: P1)

The 80% workflow is "insert SD cards, click Copy All Cards, walk away." Today this requires a series of dialogs (verification mode, then destination, then conflicts after job creation), and the source-drive list lives inside the Create Job form. After the redesign, the persistent left column always shows detected SD cards, and the Copy All Cards flow shows the operator what's detected first, then asks for destination and verification mode in one panel with a plan summary before commit.

**Why this priority**: Speed of the common path is the second-most-important property after trust. An operator who runs this 30 times a week feels every extra click. Today the flow asks "what verification mode?" before showing the cards — that's backwards.

**Independent Test**: Time how long it takes to start a batch copy from "two cards inserted" to "jobs created." It should drop measurably versus the v2.3.0 flow.

**Acceptance Scenarios**:

1. **Given** SD cards are inserted, **When** the operator opens the app, **Then** the left Sources column already shows the detected cards without any user action.
2. **Given** the Sources column shows detected cards, **When** the operator clicks Copy All Cards, **Then** the first thing they see is the list of detected cards with checkboxes (allowing per-card selection), followed by destination, verification mode, and a plan summary line ("Plan: 3 jobs · 290 GB · OK").
3. **Given** the operator clicks an SD card in the Sources column, **When** Create Job opens, **Then** the source field is pre-filled with that card.
4. **Given** Create Job is open, **When** the operator picks a destination, **Then** the plan summary at the bottom updates live with files, bytes, ETA, and time-of-day completion (`47 files · 118 GB · est. 11 min · done by 17:48`).
5. **Given** the operator is creating a transfer-only job (90% case), **When** they look at the form, **Then** compression options are collapsed by default and not visually competing for attention.

---

### User Story 3 — Verification as Hero (Priority: P1)

Today, SHA-256 hash verification is implemented but communicated as a small blue shield icon next to a status icon, with hashes hidden inside an `ExpansionTile` showing 64-character hex strings in tiny monospace. The redesign makes verification visible at every level: a verification badge on the active job card, a "✓ matches" badge per file with a side popover for the actual hashes, an Audit tab in the detail screen, and clear celebration copy when a job completes verified.

**Why this priority**: The product's emotional payoff. Operators trust the app because verification works — but they should *feel* that trust, not have to dig for it.

**Independent Test**: Run a transfer with SHA-256 mode. Without expanding any tiles, identify which files are verified and which are pending verification. Open one file's hash detail; verify both source and destination hashes are readable and copyable.

**Acceptance Scenarios**:

1. **Given** a job is using SHA-256 verification, **When** the operator looks at the active hero card, **Then** a verification badge ("SHA-256 ✓ verifying" or "SHA-256 ✓") is visible on the stats line.
2. **Given** files have been verified with matching hashes, **When** the operator opens the Files tab, **Then** each verified file shows a "✓ matches" badge inline (no expansion required).
3. **Given** the operator clicks a "✓ matches" badge, **When** the side popover opens, **Then** both source and destination hashes are visible in a readable monospace font with a copy-to-clipboard button.
4. **Given** a job completes successfully with all files verified, **When** the operator returns to the screen, **Then** the active-job slot shows a green "All cards copied & verified" message with [Erase Cards] and [New Job] CTAs.
5. **Given** a job uses size-only verification, **When** the operator views the active card, **Then** a "size-only" verification badge is visible (and the existing erase-dialog warning continues to apply when the operator attempts to erase the source card).

---

### User Story 4 — Three-Column Persistent Layout (Priority: P1)

The current master-detail layout (360px queue + flex right) starves both panels: the queue card subtitle has to truncate paths to basenames, and the right pane is empty when no job is selected. The redesign uses three persistent columns: Sources (240px) on the left, Queue + Detail (flex) in the center, Activity log (300px) on the right. Minimum window size bumps from 800×600 to 1280×720 so all three columns fit comfortably.

**Why this priority**: This is the structural decision that unlocks every other change. The hero card needs the queue panel to breathe. The Sources column makes drive detection always visible. The Activity log gives the history feed a real home.

**Independent Test**: Resize the window to 1280×720 (the new minimum). Verify all three columns are visible and content within each column is readable without horizontal scrolling.

**Acceptance Scenarios**:

1. **Given** the app is launched, **When** the operator sees the main shell, **Then** three columns are visible: Sources (left), Queue/Detail (center), Activity (right).
2. **Given** the window is at minimum size (1280×720), **When** the operator views the queue, **Then** queue cards show full source and destination paths without basename-only truncation.
3. **Given** the operator attempts to resize the window below 1280×720, **When** they release the resize handle, **Then** the window snaps to or refuses sizes below the minimum.
4. **Given** SD cards are inserted while the app is running, **When** the operator looks at the Sources column, **Then** the new cards appear automatically (no manual refresh required).
5. **Given** completed jobs exist, **When** the operator views the Activity column, **Then** they see jobs grouped by day with headers "Today / Yesterday / This week / Older".
6. **Given** the operator wants to export job history, **When** they look at the Activity column, **Then** an "Export CSV" button is visible at the bottom of the column (no longer hidden behind a small icon in a row header).

---

### User Story 5 — Inline Detail with Tabs (Priority: P2)

Today the detail view replaces the right panel and is a long vertical scroll mixing job summary, progress, file list, and the buried Erase button. The redesign makes detail an inline expansion of the active job card and organizes content into three tabs (Files / Audit / Errors) — all three tabs are always visible, with Errors showing "(0)" when empty.

**Why this priority**: After a long shoot, a job can have 200+ files. The current flat list is a perf trap (`shrinkWrap: true` inside `SingleChildScrollView`) and a UX trap (no filtering, no grouping). Tabs solve both.

**Independent Test**: Run a transfer with 100+ files. Open the Files tab and filter by status. Switch to Audit and confirm hash trail is visible. Switch to Errors and confirm "(0)" appears when nothing has failed.

**Acceptance Scenarios**:

1. **Given** the operator clicks the active job card, **When** detail expands inline, **Then** three tabs are visible: Files, Audit, Errors.
2. **Given** a job has failed files, **When** the operator views the Errors tab, **Then** each failed file's error reason is listed with the file name.
3. **Given** a job has no errors, **When** the operator views the Errors tab, **Then** the tab label shows "Errors (0)" and the tab body shows a brief empty-state message rather than a blank panel.
4. **Given** the operator views the Files tab with 100+ files, **When** they scroll, **Then** the list scrolls smoothly (virtualized rendering) without freezing the UI.
5. **Given** the Files tab is open, **When** the operator clicks a filter chip ("Failed"), **Then** the list filters to show only failed files.

---

### User Story 6 — Erase Always Visible (Priority: P2)

Today the Erase SD Card button is buried at the bottom of the file list and only appears when all files are completed and verified. The redesign moves it to a header action in the detail view, always visible, but disabled with a clear reason ("Waiting for SHA-256 verification" / "Job not yet complete") until eligible. All existing safety gates — serial-number re-verification, typed drive-path confirmation, size-only verification warning inside the dialog — stay in place.

**Why this priority**: Erase is the critical post-success action operators take many times a day. They need to know it exists *before* the job completes (so they can plan to come back at the right time) and not have to scroll past 200 files to find it.

**Independent Test**: View a job that's mid-transfer. Confirm the Erase button is visible in the detail header but disabled with a tooltip explaining why.

**Acceptance Scenarios**:

1. **Given** a job is in progress, **When** the operator views the detail header, **Then** an Erase SD Card button is visible but disabled, with an explanation like "Waiting for SHA-256 verification."
2. **Given** a job is complete and all files are verified, **When** the operator views the detail header, **Then** the Erase SD Card button is enabled.
3. **Given** the operator clicks Erase SD Card, **When** the confirmation dialog appears, **Then** the existing safety gates are present: serial-number re-verification after dialog dismissal, typed drive-path confirmation field, and size-only warning when applicable.
4. **Given** a job's source is not a removable drive (e.g., compression-only job), **When** the operator views the detail header, **Then** the Erase SD Card button is not shown.

---

### User Story 7 — Discoverable Drag and Context Actions (Priority: P2)

Drag-to-reorder works today but has no visible affordance — the entire card is the drag target. The right-click context menu also exists but is invisible. The redesign adds a visible `☰` drag handle on queued cards (drag listener moves to the handle so click-to-expand still works on the card body) and a `⋯` overflow button mirroring all context-menu actions on each card.

**Why this priority**: A power-user feature that no operator can find isn't a feature. Both reviewers flagged this as the most invisible interaction in the app.

**Independent Test**: Show the queue to a new operator who has never used the app. Without telling them, observe whether they discover drag-to-reorder and the context menu within 2 minutes of normal use.

**Acceptance Scenarios**:

1. **Given** a job is queued, **When** the operator looks at the queue card, **Then** a `☰` drag handle is visible on the right edge.
2. **Given** the operator drags the `☰` handle, **When** they release on a different position, **Then** the queue reorders and the queue processor processes jobs in the new order.
3. **Given** the operator clicks the card body (not the handle), **When** the click is registered, **Then** the card expands inline (does not start a drag).
4. **Given** a job card is visible, **When** the operator looks at it, **Then** a `⋯` overflow button is visible.
5. **Given** the operator clicks `⋯`, **When** the menu opens, **Then** all actions available via right-click are also available in this menu.

---

### User Story 8 — Plan Summary Before Commit (Priority: P2)

Today the operator clicks "Add to Queue" without seeing what they're committing to. Path-length warnings, disk-space warnings, and conflict counts surface as separate AlertDialogs after submit. The redesign adds a live plan summary panel at the bottom of Create Job: file count, total bytes, ETA, time-of-day completion, free-space verdict, conflict count, long-path count — all inline, all updating as the operator changes inputs.

**Why this priority**: Operators are about to commit hours of transfer. They want to see "I am about to copy 47 files (118 GB) to D:\Project — done by 17:48" before clicking. Today they see a toast after.

**Independent Test**: Open Create Job, pick a source and destination. Confirm the plan summary at the bottom shows file count, bytes, ETA, and time-of-day completion. Change destination to a folder with conflicts; confirm the conflict count appears in the plan summary inline (not as a separate dialog).

**Acceptance Scenarios**:

1. **Given** the operator picks a source in Create Job, **When** the file scan completes, **Then** the plan summary shows files and bytes.
2. **Given** the operator picks a destination, **When** the path is valid, **Then** the plan summary shows ETA and time-of-day completion.
3. **Given** the destination has insufficient free space, **When** the plan summary updates, **Then** the free-space verdict reads "60 GB free — won't fit, you have 118 GB to copy" inline.
4. **Given** some destination paths exceed 260 characters, **When** the plan summary updates, **Then** a yellow inline note appears: "9 files have paths > 260 chars — Windows may reject these" (no separate dialog).
5. **Given** existing files are detected at the destination, **When** the plan summary updates, **Then** the conflict count is shown inline; the conflict-resolution dialog only appears when the operator clicks "Add to Queue."

---

### User Story 9 — Settings as Side-Nav (Priority: P3)

Today Settings is a single-column page mixing Slack webhook, operator name, update preferences, and "Prep Test Cards" — with silent autosave and no validation feedback. The redesign uses a side-navigation layout with five sections (Notifications / Operator / Behavior / Diagnostics / About) and explicit save/test status indicators ("Saved ✓", "Last test: OK 11:42", "Connected ✓").

**Why this priority**: Settings is touched rarely, but trust matters most when configuring Slack — operators need to know the webhook actually works before walking away. Side-nav also creates a clear home for "Diagnostics" content (log file path, instance lock state, HandBrake detection) that has nowhere logical to live today.

**Independent Test**: Open Settings, change the Slack webhook URL, click "Test now." Confirm a status indicator appears showing test result and timestamp. Change operator name; confirm "Saved ✓" appears briefly.

**Acceptance Scenarios**:

1. **Given** the operator opens Settings, **When** the page loads, **Then** five sections are accessible via side-navigation: Notifications, Operator, Behavior, Diagnostics, About.
2. **Given** the operator types a Slack webhook URL, **When** the field debounce-saves, **Then** a "Saved ✓" indicator appears briefly.
3. **Given** the operator clicks "Test now" in Notifications, **When** the test completes, **Then** the result and timestamp are persistently shown ("Last test: OK 11:42" or "Last test: failed at 11:42").
4. **Given** the operator opens Diagnostics, **When** the page loads, **Then** they see the log file path with a "Reveal in Explorer" button, the "Prep Test Cards" affordance, instance lock state, and HandBrake detection status.

---

### User Story 10 — Theme Foundation & Density (Priority: P3)

Today the theme is Material 3 default with `colorSchemeSeed: Colors.blue`, no spacing scale, no typography scale, and raw `Colors.red`/`Colors.orange`/`Colors.green` literals scattered across 12+ files. The redesign keeps Material 3 with seeded blue but adds: a `StatusColors` theme extension used everywhere, a centralized spacing scale (`Insets.xs/s/m/l/xl/xxl`), a 5-style typography scale with tabular figures on numeric styles, JetBrains Mono asset for paths and hashes, and `VisualDensity.compact` globally.

**Why this priority**: Foundation for every future change. Without this, every screen invents its own rhythm and a small change touches every screen. Compounding ROI.

**Independent Test**: After implementation, change one accent color in the theme. Confirm the change propagates to every screen that uses status colors. Look at any number that updates live (speed, ETA); confirm it doesn't shift other elements as digits change.

**Acceptance Scenarios**:

1. **Given** the operator views any screen with status colors, **When** they look at the visual treatment, **Then** colors come from a shared theme extension (no raw `Colors.X` literals in screen code).
2. **Given** a number updates live (e.g., transfer speed), **When** digits change, **Then** the surrounding layout does not shift (tabular figures applied).
3. **Given** the operator views a path or SHA-256 hash anywhere in the app, **When** the text is rendered, **Then** it uses the JetBrains Mono asset font (consistent across machines).
4. **Given** the app uses density-compact mode, **When** the operator views the queue, **Then** roughly 25% more vertical content is visible compared to the v2.3.0 default density.

---

### User Story 11 — Keyboard Cheat Sheet (Priority: P3)

Today only two shortcuts are wired (`Ctrl+N`, `Ctrl+Enter`) and they're advertised in a tiny grey hint in the empty-state right panel. The redesign expands to ten-plus shortcuts and adds a `?`/`F1` modal cheat sheet surfaced from a `?` icon in the status bar.

**Why this priority**: Operators on a shared workstation are exactly the kind of users who pick up keyboard shortcuts when they're discoverable. Cheap to implement, high satisfaction value.

**Independent Test**: Press `?` from the main shell. A modal appears listing all shortcuts. Press `Esc` to dismiss. Try each listed shortcut and confirm it triggers the documented action.

**Acceptance Scenarios**:

1. **Given** the app is open, **When** the operator presses `?` or `F1`, **Then** a modal cheat sheet appears listing all keyboard shortcuts grouped by category.
2. **Given** the cheat sheet is open, **When** the operator presses `Esc`, **Then** the modal dismisses.
3. **Given** the cheat sheet lists a shortcut, **When** the operator presses that shortcut anywhere in the app, **Then** the documented action is triggered.
4. **Given** the operator views the status bar, **When** they look for help, **Then** a `?` icon is visible and clickable to open the cheat sheet.

---

### Edge Cases

- What happens when the window is below the new 1280×720 minimum? The window manager prevents resize below this; no responsive collapse is required.
- What happens when no SD cards are detected? The Sources column shows a pulsing "Listening for SD cards…" banner that updates live as cards are inserted.
- What happens when the Activity column has no completed jobs yet? The column shows an empty-state message with a brief explanation of what will appear there.
- What happens when the active job card is large (a long file list expanded inline) and a new active job appears? The expanded card collapses; the new active job becomes the hero. State is preserved if the operator reopens the previous job from the Activity column.
- What happens to drag-to-reorder when only one job is queued? The drag handle remains visible but dragging has no effect.
- What happens when the operator presses a keyboard shortcut while a modal dialog is open? Shortcuts are scoped to the main shell; modal-open state pauses them so typing in a TextField doesn't trigger queue actions.
- What happens to crash-recovered jobs in the queue? They appear as paused with a clear "Recovered after restart" indicator on the card so the operator knows why the job is paused.

## Requirements

### Functional Requirements

**Layout & Shell**

- **FR-001**: The application MUST present three persistent columns at all times: Sources (left, fixed width), Queue + Detail (center, flex), Activity (right, fixed width).
- **FR-002**: The application MUST enforce a minimum window size of 1280×720 to ensure the three-column layout always fits.
- **FR-003**: The application MUST replace the current AppBar with a status bar containing: app icon and name, a single state dot (grey/blue/green/red/orange), queue summary text including time-of-day completion estimate, operator name, settings entry, and a help icon for the keyboard cheat sheet.
- **FR-004**: The system tray icon tooltip MUST mirror the status bar's queue-summary text rather than displaying a static "Idle" string.

**Job Card & Queue**

- **FR-005**: Job cards MUST render in three variants: Active (large hero with prominent progress, animated bar, stats line, current filename, action buttons), Queued (slim two-line row with a visible `☰` drag handle), and Done (compact dimmed row).
- **FR-006**: The drag-to-reorder listener MUST be attached to the `☰` handle, not the entire card body, so click-to-expand and drag-to-reorder do not conflict.
- **FR-007**: Each job card MUST expose a visible `⋯` overflow button mirroring every action available via right-click.
- **FR-008**: Job state MUST be communicated by a 12px colored dot at the card's left edge plus the card's left-border color; the redundant status chip on the right is removed.
- **FR-009**: Job type MUST be encoded as a monochrome glyph (color reserved for state).
- **FR-010**: For Transfer & Compress jobs, the active hero card MUST display a phase indicator: `✓ Transfer · ●●●●●●●● Compress · ○ Verify`.
- **FR-011**: The queue MUST visually group failed jobs at the top with a "1 failed — review" banner when failures exist.
- **FR-012**: When a job completes successfully and is the last job in the queue, the active-job slot MUST briefly show "All cards copied & verified" with [Erase Cards] and [New Job] CTAs before reverting to an empty state.

**Detail View & Tabs**

- **FR-013**: Job detail MUST be revealed inline inside the active card when clicked (no separate route or right-pane navigation).
- **FR-014**: Detail content MUST be organized into three always-visible tabs: Files, Audit, Errors. The Errors tab MUST display "(N)" in its label, including "(0)" when empty.
- **FR-015**: The Files tab MUST use virtualized rendering so 100+ file lists scroll smoothly without UI jank.
- **FR-016**: The Files tab MUST provide filter chips (All / Pending / In progress / Completed / Failed) that filter the displayed list.
- **FR-017**: Each verified file row MUST display a single "✓ matches" badge that opens a side popover with both source and destination hashes plus a copy-to-clipboard button. The current `ExpansionTile` pattern is removed.
- **FR-018**: The Erase SD Card button MUST live in the detail's header action area, always visible for transfer-type jobs whose source is a removable drive. It MUST be disabled with a clear textual reason when not eligible (e.g., "Waiting for SHA-256 verification", "Job not yet complete").
- **FR-019**: All existing erase safety gates MUST remain: pre/post drive identity comparison via serial number, typed drive-path confirmation, and size-only verification warning inside the dialog.

**Sources Column**

- **FR-020**: The Sources column MUST list detected SD cards live (auto-refresh on insertion/removal) without requiring user action.
- **FR-021**: The Sources column MUST display a pulsing "Listening for SD cards…" banner when no cards are detected.
- **FR-022**: Clicking an SD card in the Sources column MUST open Create Job with the source field pre-filled.
- **FR-023**: Favorites remain inside Create Job (not in the Sources column).

**Create Job**

- **FR-024**: Create Job MUST present source selection as an inline radio row of detected drives plus a "Folder…" option (replacing the separate DriveList widget).
- **FR-025**: Compression options MUST be collapsed by default and expand only when the operator chooses Copy & Compress (or expands the section).
- **FR-026**: Create Job MUST display a live plan summary panel at the bottom containing: file count, total bytes, estimated duration, time-of-day completion, free-space verdict, conflict count, and long-path count.
- **FR-027**: The destination free-space indicator MUST read as a sentence ("4.2 TB free — plenty of room" / "180 GB free — cutting it close" / "60 GB free — won't fit, you have 118 GB to copy") rather than a numeric label.
- **FR-028**: Long destination paths exceeding 260 characters MUST be flagged inline in the plan summary as a yellow note ("9 files have paths > 260 chars — Windows may reject these"), not as a blocking AlertDialog.

**Copy All Cards Flow**

- **FR-029**: The Copy All Cards flow MUST present detected cards first (with checkboxes for per-card inclusion), then destination, then verification mode, then a plan summary line, all in a single panel before any jobs are created.
- **FR-030**: The Copy All Cards plan summary MUST show total job count, total bytes, and overall validity verdict (e.g., "Plan: 3 jobs · 290 GB · OK").

**Activity Column**

- **FR-031**: The Activity column MUST display completed jobs grouped by day with headers: Today, Yesterday, This week, Older.
- **FR-032**: The Activity column MUST include a prominent "Export CSV" button at the bottom (no longer hidden behind a small icon in a row header).

**Settings**

- **FR-033**: Settings MUST use a side-navigation layout with five sections: Notifications, Operator, Behavior, Diagnostics, About.
- **FR-034**: The Notifications section MUST include a "Test now" button for the Slack webhook with a persistent status indicator showing the result and timestamp of the most recent test ("Last test: OK 11:42" or "Last test: failed 11:42") and a connection-state pill.
- **FR-035**: The Operator section MUST display a "Saved ✓" indicator briefly after each debounced save.
- **FR-036**: The Diagnostics section MUST surface: "Prep Test Cards" affordance, log file path with "Reveal in Explorer" button, instance lock state, and HandBrake detection status.

**Theme & Density**

- **FR-037**: The theme MUST define a centralized spacing scale (`Insets.xs/s/m/l/xl/xxl` = 4/8/12/16/24/32 logical pixels) used in place of literal `SizedBox` values throughout the UI.
- **FR-038**: The theme MUST define five typography styles (display / headline / title / body / caption) with `FontFeature.tabularFigures()` applied to numeric-heavy styles so updating numbers do not shift surrounding layout.
- **FR-039**: The theme MUST define a `StatusColors` theme extension used in place of raw `Colors.red`, `Colors.orange`, `Colors.green` literals across all UI files.
- **FR-040**: The application MUST bundle the JetBrains Mono font asset and use it for all path and hash rendering.
- **FR-041**: The application MUST set `VisualDensity.compact` globally for desktop-appropriate density.
- **FR-042**: The theme MUST remain Material 3 with the existing seeded-blue color scheme; dark mode is not added in this feature.

**Component-Level Changes**

- **FR-043**: The pipeline progress bar MUST display a single dense stats line: `184 MB/s · 23/49 · 12m elapsed · done by 18:14`.
- **FR-044**: The pipeline progress bar MUST animate with a slow shimmer when active (idle bars do not shimmer).
- **FR-045**: Filenames in progress and file rows MUST use middle-ellipsis truncation (`A001_C012_…_05072B.MOV`) to preserve the timecode tail.
- **FR-046**: The conflict resolution dialog MUST display source vs destination file sizes side-by-side with an "identical size" / "very different" hint.
- **FR-047**: The confirmation dialog (used for non-conflict destructive actions) MUST adopt the typed-confirmation pattern used by `ConflictResolutionDialog`, with severity-aware visual treatment so clearing history is visually distinguishable from erasing an SD card.

**Empty / Loading / Error States**

- **FR-048**: When SD cards are detected but no jobs are queued, the queue panel MUST present an "N cards detected" hero state with a primary "Copy All Cards" CTA (reverses current priority where Copy All is a secondary OutlinedButton).
- **FR-049**: Initial loading states (drive list, file list, queue list) MUST use skeleton placeholders rather than a centered `CircularProgressIndicator`.
- **FR-050**: When HandBrake is not installed, the home screen MUST display a warning banner (currently only Create Job displays this).
- **FR-051**: Crash-recovered paused jobs MUST display a "Recovered after restart" indicator on the card.

**Keyboard Shortcuts**

- **FR-052**: The application MUST register and document the following keyboard shortcuts (existing where noted):
  - `Ctrl+N` New job (existing)
  - `Ctrl+Shift+C` Copy All Cards (new)
  - `Ctrl+Enter` Pause/Resume queue (existing)
  - `Ctrl+,` Open Settings (new)
  - `Ctrl+E` Export history CSV (new)
  - `Ctrl+L` Open log file (new)
  - `↑ / ↓` Move selection in queue (new)
  - `Space` Toggle expand/collapse selected job card (new)
  - `Delete` Remove selected job (with confirm) (new)
  - `Ctrl+R` Retry selected failed job (new)
  - `?` or `F1` Show keyboard cheat sheet (new)
- **FR-053**: A `?` icon in the status bar MUST open a modal listing all keyboard shortcuts grouped by category, dismissible with `Esc`.
- **FR-054**: Keyboard shortcuts MUST be scoped to the main shell so they do not fire while a modal dialog or text input has focus.

### Key Entities

- **Job**: Existing entity. No schema changes. Surface area unchanged; rendering changes only.
- **JobFile**: Existing entity. No schema changes. Hash display moves from `ExpansionTile` to popover but no model changes.
- **DetectedDrive**: Existing entity. Now rendered in the persistent Sources column instead of inside Create Job.

## Success Criteria

### Measurable Outcomes

- **SC-001**: An operator standing 3 meters from the screen can correctly identify queue state (idle / running / completed / attention-needed) within 2 seconds, in 90%+ of attempts.
- **SC-002**: Time from "two SD cards inserted" to "two transfer jobs created and queued" decreases by at least 30% versus the v2.3.0 flow.
- **SC-003**: A new operator using the app for the first time discovers drag-to-reorder and the per-card overflow menu within 2 minutes of guided exploration, without prompting.
- **SC-004**: Files lists with 200+ entries scroll at a smooth 60fps with no perceived UI freeze.
- **SC-005**: An operator can verify both source and destination SHA-256 hashes for any verified file by clicking exactly one badge (no expansion required, side popover with copy buttons).
- **SC-006**: Settings webhook test result is visible without re-running the test for at least one app session, with explicit success/failure timestamp.
- **SC-007**: 100% of status colors in UI files are sourced from the `StatusColors` theme extension (zero raw `Colors.red`/`Colors.orange`/`Colors.green` literals in screen and widget files).
- **SC-008**: Live-updating numbers (speed, ETA, percentage) do not shift surrounding layout as digits change (tabular figures applied throughout).
- **SC-009**: Every keyboard shortcut listed in the cheat sheet performs the documented action; the cheat sheet is opened via `?` and dismissed via `Esc` without configuration.
- **SC-010**: The Erase SD Card affordance is visible in the detail view at every stage of the job lifecycle (disabled with reason during transfer, enabled after verification), confirmed by walkthrough on at least three distinct job states.
- **SC-011**: All destructive operations preserve their existing typed-confirmation gates; no regression in the safety properties shipped in v2.3.0.

## Assumptions

- The video team's Windows workstation supports a 1280×720 minimum window. (Project context confirms a single dedicated machine; today's minimum of 800×600 is conservative for a desktop app and the team is unlikely to use a smaller workspace.)
- Existing data model is sufficient — this redesign does not require schema changes or DAO additions.
- The Material 3 seeded-blue theme is acceptable as the visual base; no rebrand is requested.
- The team uses the app in daylight conditions and does not require dark mode; dark mode is explicitly deferred.
- The 24-hour clock format is acceptable for time-of-day completion (Romanian locale, Windows default 24h).
- Operators are mouse + keyboard primary; touch is not a target.
- Animations (progress bar shimmer, status dot pulse) are subtle and do not include audio cues.
- The redesign is an evolution, not a rewrite — all existing functionality keeps working through the visual changes; no feature regressions are acceptable.
- Adversarial reviews via `/codex:adversarial-review` and `/codex:rescue` will run before merge per project convention.

## Out of Scope (deferred)

- Dark mode (theme infrastructure should not block adding it later)
- Search/filter inside the queue (`Ctrl+F`)
- Re-run job from history with new destination
- Pin destination as default
- Drag-and-drop folder onto window (requires extra dependency)
- "Copy status to clipboard" shortcut for Slack pasting
- Audio cues for job completion / failure
