---
description: "Implementation tasks for feature 014: UI/UX Redesign — Visual Hierarchy & Operator Trust"
---

# Tasks: UI/UX Redesign — Visual Hierarchy & Operator Trust

**Input**: Design documents from `/specs/014-ui-redesign/`
**Prerequisites**: plan.md (✓), spec.md (✓), research.md (✓), data-model.md (✓), quickstart.md (✓)

**Tests**: Manual QA on Windows 11 per quickstart.md. No automated test tasks (existing widget_test.dart placeholder retained).

**Organization**: Tasks are grouped by user story to enable independent implementation and review. All 11 stories share the foundational theme infrastructure (Phase 2). Reordered after Codex tasks-review to ensure each story's checkpoint is reachable in isolation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- File paths are absolute or repo-relative under `lib/` / `assets/`

## Path Conventions

- Single Flutter project: source under `lib/`, assets under `assets/`
- New widgets: `lib/ui/widgets/`
- New screens: `lib/ui/screens/`
- Theme: `lib/ui/theme/`

---

## Phase 1: Setup (Project Initialization)

**Purpose**: Bump version, declare new font asset, refresh dependencies. No behavioral changes.

- [X] T001 Bump `version` in `pubspec.yaml` from `2.3.0+1` to `2.4.0+1`
- [X] T002 Place `JetBrainsMono-Regular.ttf` in `assets/fonts/` (download from JetBrains Mono OFL distribution)
- [X] T003 Declare JetBrains Mono font asset in `pubspec.yaml` under `flutter > fonts:` with family name `JetBrainsMono`
- [X] T004 Run `flutter pub get` to fetch the new asset declaration

---

## Phase 2: Foundational (Theme Infrastructure — BLOCKING)

**Purpose**: Theme primitives every screen and widget will read. Must be in place before any US-level UI work begins.

**⚠️ CRITICAL**: All user stories depend on these tasks being complete.

- [X] T005 Create `lib/ui/theme/insets.dart` defining `class Insets { static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0; }`
- [X] T006 [P] Create `lib/ui/theme/text_styles.dart` defining `AppTextStyles` with `display`, `headline`, `title`, `body`, `caption`, `mono` styles; apply `FontFeature.tabularFigures()` on `display` and any numeric-heavy variant
- [X] T007 Wire `AppTextStyles` into `lib/ui/theme/app_theme.dart` `textTheme:` overrides (`displayMedium`, `titleLarge`, `bodyLarge`, etc.) so `Theme.of(context).textTheme` resolves to these. **MUST preserve Material 3 + the existing seeded-blue color scheme; MUST NOT add dark mode** (FR-042). Keep the existing `darkTheme` getter unchanged.
- [X] T008 [P] Extend `StatusColors` extension in `lib/ui/theme/app_theme.dart` with dot-color getters: `dotIdle`, `dotActive`, `dotRecentDone`, `dotAttention`, `dotWarning`
- [X] T009 Set `visualDensity: VisualDensity.compact` in both `lightTheme` and `darkTheme` getters of `lib/ui/theme/app_theme.dart`
- [X] T010 Update `lib/main.dart`: change `setMinimumSize(const Size(800, 600))` to `setMinimumSize(const Size(1280, 720))`; keep `_AlreadyRunningApp` window at 520×320
- [X] T011 Audit and replace all raw `Colors.red` / `Colors.orange` / `Colors.green` literals across `lib/ui/screens/` and `lib/ui/widgets/` with `Theme.of(context).extension<StatusColors>()!` accessors. **Acceptance criteria**: `grep -rE 'Colors\.(red|orange|green)' lib/ui/` returns zero hits in screen and widget files (theme files exempt).
- [X] T012 Create `lib/services/queue_state_notifier.dart` (or extend `jobQueueService`) exposing a single source of truth for queue lifecycle events: `onQueueRunningStarted`, `onQueueAllDone`, `onQueueDismissedByUser` (job created, queue started, etc.). Both StatusBar (T015 timer) and HomeScreen (T064 celebration) MUST subscribe to the same source so the green-dot timer and the completed-card overlay clear on identical events.

**Checkpoint**: Theme foundation ready. Run `flutter analyze` — must pass clean.

---

## Phase 3: User Story 1 — Trust at a Glance (Priority: P1) 🎯 MVP

**Goal**: Operator standing across the room can read queue state (idle/running/completed/attention) within 2 seconds. Status bar replaces bare AppBar; tray tooltip mirrors live state. Job cards render in four state-distinguished variants.

**Independent Test**: Insert SD cards, start a job, force a failure, restore the queue. Verify state dot transitions (grey → blue → green → grey, or → orange/red as appropriate); verify tray tooltip matches status bar text; verify Active hero card is visually distinct from Queued slim rows from Done dimmed rows.

### Implementation for User Story 1

