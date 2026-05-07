# Quickstart: UI/UX Redesign — Visual Hierarchy & Operator Trust

**Feature**: 014-ui-redesign
**Date**: 2026-05-07

## What this feature changes

UI-layer redesign of v2.3.0. No schema changes. No changes to transfer/compress/recovery logic — all that stays exactly as it shipped in 013. Minor read-only additions are made to surface diagnostics in Settings: a new `instanceLock.diagnostic()` getter exposes the current lock state, and the existing HandBrake detection result is read from a getter rather than re-detected.

## Files modified

### Theme foundation (Phase A)
- `lib/ui/theme/app_theme.dart` — density, text scale, StatusColors usage
- `lib/ui/theme/insets.dart` (NEW) — spacing scale 4/8/12/16/24/32
- `lib/ui/theme/text_styles.dart` (NEW) — display/headline/title/body/caption + tabular figures
- `pubspec.yaml` — bump to 2.4.0+1, declare JetBrains Mono asset
- `lib/main.dart` — min window 1280×720
- `assets/fonts/JetBrainsMono-Regular.ttf` (NEW)

### Shell + status bar (Phase B)
- `lib/ui/screens/shell_screen.dart` — three-column layout, status bar replaces AppBar
- `lib/ui/widgets/status_bar.dart` (NEW) — state dot, summary, operator, settings, ?

### Sources panel (Phase C)
- `lib/ui/widgets/sources_panel.dart` (NEW) — left column, live SD card list

### Activity panel (Phase D)
- `lib/ui/widgets/activity_panel.dart` (NEW) — right column, history grouped by day

### Job card variants + queue (Phase E)
- `lib/ui/widgets/job_card.dart` — becomes a variant router
- `lib/ui/widgets/job_card_active.dart` (NEW)
- `lib/ui/widgets/job_card_next_up.dart` (NEW)
- `lib/ui/widgets/job_card_queued.dart` (NEW)
- `lib/ui/widgets/job_card_done.dart` (NEW)

### Detail tabs (Phase F)
- `lib/ui/widgets/detail_tabs.dart` (NEW)
- `lib/ui/widgets/files_tab.dart` (NEW)
- `lib/ui/widgets/audit_tab.dart` (NEW)
- `lib/ui/widgets/errors_tab.dart` (NEW)
- `lib/ui/widgets/erase_drive_action.dart` (NEW — extracted from JobDetailScreen)
- `lib/ui/screens/job_detail_screen.dart` — kept for backwards compat; primary content now in tabs

### Create Job redesign (Phase G)
- `lib/ui/screens/create_job_screen.dart` — collapsed common path
- `lib/ui/widgets/plan_summary_panel.dart` (NEW)
- `lib/ui/widgets/handbrake_banner.dart` (NEW — extracted)

### Copy All Cards (Phase H)
- `lib/ui/widgets/copy_all_cards_dialog.dart` (NEW)
- `lib/ui/screens/home_screen.dart` — call site changes

### Settings side-nav (Phase I)
- `lib/ui/screens/settings_screen.dart` — side-nav layout

### Dialogs (Phase J)
- `lib/ui/widgets/confirmation_dialog.dart` — severity-aware variant
- `lib/ui/widgets/conflict_dialog.dart` — side-by-side sizes

### Shortcuts + cheat sheet (Phase K)
- `lib/ui/widgets/keyboard_cheat_sheet.dart` (NEW)
- `lib/ui/screens/shell_screen.dart` — additional shortcuts

### States (Phase L)
- `lib/ui/widgets/skeleton_row.dart` (NEW)
- Various screens — empty/loading/error treatments

### Polish (Phase M)
- `CLAUDE.md` — feature table update, v2.4.0 release notes

## Build and verify

```bash
# After all changes
flutter pub get          # New asset declaration: JetBrains Mono
flutter analyze          # Must pass — clean
flutter test             # Must pass — keep widget_test.dart placeholder

# Optional: visual diff smoke test
# Run the app, take screenshots before/after key screens
flutter run -d windows   # If on Windows host
```

## Manual QA on Windows 11

Run through this list on the team's actual workstation before merging.

### Trust at a glance (US1)

- [ ] Stand 3 meters from screen with no jobs running. State dot is grey.
- [ ] Start a job. Within 1 second, state dot transitions to blue and queue summary updates with time-of-day completion.
- [ ] Wait for the job to complete. State dot turns green. Active slot shows "All cards copied & verified."
- [ ] Wait 5 minutes without any user action. Green reverts to grey.
- [ ] Repeat — green dot, then click "Copy All Cards" within 5 minutes. Green dismisses immediately.
- [ ] Misconfigure Slack (clear webhook). State dot is orange. Restore webhook; warning clears.
- [ ] Force a job failure (e.g., point at a read-only destination). State dot turns red. Failed job is grouped at top of queue with "1 failed — review" banner.
- [ ] Hover the system tray icon. Tooltip text matches the status bar summary.

### One-screen common path (US2)

