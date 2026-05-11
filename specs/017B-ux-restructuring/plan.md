# 017B Implementation Plan — UX Restructuring

## Architecture changes

### Layout (`lib/ui/screens/shell_screen.dart`)

Before:
```
[ SourcesPanel 240px ]
[ Center: queue + active card (flex) ]
[ VerticalDivider ]
[ ActivityPanel 300px ]                  ← REMOVED
[ VerticalDivider ]
[ CreateJobScreen 360px (always shown) ] ← Auto-hide
```

After:
```
[ SourcesPanel 240↔48px (collapsible) ]
[ Center: queue + active card + History (flex) ]
[ Optional: CreateJobScreen 360px when _showCreateJob ]
```

### History surface (`lib/ui/widgets/history_surface.dart`)

New widget. Subscribes to `jobDao.watchCompletedJobs(limit: 1000)`,
applies in-memory filter pipeline (search + status), renders via
`ListView.builder` for virtualization. CSV export entry stays in the
home-screen action bar (not duplicated inside HistorySurface).

### Sources panel collapsibility (`lib/ui/widgets/sources_panel.dart`)

`AnimatedContainer` switches width between 240 and 48. Collapsed
state shows a stacked column of SD-card icons + chevron-right at the
top. Expanded shows full list + chevron-left.

## Critical files

- `lib/ui/screens/shell_screen.dart` — B1 + B3 + B4
- `lib/ui/widgets/sources_panel.dart` — B3 + B11
- `lib/ui/screens/home_screen.dart` — B6 (replaces Done section with HistorySurface)
- `lib/ui/widgets/history_surface.dart` — B6/B7/B8 (new)
- `lib/ui/widgets/files_tab.dart` — B5 (filter chip horizontal-scroll)
- `lib/ui/screens/settings_screen.dart` — B10 (Diagnostics: Recent failures)
- `lib/database/daos/settings_dao.dart` — B3 persistence (sourcesPanelCollapsed already added in 017A's v8 migration)

## Phase ordering

**Phase 1 — Filter chip horizontal scroll (lowest risk).**
- B5 alone. Self-contained `Wrap` → `SingleChildScrollView(Row)` swap.
- Lands first to confirm the operator's narrowest pain point is fixed.

**Phase 2 — Sources panel collapsibility.**
- B3 + B11. Requires SettingsDao read/write hookup.

**Phase 3 — Layout restructuring.**
- B1 + B4. Drop ActivityPanel, gate CreateJobScreen pane render. The
  most visually disruptive change; lands AFTER Phase 1/2 are validated.

**Phase 4 — History surface.**
- B6 + B7 + B8 + B9. New widget; replaces the existing Done section.
  Status filter chips include Unverified + Mismatch (Codex M6 hard requirement).

**Phase 5 — Diagnostics enhancement.**
- B10 alone. Settings → Diagnostics → Recent failures expandable list.

## Constitution gate

| Principle | Compliance | Note |
|-----------|------------|------|
| I — Human-in-the-Loop | ✅ | No new destructive actions. Collapse + auto-hide are operator-controlled. |
| II — Single Codebase | ✅ | Zero new deps; pure Flutter widget refactor. |
| III — Resilient Pipeline | ✅ | UI-only; executor untouched. |
| IV — Minimal Complexity | ✅ | Removes a panel, replaces a `Wrap` with a scroller, persists one bool. |
| V — Observable Progress | ✅ | Strengthens it — verify-axis outcomes promoted to history + diagnostics. |
| VI — Update Transparency | ✅ | No change to update flow. |

## Risks

1. **History surface performance with 1 000+ jobs**: virtualization via
   `ListView.builder`, but `Job.watchCompletedJobs` returns the full
   list — convert to a paged DAO query if performance regresses.
2. **Sources panel auto-expand interfering with manual collapse**:
   only auto-expand when a NEW drive appears (compare against
   previously-seen drive paths), not on every poll tick.
3. **Ctrl+H collision with Ctrl+H = Help in some apps**: the project
   currently uses `?` and `F1` for help; Ctrl+H is free per the 12
   documented shortcuts.
4. **CreateJobScreen auto-hide racing with onJobCreated callback**:
   ensure setState(() => _showCreateJob = false) lands before the
   navigation, not after.

## Verification

### Pre-build (macOS)
- `flutter analyze` clean.
- All existing 78 tests still pass.
- New widget tests for HistorySurface filter behavior.

### Windows acceptance (T067 piggy-back)
- Filter chips single-row at 280-px column.
- Sources collapses to 48 px; Ctrl+1 toggles; persists across restart.
- Sources auto-expands on new card insert.
- CreateJob pane auto-hides; Ctrl+N opens, save closes.
- ActivityPanel gone; center column expanded.
- History search finds a job by partial source path; status filter
  narrows to Mismatch.
- Diagnostics → Recent failures lists a known-bad job from the test
  set.
