# 017B — UX Restructuring (v2.5.0 second half)

**Branch**: `017-ux-restructuring`
**Status**: in progress (post-017A, ships under v2.5.0 tag)
**Date**: 2026-05-08

## Why

The operator's 2026-05-08 Windows test exposed three UX failures alongside
the executor-correctness blockers (which 017A closed):

1. The right-side ActivityPanel and the third-column CreateJobScreen are
   open all the time — the center column with the active-job card is
   squeezed even though that's where the operator looks during a run.
2. Filter pills (All / Pending / In progress / Completed / Failed) wrap
   to 3 rows at column widths the operator typically uses; counts
   become unreadable.
3. Cross-job history awareness (which jobs failed, which finished
   recently) is currently provided by the ActivityPanel — if the
   panel is dropped without a replacement, that signal is lost.

A handful of smaller items round it out: Sources panel collapsibility,
phase-indicator promotion (already partially done in 017A), and a
"recent failures" section in Settings → Diagnostics so the operator
can triage non-clean completions without parsing log lines.

## User stories

### US-B1 (P1) — Center column owns the workspace

**As an** operator running a transfer + compress job
**I want** the active-job card and queue to expand to fill horizontal
space when the CreateJobScreen isn't open and the SourcesPanel is
collapsed
**So that** my live progress, ETA, file list, and verify state are all
visible without horizontal scrolling.

**Acceptance**:
- ActivityPanel is removed entirely; the center column flexes to fill
  the freed width.
- CreateJobScreen pane is shown only when the operator is actively
  creating a job (via Ctrl+N or "Add job" button); auto-hides on
  successful save / cancel.
- SourcesPanel is collapsible to a 48-px icon strip via Ctrl+1 or a
  chevron in its header; collapsed state persists across launches.

### US-B2 (P1) — Filter pills don't wrap

**As an** operator looking at a long file list inside a job
**I want** the filter chips (All / Pending / In progress / Completed /
Failed) to stay on a single horizontal row even when the column is
narrow
**So that** I can quickly switch between filters without scanning a
3-row layout for the chip I want.

**Acceptance**:
- The chip row is a single horizontal scroller.
- Counts remain visible inside each chip label.
- Existing chip selection / theming behavior preserved.

### US-B3 (P2) — Cross-job history is first-class, not hidden in a panel

**As an** operator triaging the day's runs at end-of-shift
**I want** a search box, status filter, and date sort over the full job
history (not just the most-recent few)
**So that** I can find a specific job by source path / operator / date
range and inspect its outcome.

**Acceptance**:
- The Done section in the queue / home screen becomes a virtualized
  infinite-scroll history surface.
- Search box filters by source path AND operator name (case-
  insensitive substring).
- Status filter chips: All / Verified / **Unverified** / **Mismatch**
  / Failed / Active-recent (Codex round-1 M6 hard requirement —
  unverified + mismatch must be first-class).
- Ctrl+H focuses the search box.
- CSV export entry retained.

### US-B4 (P2) — Diagnostics surfaces failures without log parsing

**As an** operator who's just finished a run that completed with a
warning ("⚠ 2 file(s) UNVERIFIED")
**I want** Settings → Diagnostics → "Recent failures" to list the
affected jobs/files
**So that** I can investigate without grepping through copiatorul3000.log.

**Acceptance**:
- Diagnostics gains a "Recent failures" section.
- Lists jobs with `failureKind != none` OR any file at `verifyStatus =
  mismatch / unverified`, newest first.
- Tapping a row opens the job's detail view.

## Functional requirements

| FR | Description |
|----|-------------|
| FR-B01 | ActivityPanel removed from `shell_screen.dart` (right column + VerticalDivider). |
| FR-B02 | CreateJobScreen pane only renders when `_showCreateJob == true`; the empty-state placeholder for the right pane is removed. |
| FR-B03 | SourcesPanel toggles between 240 px (expanded) and 48 px (icon strip) via Ctrl+1 OR chevron button in the panel header. State persists in `AppSettings.sourcesPanelCollapsed` (already added in 017A's v8 migration). |
| FR-B04 | Auto-expand SourcesPanel when a new SD card is detected (so a card insert is never invisible). |
| FR-B05 | Filter chip row in `files_tab.dart` becomes a horizontal scroller. |
| FR-B06 | Home screen's Done section is replaced by a `HistorySurface` widget: search box + status filter chips + virtualized list. |
| FR-B07 | History search filters by `Job.sourcePath` AND `Job.operatorName` (case-insensitive substring). |
| FR-B08 | History status filter chips include Unverified and Mismatch as distinct from Failed (Codex round-1 M6). |
| FR-B09 | Ctrl+H focuses the history search box (uses currently-unused shortcut slot). |
| FR-B10 | Diagnostics gains a "Recent failures" expandable section enumerating jobs with non-clean verify outcomes. |
| FR-B11 | The collapsed SourcesPanel shows a stacked SD-card icon for each detected drive so an inserted card is still visible without expanding. |

## Out of scope (deferred to v3.0)

- Date-range filter / timeline visualization on history (basic newest-
  first sort is sufficient for the operator's workflow).
- Multi-select bulk actions on history rows.
- Saved searches / search history.

## Success criteria

- SC-B01: With CreateJobScreen closed and SourcesPanel collapsed, the
  active-job card occupies at least 80 % of the window width at the
  default 1280-px width (currently ~50 %).
- SC-B02: Filter chip row never wraps at column widths ≥ 280 px.
- SC-B03: History search returns matches within 100 ms for a database
  with 1 000 historical jobs.
- SC-B04: Operator can locate a specific failed job via search + filter
  in fewer than 5 keystrokes (verified in T067 acceptance).

## Constitution alignment

- **Principle V (Observable Progress)**: makes verify-axis outcomes
  durably visible (history + diagnostics) instead of ephemeral panel
  signals.
- **Principle I (Human-in-the-Loop)**: collapsible Sources + auto-hide
  Create panel keeps decisions explicit (no chrome consumes operator
  attention without consent).
- **Principle II (Single Codebase)**: zero new dependencies; pure
  Flutter widget refactor + AppSettings persistence already shipped
  in 017A.

## References

- `~/.claude/plans/i-just-did-a-glistening-lake.md` — original v2.5.0
  plan covering both 017A and 017B.
- 017A `specs/017-executor-correctness/` — sibling feature (executor
  correctness pass).