- [X] T013 [US1] Create `lib/ui/widgets/queue_summary_composer.dart` (pure function or small class): produces the queue summary text given queue state. Used by both StatusBar and tray tooltip to avoid duplicate logic.
- [X] T014 [US1] Create `lib/ui/widgets/status_bar.dart`: app icon + name, state dot, queue summary text (via `QueueSummaryComposer`), operator name (read via the existing settings access pattern — verify whether the codebase exposes a `SettingsDao.watchSettings()` or accesses settings via a singleton, and use whichever exists), settings IconButton, `?` IconButton.
- [X] T015 [US1] Implement state-dot precedence in StatusBar: `red` (any failed job) > `orange` (Slack misconfigured OR HandBrake missing) > `blue` (job running) > `green` (queue cleared <5min) > `grey` (idle); summary text describes highest-priority condition. Implement 5-minute recent-done `Timer` driven by `QueueStateNotifier` (T012) — started on `onQueueAllDone`, cancelled on `onQueueDismissedByUser`.
- [X] T016 [US1] Subscribe StatusBar to `jobQueueService.progressNotifier` + `jobDao.watchAllJobs()` + `QueueStateNotifier` to drive state and summary
- [X] T017 [US1] Implement animated pulse on `blue`/`orange`/`red` dot states using a slow `AnimationController` (disposed in StatusBar `dispose()`); idle/recent-done dots are static
- [X] T018 [US1] Wire `trayManager.setToolTip()` mirror of StatusBar summary in `lib/main.dart` (or a small TrayService method); throttle to 1Hz; reads from the same `QueueSummaryComposer`
- [X] T019 [US1] **Install StatusBar into the existing ShellScreen AppBar slot now** via `Scaffold(appBar: PreferredSize(preferredSize: Size.fromHeight(56), child: StatusBar()))`. This makes US1 demoable in isolation. The full three-column body rewrite is T046 in US4 — that task preserves the StatusBar slot.
- [X] T020 [US1] Create `lib/ui/widgets/job_card_active.dart`: large hero with state dot, type glyph (monochrome), source → destination, embedded `PipelineProgressBar`, current filename (middle-ellipsis), stats line **including verification badge (`SHA-256 ✓` / `Size-only`)**, phase indicator strip (Transfer & Compress jobs), Pause/Cancel/⋯ action buttons. **Erase SD Card button lives in this widget's header** (FR-018) — disabled-with-reason states wired in T064 (US6).
- [X] T021 [US1] Create `lib/ui/widgets/job_card_next_up.dart`: same height as Active, no progress bar, "Press Start to begin" hint, Start/Cancel actions
- [X] T022 [US1] Create `lib/ui/widgets/job_card_queued.dart`: 64px slim row with state dot at left, ☰ drag handle on right
- [X] T023 [US1] Create `lib/ui/widgets/job_card_done.dart`: 48px dimmed row, ⋯ overflow only
- [X] T024 [US1] Update `lib/ui/widgets/job_card.dart` to act as router: picks variant by `job.status` and queue context (running → Active; first queued when nothing running → Next-up; rest queued → Queued; completed → Done)
- [X] T025 [US1] Drop the redundant status chip on the right of all card variants; encode state via 12px left-edge dot + left-border color from `StatusColors`
- [X] T026 [US1] Encode job type as a monochrome glyph (no color) in all four card variants
- [X] T027 [US1] Add a "warning banner slot" region at the top of the home queue panel in `lib/ui/screens/home_screen.dart` — a vertical column where Slack-unconfigured / HandBrake-missing / failed-banner widgets render. Banners are wired in T037 (US2 hero), T087 (failed banner US7), T108 (HandBrake banner Polish).

**Checkpoint**: Status bar replaces AppBar (with the existing single-pane body still in place); cards render in four variants; state is readable across the room. US1 is demoable on Windows 11.

---

## Phase 4: User Story 2 — One-Screen Common Path (Priority: P1)

**Goal**: "Insert SD cards → copy → walk away" is one screen. Sources column shows live SD cards. Create Job collapses to common path. Copy All Cards shows detected cards FIRST.

**Independent Test**: Insert two SD cards. Verify they appear in Sources within 3 seconds. Click one — Create Job opens pre-filled. Click "Copy All Cards" from queue empty state — dialog shows cards with checkboxes before destination/verification.

### Implementation for User Story 2