- [ ] Insert two SD cards. They appear in the Sources column without manual refresh.
- [ ] Click one card. Create Job opens with that card pre-selected as source.
- [ ] Click "Copy All Cards" from the queue panel's hero state. Dialog shows detected cards FIRST (with checkboxes), then destination, then verification mode.
- [ ] Pick a destination in Create Job. Plan summary updates live with files, bytes, and free-space verdict (no ETA).
- [ ] Pick a destination with insufficient space. Plan summary shows "60 GB free — won't fit" inline. No blocking dialog.
- [ ] Pick a destination with conflicting files. Plan summary shows "N files conflict" inline.

### Verification as hero (US3)

- [ ] Run a SHA-256 transfer. Active hero card shows verification badge.
- [ ] Open Files tab during transfer. Verified rows show "✓ matches" badge.
- [ ] Click a "✓ matches" badge. Side popover opens with both source and destination hashes in JetBrains Mono. "Copy both" button works (paste somewhere, confirm).
- [ ] After job completes successfully, active slot shows green "All cards copied & verified" with [Erase Cards] [New Job] CTAs.

### Three-column layout (US4)

- [ ] Open the app at 1280×720. All three columns visible. Queue cards show full source → destination paths.
- [ ] Try to resize below 1280×720. Window snaps back to minimum.
- [ ] Insert SD cards while running. Sources column updates live.
- [ ] Activity column groups completed jobs by day (Today / Yesterday / This week / Older).
- [ ] Activity column has prominent "Export CSV" button at the bottom. Click it; CSV file is created.

### Inline detail with tabs (US5)

- [ ] Click an active job card. Detail expands inline. Three tabs visible: Files / Audit / Errors.
- [ ] On a job with no errors, Errors tab shows "(0)" and the body shows empty-state copy.
- [ ] On Files tab with 200+ files, scroll smoothly without jank.
- [ ] Filter chips (All / Pending / In progress / Completed / Failed) filter the list.

### Erase always visible (US6)

- [ ] During an active transfer, view detail header. Erase button is visible but disabled with "Waiting for SHA-256 verification" text.
- [ ] After the job completes verified, button is enabled.
- [ ] Click Erase. Confirmation dialog appears with: drive identity, typed-confirmation field, size-only warning (if applicable). Identical safety gates as v2.3.0.
- [ ] Swap the SD card during the dialog. Click Erase. Dialog aborts with "Drive changed" snackbar.

### Discoverable drag + context (US7)

- [ ] On a queued job card, see a `☰` drag handle on the right.
- [ ] Drag the handle to reorder. Queue rearranges; queue processor processes in new order.
- [ ] Click the card body (not handle). Card expands inline (no drag triggered).
- [ ] Click `⋯` overflow on a card. Menu opens with all the same actions as right-click.

### Plan summary before commit (US8)

- [ ] Create Job: pick source. Plan summary shows files and bytes.
- [ ] Pick destination. Free-space verdict appears as a sentence.
- [ ] Pick a destination with paths > 260 chars. Yellow inline note: "N files have paths > 260 chars."
- [ ] Pick a destination with existing files. Conflict count shown inline. Click "Add to Queue"; conflict dialog appears (typed-overwrite still required).

### Settings side-nav (US9)

- [ ] Open Settings. See five sections in left nav: Notifications / Operator / Behavior / Diagnostics / About.
- [ ] In Notifications, type a Slack URL. "Saved ✓" appears briefly after debounce.
- [ ] Click "Test now". Result and timestamp persist as "Last test: OK 11:42" until next app launch.
- [ ] Open Diagnostics. Log file path with "Reveal in Explorer" button works (opens Explorer with file selected).
- [ ] Open About. Shows correct app version (2.4.0).

### Theme + density (US10)

- [ ] Inspect any screen. Numbers (speed, ETA, percentage) don't shift surrounding layout as digits change.
- [ ] Paths and SHA-256 hashes use JetBrains Mono.
- [ ] Density compact: queue shows ~25% more content than v2.3.0 default.

### Keyboard cheat sheet (US11)

- [ ] Press `?` from the main shell. Cheat sheet modal opens.
- [ ] Press `Esc`. Modal dismisses.
- [ ] Test each documented shortcut: `Ctrl+N` (new job), `Ctrl+Shift+C` (copy all cards), `Ctrl+Enter` (pause/resume), `Ctrl+,` (settings), `Ctrl+E` (export CSV), `Ctrl+L` (open log), `↑/↓` (queue selection), `Space` (toggle expand), `Delete` (remove with confirm), `Ctrl+R` (retry failed), `?`/`F1` (cheat sheet).
- [ ] Type `?` in the operator-name TextField. Should insert "?" character, not open cheat sheet.

## Key decisions

- **No schema migration** — UI-only changes
- **No new dependencies** — package_info_plus already present from 013
- **Material 3 stays** — seeded blue with tightened scales (Insets, AppTextStyles)
- **Inline detail, not a route** — JobDetailScreen kept registered for backwards compat
- **No dark mode** — deferred; theme infrastructure doesn't block adding it later
- **No ETA pre-flight** — only on running cards; pre-flight estimates are unreliable
- **Min window 1280×720** — three-column always on, no responsive collapse