- [X] T028 [US2] Create `lib/ui/widgets/sources_panel.dart`: 240px left column listing detected drives with letter, label, capacity used/total, free-space pill. Exposes `onSourceSelected(DetectedDrive drive)` callback in its constructor — caller (ShellScreen, see T046) wires it to show CreateJob pre-filled. SourcesPanel itself does NOT navigate.
- [X] T029 [US2] Implement `Timer.periodic(Duration(seconds: 3))` polling `driveService.getRemovableDrives()` in SourcesPanel; cancel in `dispose()`; swallow transient errors silently (next tick recovers)
- [X] T030 [US2] Implement pulsing "Listening for SD cards…" empty state in SourcesPanel using a slow `AnimationController` (disposed in `dispose()`)
- [X] T031 [US2] Restructure `lib/ui/screens/create_job_screen.dart` source row to inline radio chips of detected drives + "Folder…" button (replaces inline DriveList block). When opened with a pre-fill from SourcesPanel, the corresponding chip is pre-selected.
- [X] T032 [US2] Add free-space sentence renderer below destination picker in CreateJobScreen ("4.2 TB free — plenty of room" / "180 GB free — cutting it close" / "60 GB free — won't fit, you have 118 GB to copy")
- [X] T033 [US2] Preserve favorite chips below destination picker in CreateJobScreen (FavoritesService and chip UI unchanged from v2.3.0)
- [X] T034 [US2] Collapse compression options into `ExpansionTile` in CreateJobScreen; expansion enables "Copy & Compress" job type
- [X] T035 [US2] Create `lib/ui/widgets/copy_all_cards_dialog.dart`: detected cards with checkboxes (cards FIRST), destination picker with free-space, verification mode SegmentedButton, conflict-handling default, plan summary line, Create N Jobs button. **Drive-snapshot policy**: detected drives are captured as a snapshot when the dialog opens (no live polling inside the dialog). Before invoking `createBatchTransferJobs(...)`, the dialog re-checks each selected drive is still present; if any selected drive disappeared, show an inline error and abort the batch.
- [X] T036 [US2] Replace `_batchCopyAllCards()` body in `lib/ui/screens/home_screen.dart` to invoke `CopyAllCardsDialog`; reuse existing `createBatchTransferJobs(...)` callback on confirm
- [X] T037 [US2] Add hero "N cards detected — Copy All Cards" empty state to home queue panel when queue empty + drives present (FR-048); rendered in the queue panel's main slot (not the warning-banner slot from T027)

**Checkpoint**: Common path is one screen; cards detected → copied → done without page-hopping. SourcesPanel exists as a standalone widget; full shell wiring is T046 in US4.

---

## Phase 5: User Story 3 — Verification as Hero (Priority: P1)

**Goal**: SHA-256 verification is visually celebrated. One click reveals both source and destination hashes side-by-side.

**Independent Test**: Run a SHA-256-verified transfer. Verify badge appears on Active hero card stats line (already wired in T020). Open Files tab — verified rows show "✓ matches". Click one — popover shows both hashes in JetBrains Mono with "Copy both" button.

### Implementation for User Story 3

- [X] T038 [US3] Create `lib/ui/widgets/files_tab.dart` as a single `ListView.builder`: index 0 is the filter chip row; subsequent indices are file rows. NO nested scrollers. The widget is given a fixed parent height by its container in DetailTabs (T055).
- [X] T039 [US3] Implement filter chips (All / Pending / In progress / Completed / Failed) as component-local state in FilesTab; changing filters re-filters the backing list
- [X] T040 [US3] Per-row rendering in FilesTab: status icon, filename (middle-ellipsis), size, "✓ matches" badge for verified files (replaces ExpansionTile-with-hashes pattern)
- [X] T041 [US3] Implement hash popover via `showDialog`: shows source hash + destination hash in `AppTextStyles.mono` (JetBrainsMono), with "Copy both" button using `Clipboard.setData`

**Checkpoint**: Verification is visible at every layer (hero badge → file row badge → hash popover). FilesTab is created here but wired into DetailTabs container in US5 (T055).

---

## Phase 6: User Story 4 — Three-Column Persistent Layout (Priority: P1)

**Goal**: Three columns visible at once at 1280×720+. Sources left, Queue+Detail center, Activity right.

**Independent Test**: Open at 1280×720 — all three columns visible. Insert SD card — Sources updates live. Complete a job — Activity updates with day grouping. Click Export CSV — file is created. Press Ctrl+E — same export fires.

### Implementation for User Story 4

- [X] T042 [US4] Create `lib/ui/widgets/activity_panel.dart` (300px right column) subscribing to `jobDao.watchCompletedJobs()`. **Implemented as**: free-function `exportHistoryToCsv(BuildContext)` in `lib/utils/history_export.dart` shared by both the panel button and the Ctrl+E shortcut (US11 T097). No controller pattern needed — the helper is the single export entry point.
- [X] T043 [US4] Implement day grouping in ActivityPanel: Today / Yesterday / This week (≤7 days) / Older; day boundary uses local time
- [X] T044 [US4] Render each completed job as `JobCardDone` inside the appropriate group in ActivityPanel
- [X] T045 [US4] Add prominent `FilledButton.tonalIcon` "Export CSV" at bottom of ActivityPanel invoking `exportHistoryToCsv` helper
- [X] T046 [US4] Rewrite `lib/ui/screens/shell_screen.dart` body to three columns: Sources(240) / Expanded(Row[HomeScreen(360) | _buildRightPanel]) / ActivityPanel(300). StatusBar `appBar:` slot preserved.
- [X] T047 [US4] Preserved existing `WindowListener` graceful-shutdown logic (from 013) in the rewritten ShellScreen
- [X] T048 [US4] Stop routing `JobDetailScreen` as the right pane default. **Done in Phase 7**: shell `_buildRightPanel` no longer routes to JobDetailScreen; right pane is empty-state or CreateJobScreen. JobDetailScreen kept registered for backwards compat (deep-links / programmatic navigation only).
- [X] T049 [US4] Empty state in ActivityPanel: "Completed jobs will appear here."

**Checkpoint**: Three-column layout always on; no responsive collapse; min window enforced.

---

## Phase 7: User Story 5 — Inline Detail with Tabs (Priority: P2)

**Goal**: Job detail expands inline within the active card. Three tabs always visible (Files/Audit/Errors); Errors tab shows "(0)" when empty.

**Independent Test**: Click an active card. Detail expands inline (no navigation). All three tabs visible with counts. Files tab scrolls 200+ entries smoothly. Errors tab shows "(0)" with empty-state copy when no failures. Queued cards also expand on click into the same tabs (showing pending files / partial audit / no errors). Done cards expand into a reduced view (Audit tab pre-selected, full hash trail visible).

### Implementation for User Story 5

- [X] T050 [US5] Track `expandedJobIds: Set<int>` state owner in `lib/ui/screens/home_screen.dart` (queue) AND `lib/ui/widgets/activity_panel.dart` (history) — each panel owns its own set so expanding history doesn't toggle queue cards. Multiple cards may be expanded simultaneously. Toggling driven by card-body taps; Space-key shortcut wired in US11 T093.
- [X] T051 [US5] Create `lib/ui/widgets/audit_tab.dart`: Summary / Timeline / Hash trail sections with verification mode, operator name, total bytes, all hashes (selectable, JetBrains Mono).
- [X] T052 [US5] Create `lib/ui/widgets/errors_tab.dart`: failed-file list with `errorMessage`; empty state copy "No errors. Every file completed successfully."
- [X] T053 [US5] Create `lib/ui/widgets/detail_tabs.dart` with `TabBar`: Files (count) / Audit / Errors (count); tabs always visible. Errors tab label format: `Errors (N)` where N is failed-file count (including "(0)").
- [X] T054 [US5] Card-variant inline expansion policy: **Active / Queued / Next-up cards expand into the full DetailTabs** with Files tab default. **Done cards** use `DetailTabs.forDone` which pre-selects the Audit tab (history-friendly). All four variants expose `isExpanded` constructor param.
- [X] T055 [US5] Embed `DetailTabs` as inline expansion inside `JobCardActive` / `JobCardQueued` / `JobCardNextUp` / `JobCardDone`. Each variant restructured to wrap its body and the optional detail panel in a Card-internal Column. Inline detail uses `SizedBox(height: 320)` so FilesTab's `ListView.builder` has a finite container for virtualization. Toggling driven by panel-owned `expandedJobIds`.

**Checkpoint**: Inline detail works for active/queued/done jobs; tabs render with correct counts; FilesTab scrolls 200+ rows smoothly.

---

## Phase 8: User Story 6 — Erase Always Visible (Priority: P2)

**Goal**: Erase SD Card affordance is visible from job start (in the Active card header — see T020), disabled with reason until eligible. All existing safety gates preserved.

**Independent Test**: View an active card mid-transfer — Erase button visible in card header but disabled with text "Waiting for SHA-256 verification". After verification completes, button enables. Click — full typed-confirmation dialog with serial check fires. Swap the SD card mid-dialog — abort with "Drive changed" snackbar.

### Implementation for User Story 6

- [X] T056 [US6] Extract `_eraseSourceDrive()` flow from `lib/ui/screens/job_detail_screen.dart` into new `lib/ui/widgets/erase_drive_action.dart` — preserves `_showEraseConfirmDialog`, serial-number identity check, typed drive-path field, size-only warning. Exports both `EraseDriveActionButton` widget and a free-function `eraseSourceDrive(BuildContext, Job)` for the celebration's per-card sequence.
- [X] T057 [US6] Wired the EraseDriveAction button into `JobCardActive` header (slot reserved in T020). Disabled with reason text ("Job not yet complete" / "Waiting for SHA-256 verification" / "Waiting for verification") until the job is completed AND every file is verified. Compression-only jobs never render the button (no source drive to erase).
- [X] T058 [US6] **Verification checkpoint passed**: extracted widget preserves all safety gates: pre-dialog `getDriveIdentity` capture (line 105-107), typed drive-path TextField (~245-256), size-only warning conditional (~220-244), `barrierDismissible: false`, post-dialog identity re-check via `_identityMatches` (~117-127), "Drive changed" snackbar abort (~119-130). Behavior matches v2.3.0 byte-for-byte.
- [X] T059 [US6] Created `lib/ui/widgets/job_card_completed.dart`: ephemeral celebration card with green status-dot border, "All cards copied & verified" headline, CTA row [Erase Cards] [New Job], and a Dismiss `×` icon. Persists until `notifyDismissedByUser` or 5-minute auto-timer fires.
- [X] T060 [US6] Mounted `JobCardCompleted` in `lib/ui/screens/home_screen.dart` as a `SliverToBoxAdapter` above the active-jobs sliver. HomeScreen subscribes to `queueStateNotifier.events` in `initState`; on `allDone`, snapshots the recent (≤60s window) completed jobs into `_celebrationBatch` and starts a 5-minute auto-dismiss `Timer`. On `runningStarted` or `dismissedByUser`, clears the batch and cancels the timer. `_onCreateJob` fires `notifyDismissedByUser` so creating a new job dismisses the celebration in sync with StatusBar's green dot.
- [X] T061 [US6] [Erase Cards] CTA implemented as sequential per-card flow: extracts unique source drive paths from `recentJobs` (skips compression-type jobs which have no removable source); checks each path against `driveService.getRemovableDrives()` snapshot; for each still-present drive, invokes `eraseSourceDrive(context, job)` which fires its own typed-confirmation dialog (FR-019). NEVER bulk-erases (Constitution Principle I, FR-012). Skipped (drive not detected) cards counted in the final summary snackbar.

**Checkpoint**: Erase visible at every job stage; all safety gates preserved; bulk erase eliminated.

---

## Phase 9: User Story 7 — Discoverable Drag and Context Actions (Priority: P2)

**Goal**: Drag-to-reorder is visible (☰ handle); right-click actions also available via ⋯ overflow on every card. Failed-jobs banner anchored at top.

**Independent Test**: On a queued card, see ☰ on right. Drag handle to reorder; queue rearranges. Click card body (not handle) — card expands inline (no drag triggered). Click ⋯ — menu opens with all right-click actions. Force a job failure — "1 failed — review" banner pins at top with [Retry all] [Dismiss]; failed jobs stay in their normal queue position.

### Implementation for User Story 7

- [X] T062 [US7] Move `ReorderableDragStartListener` from the whole `JobCard` to a small wrapper around the `☰` icon in `JobCardQueued`
- [X] T063 [US7] Make `JobCardNextUp` reorderable (only `JobCardActive` is positionally fixed); dragging another card above Next-up promotes that card to Next-up
- [X] T064 [US7] Add `⋯` overflow button to all four card variants; menu mirrors every right-click action (retry, delete, view details, etc.)
- [X] T065 [US7] Implement failed-banner widget rendered in HomeScreen's warning-banner slot (created in T027): "N failed — review" with [Retry all] [Dismiss] actions. Failed jobs stay in their normal queue position (banner is the surfacing mechanism, not a re-sort) — preserves Active/Next-up anchor (FR-005a, FR-011).
- [X] T066 [US7] Failed-banner dismiss persistence: dismissing hides the banner until **a new failure occurs** (i.e., a job transitions into failed state that was not previously failed). Dismiss state lives in HomeScreen state (in-memory; resets on app restart). The `dismissedFailureSet: Set<int>` tracks which failed job IDs have been dismissed; the banner shows only when `failedJobs - dismissedFailureSet` is non-empty.

**Checkpoint**: Drag is visible; overflow mirrors right-click; failed banner doesn't break visual hierarchy and doesn't nag after dismissal.

---

## Phase 10: User Story 8 — Plan Summary Before Commit (Priority: P2)

**Goal**: Free-space verdict, conflicts, long paths visible inline before committing. No ETA pre-flight (unreliable).

**Independent Test**: In Create Job, pick source. Plan summary shows file count + bytes. Pick destination — free-space verdict appears as a sentence. Pick a destination with conflicts — conflict count shown inline. Pick a destination with long paths — yellow inline note appears.

### Implementation for User Story 8

- [X] T067 [US8] Create `lib/ui/widgets/plan_summary_panel.dart`: inputs are file count, total bytes, free-space verdict, conflict count, long-path count
- [X] T068 [US8] Wire PlanSummaryPanel to live source-scan results in CreateJobScreen — fed by existing scan logic
- [X] T069 [US8] Compute free-space verdict in PlanSummaryPanel based on destination picker selection: "plenty of room" / "cutting it close" / "won't fit" sentences (FR-027)
- [X] T070 [US8] Compute conflict count from existing conflict-detection logic and surface inline in PlanSummaryPanel
- [X] T071 [US8] Compute long-path count and surface as yellow inline note in PlanSummaryPanel ("9 files have paths > 260 chars — Windows may reject these")
- [X] T072 [US8] Replace blocking long-path `AlertDialog` in `lib/ui/screens/create_job_screen.dart` with the inline yellow note from T071. **Sequencing constraint**: T071 must be implemented before this task so the replacement exists when the dialog is removed; otherwise FR-028 has a temporary regression.
- [X] T073 [US8] Confirm ETA is intentionally OMITTED from PlanSummaryPanel (per FR-026 / clarification — ETA appears only on running cards)

**Checkpoint**: Plan summary updates live; no surprises post-commit.

---

## Phase 11: User Story 9 — Settings as Side-Nav (Priority: P3)

**Goal**: Settings uses side-nav with five sections. Notifications shows live test result; Diagnostics surfaces log path / instance lock / HandBrake status; About shows correct version.

**Independent Test**: Open Settings — see 5 sections in left nav. Type a Slack URL — "Saved ✓" appears briefly. Click "Test now" — result and timestamp persist as "Last test: OK 11:42" until app launch. Open Diagnostics — log file path with "Reveal in Explorer" works. Open About — shows version 2.4.0.

### Implementation for User Story 9

- [X] T074 [US9] Add `instanceLock.diagnostic()` getter in `lib/utils/instance_lock.dart` exposing current lock state (held/free, lock file path, PID if known) for Settings → Diagnostics. **MUST precede T078** since Diagnostics reads it.
- [X] T075 [US9] Rewrite `lib/ui/screens/settings_screen.dart` as `Row` with `NavigationRail` (5 items: Notifications / Operator / Behavior / Diagnostics / About) and a right detail pane
- [X] T076 [US9] Notifications section: Slack URL TextField with debounced save, explicit "Test now" button, in-memory last-test result line ("Last test: OK 11:42" / "failed at 11:42"), connection-state pill (green Connected / red Failed / grey Untested) — last-test result lives in widget state only (resets on app restart, no schema change)
- [X] T077 [US9] Operator section: name TextField with brief "Saved ✓" indicator after debounced save
- [X] T078 [US9] Diagnostics section: "Prep Test Cards" button (moved here from Notifications-adjacent space); log file path with "Reveal in Explorer" button calling `Process.run('explorer', ['/select,', logService.logPath])`; instance lock state (read via `instanceLock.diagnostic()` from T074); HandBrake detection status
- [X] T079 [US9] Behavior section: default verification mode dropdown, default conflict-resolution dropdown
- [X] T080 [US9] About section: app version (already from `package_info_plus`), "Check for updates" button (existing logic), link to GitHub releases page

**Checkpoint**: Settings scales gracefully; future preferences slot into existing sections.

---

## Phase 12: User Story 10 — Theme Foundation & Density (Priority: P3)

**Goal**: Adopt foundational theme primitives across all screens and widgets. (Foundational tasks T005–T012 created the primitives; this phase adopts them throughout the UI.)

**Independent Test**: Inspect any screen — numbers (speed, ETA, percentage) don't shift surrounding layout as digits change. Paths and SHA-256 hashes use JetBrains Mono. Density compact: queue shows ~25% more content than v2.3.0 default.

### Implementation for User Story 10

- [X] T081 [US10] Replace literal `SizedBox(height: N)` / `EdgeInsets.all(N)` values with `Insets.*` accessors across `lib/ui/screens/` and `lib/ui/widgets/`. **Acceptance criteria**: `grep -rE 'SizedBox\(height: ?[0-9]+\.?[0-9]*\)' lib/ui/` returns zero hits in screen/widget files; layout snapshots before/after look equivalent on Windows 11.
- [X] T082 [US10] Apply `AppTextStyles` via `Theme.of(context).textTheme` across affected widgets (status bar large numerics → display, screen titles → headline, section headers → title, etc.). **Acceptance criteria**: no raw `TextStyle(fontSize: ...)` literals remain in screen/widget files outside `text_styles.dart`.
- [X] T083 [US10] Apply `AppTextStyles.mono` (JetBrainsMono) to all path renderings and SHA-256 hash labels across cards, files tab, hash popover, audit tab. **Acceptance criteria**: `grep -rE "fontFamily: 'monospace'" lib/ui/` returns zero hits.

**Checkpoint**: No raw color literals, no raw SizedBox literals, no system monospace fallback for hashes.

---

## Phase 13: User Story 11 — Keyboard Cheat Sheet (Priority: P3)

**Goal**: All keyboard shortcuts wired and discoverable via `?` modal.

**Independent Test**: Press `?` from main shell — cheat sheet modal opens. Press `Esc` — modal dismisses. Test each documented shortcut. Type `?` in operator-name TextField — should insert "?" character, NOT open cheat sheet.

### Implementation for User Story 11

- [X] T084 [US11] Create `lib/ui/widgets/keyboard_cheat_sheet.dart`: modal listing all shortcuts grouped by category (Job Management / Queue Control / Navigation / Help); dismiss on `Esc` or outside click. **MUST precede T091** since the wiring opens this modal.
- [X] T085 [US11] Define `selectedQueueJobId: int?` state in `lib/ui/screens/home_screen.dart` (lifted from prior local state if any). Drives `↑/↓` navigation and `Space`/`Delete`/`Ctrl+R` actions. Selection visualizes as a focus ring on the corresponding card. Selection is preserved across reorders (by job ID, not index).
- [X] T086 [US11] Expand `Shortcuts(shortcuts: {...})` block in `lib/ui/screens/shell_screen.dart` to map all 11 shortcut keystrokes to `Intent` instances
- [X] T087 [US11] Wire `Ctrl+N` Action → existing CreateJobIntent
- [X] T088 [US11] Wire `Ctrl+Shift+C` Action → opens `CopyAllCardsDialog` (T035)
- [X] T089 [US11] Wire `Ctrl+Enter` Action → existing PauseResumeIntent
- [X] T090 [US11] Wire `Ctrl+,` Action → navigates to Settings
- [X] T091 [US11] Wire `?` and `F1` Actions → open KeyboardCheatSheet (T084)
- [X] T092 [US11] Wire `↑`/`Down` Actions → step `selectedQueueJobId` (T085) up/down through visible queue cards
- [X] T093 [US11] Wire `Space` Action → toggle inclusion of selected job in `expandedJobIds` (T050)
- [X] T094 [US11] Wire `Delete` Action → delete selected job after `ConfirmationDialog` (with typed confirmation per FR-047 — see T101)
- [X] T095 [US11] Wire `Ctrl+R` Action → retry selected job if status is failed
- [X] T096 [US11] Wire `Ctrl+L` Action → opens log file via `Process.run('explorer', ['/select,', logService.logPath])`
- [X] T097 [US11] Wire `Ctrl+E` Action → calls `ActivityPanel.exportCsv()` via the public method exposed in T042
- [X] T098 [US11] Wire StatusBar `?` IconButton (from T014) to open KeyboardCheatSheet (T084)
- [X] T099 [US11] Verify keyboard shortcut focus scoping: typing `?` in operator-name TextField inserts the character, NOT opens the cheat sheet (Flutter `Shortcuts` widget already scopes; verify by manual test)

**Checkpoint**: All 11 shortcuts perform documented actions; cheat sheet is discoverable; selection survives reorders.

---

## Phase 14: Polish & Cross-Cutting Concerns

**Purpose**: Refinements that span multiple stories.

- [ ] T100 Implement `recoveredJobIds: Set<int>` in `lib/database/daos/job_dao.dart` (in-memory only, no schema change). Set is populated inside `recoverStaleJobs()` on cold start with the IDs of jobs that were transitioned from in-progress to paused. Clearing semantics: an ID is removed only when the operator acts on **that specific job** (resume / cancel / delete / retry); creating an unrelated new job does NOT clear other jobs' recovery chips. (data-model.md updated.)
- [ ] T101 Update `lib/ui/widgets/confirmation_dialog.dart` with severity-aware variant (`info` / `destructive` / `critical`). **All non-conflict destructive actions MUST use the typed-confirmation pattern** (FR-047). Severity affects visual treatment only (color/icon), NOT whether typed confirmation is required. Lower-severity destructive ops (e.g., "Delete job") may use a SHORTER typed confirmation string (e.g., type `delete`) than catastrophic ones (e.g., erase SD card requires the full drive path); the typed gate itself is mandatory in all cases.
- [ ] T102 [P] Update existing destructive call sites to use the typed-confirmation `ConfirmationDialog`: "Clear history", "Delete job" (also reached by `Delete` shortcut T094), and any other non-conflict destructive flow. Erase SD Card already uses its own typed gate (preserved); no change there.
- [ ] T103 [P] Update `lib/ui/widgets/conflict_dialog.dart` to show source vs destination file sizes side-by-side per row with "identical size" / "very different" hint (FR-046); reads source size via `File(path).lengthSync()`
- [ ] T104 [P] Update `lib/ui/widgets/progress_bar.dart`: dense single-line stats (`184 MB/s · 23/49 · 12m elapsed · done by 18:14`), slow shimmer animation when active, phase indicator strip for Transfer & Compress jobs, middle-ellipsis filename
- [ ] T105 [P] Create `lib/ui/widgets/skeleton_row.dart`: configurable-height shimmering placeholder
- [ ] T106 Wire SkeletonRow into SourcesPanel (3 rows on first scan), home queue (3 rows on first job query), FilesTab (5 rows). NOT [P]: edits home_screen.dart which other tasks touch.
- [ ] T107 [P] Create `lib/ui/widgets/handbrake_banner.dart` extracted from `lib/ui/screens/create_job_screen.dart` (the existing HandBrake-not-installed banner near lines 109-133 in v2.3.0; since CreateJobScreen has been restructured by T031–T034, locate the equivalent banner block in the rewritten file and extract it)
- [ ] T108 Render HandBrakeBanner in HomeScreen's warning-banner slot (T027) alongside the existing Slack-unconfigured banner. NOT [P]: edits home_screen.dart.
- [ ] T109 [P] Add "Recovered after restart" chip on `JobCardQueued` and `JobCardNextUp` reading from `JobDao.recoveredJobIds` (T100). Chip dismisses for that job when the operator acts on it (per T100's clearing semantics).
- [ ] T110 Run `flutter pub get` (re-verify font asset resolves)
- [ ] T111 Run `flutter analyze` — must pass clean (no warnings, no errors)
- [ ] T112 Run `flutter test` — keep `widget_test.dart` placeholder green
- [ ] T113 Update `CLAUDE.md`: add 014 to feature table; bump latest release to v2.4.0; refresh "What Works" with redesign entries; remove now-stale "What's invisible" residue
- [ ] T114 Manual QA on Windows 11 against `quickstart.md` test plan — walk through all 11 user-story sections

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories. T012 (QueueStateNotifier) is critical; multiple user stories subscribe to it.
- **User Stories (Phases 3–13)**: All depend on Foundational completion. Within stories, ordering is now consistent: each story can pass its own checkpoint without depending on a later story.
- **Polish (Phase 14)**: Depends on user-story phases. T100 must precede T109. T106/T108 share `home_screen.dart` so are sequenced after parallel polish tasks. T101 must precede T102 (call-site updates) and T094 (Delete shortcut uses typed dialog).

### User Story Dependencies (intra-feature)

- **US1 (Trust at a Glance)**: depends on Foundational only — independently demoable after T027 (StatusBar installed in shell as AppBar; cards render in four variants in the existing single-pane body)
- **US2 (One-Screen Common Path)**: depends on Foundational; SourcesPanel created here but full shell integration is in US4. SourcesPanel can be demonstrated by mounting it in a test harness or temporarily as part of the home column.
- **US3 (Verification as Hero)**: depends on US1 (`JobCardActive` exists); FilesTab is created here, wired into DetailTabs in US5 (T055)
- **US4 (Three-Column Layout)**: depends on US1 (StatusBar), US2 (SourcesPanel) — composes them into the shell rewrite (T046)
- **US5 (Inline Detail with Tabs)**: depends on US1 (`JobCardActive`/`JobCardQueued`/`JobCardDone`) and US3 (FilesTab)
- **US6 (Erase Always Visible)**: depends on US1 (`JobCardActive` header slot defined in T020), Foundational T012 (QueueStateNotifier for celebration card timing)
- **US7 (Discoverable Drag and Context)**: depends on US1 (all four card variants exist), US1 T027 (warning-banner slot)
- **US8 (Plan Summary Before Commit)**: depends on US2 (CreateJobScreen restructure)
- **US9 (Settings Side-Nav)**: depends on Foundational only — independent
- **US10 (Theme Foundation & Density)**: runs as cross-cutting cleanup once other stories have created their widgets (or in parallel with each story's widget creation, applying theme as widgets are written)
- **US11 (Keyboard Cheat Sheet)**: depends on US4 (shell), US5 (`expandedJobIds`), US7 (selection-aware actions)

### Within Each User Story

- New-file tasks marked [P] within a story can be created in parallel
- Tasks that modify the same file MUST be sequenced
- Where a task references a widget/file/method created by another task, the creator MUST run first (verified by Codex review and reflected in this ordering)

### Parallel Opportunities

- T006 / T008 (foundational, different files) — parallel
- T020 / T021 / T022 / T023 (four card variant files) — parallel within US1
- T028 / T035 (sources_panel + copy_all_cards_dialog) — parallel within US2
- T051 / T052 (audit_tab + errors_tab) — parallel within US5
- T103 / T104 / T105 / T107 / T109 (polish, different files) — parallel within Phase 14

---

## Parallel Example: User Story 1

```bash
# After Foundational (Phase 2) is complete, kick off these in parallel:
Task: "Create lib/ui/widgets/queue_summary_composer.dart"                  # T013
Task: "Create lib/ui/widgets/job_card_active.dart hero variant"            # T020
Task: "Create lib/ui/widgets/job_card_next_up.dart hero variant"           # T021
Task: "Create lib/ui/widgets/job_card_queued.dart slim row"                # T022
Task: "Create lib/ui/widgets/job_card_done.dart dimmed row"                # T023
```

---

## Implementation Strategy

### MVP First (User Story 1 + Foundational)

1. Complete Phase 1: Setup (T001–T004)
2. Complete Phase 2: Foundational (T005–T012) — **CRITICAL**, blocks everything
3. Complete Phase 3: User Story 1 — Trust at a Glance (T013–T027)
4. **STOP and VALIDATE**: StatusBar replaces AppBar; cards in four variants; state readable across the room. The shell body still renders the existing single-pane layout — that's fine for MVP demo.
5. Demo on Windows 11; if approved, proceed to US2

### Incremental Delivery

Recommended order matches plan.md phase order with dependencies enforced:

1. Setup + Foundational → Theme primitives + QueueStateNotifier in place
2. US1 → StatusBar + card variants → MVP demo
3. US2 → Sources panel widget + Create Job redesign + Copy All Cards (still single-pane shell)
4. US4 → Shell rewrite composes US1's StatusBar + US2's SourcesPanel + new ActivityPanel into three columns
5. US3 → Verification badge + hash popover (uses US1's hero, FilesTab feeds into US5)
6. US5 → Inline detail tabs (uses US1's hero + US3's FilesTab)
7. US6 → Erase as header action (uses US1's hero)
8. US7 → Drag handle + overflow + failed banner (polish on US1's variants)
9. US8 → Plan summary panel (composes into US2's CreateJobScreen; replaces blocking long-path dialog)
10. US9 → Settings side-nav (independent)
11. US11 → Keyboard shortcuts + cheat sheet (uses US4's shell, US5's `expandedJobIds`)
12. US10 → Theme adoption (cross-cutting cleanup)
13. Phase 14 → Polish + flutter analyze + manual QA → tag v2.4.0

### Parallel Team Strategy

Single-developer feature (this is a solo redesign), so parallel-team strategy doesn't apply. Within a single developer's flow, [P] tasks within a phase can still be batched into one editing session.

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks
- [Story] label maps task to specific user story for traceability
- Each user story should be independently demoable on Windows 11
- All destructive operations preserve their typed-confirmation gates (Constitution Principle I, FR-047)
- No schema migration: schema v5 unchanged; all UI-layer state is in-memory
- Commit at meaningful checkpoints (typically: end of phase, or after a self-contained widget creation)
- Avoid: editing the same file in parallel tasks; introducing dependencies that break US1 → MVP demoability
- This task list reflects Codex's tasks-review (round 2). The plan itself was previously corrected after Codex's plan-review (round 1). FR-047's interpretation was corrected: typed confirmation is required for ALL non-conflict destructive actions, not just catastrophic ones — severity affects visual treatment only.
