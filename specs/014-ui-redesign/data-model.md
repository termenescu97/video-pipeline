# Data Model: UI/UX Redesign — Visual Hierarchy & Operator Trust

**Feature**: 014-ui-redesign
**Date**: 2026-05-07
**Schema Version**: 5 → 5 (no migration)

## Summary

This feature is a UI-layer redesign. **No database schema changes.** All entity surfaces remain identical to v2.3.0. The only state additions live in client-side widgets and an in-memory cache for "Recovered after restart" tracking.

## Existing entities (unchanged)

| Entity | Notes |
|--------|-------|
| Job | All columns and state transitions identical to v2.3.0. |
| JobFile | Hashes already exist (`sourceHash`, `destinationHash`); UI now surfaces them differently. |
| FavoritePath | Unchanged. Stays inside Create Job. |
| AppSettings | One *optional* additional column considered (see below); decision is to defer. |

## Optional / deferred schema considerations

### AppSettings — Slack last-test result

The Settings → Notifications panel will display "Last test: OK 11:42" persistently. Persistence requires storage somewhere.

**Decision**: Store in-memory only for v2.4 (resets on app restart). If persistence is requested later, add `lastSlackTestResult: text` and `lastSlackTestAt: dateTime` columns in a future feature with a schema migration. The "last test" indicator gracefully degrades to "Untested" on launch — not a regression.

**Rationale**: Avoids touching schema for a low-value persistence guarantee. The operator typically tests Slack once, sees the result, walks away. They don't need to see the test from yesterday.

### JobFile — recovery flag

To render a "Recovered after restart" chip, we need to know which jobs were touched by `recoverStaleJobs()` on the most recent launch.

**Decision**: Track in memory only — `JobDao` exposes a `Set<int> recoveredJobIdsThisSession` populated when `recoverStaleJobs()` runs; cards read from it. An ID is removed from the set only when the operator acts on *that specific recovered job* (resume / cancel / delete / retry). Creating an unrelated new job does NOT clear chips on other jobs.

**Rationale**: Persisting a "was recovered" flag would require a column update on every recovery and a column read on every card render. The in-memory set is simpler and matches the lifetime of the indicator (single session, until new operator action).

## New client-side state

These are not database entities — just UI state that lives in widgets or shared providers.

| State | Owner | Purpose |
|-------|-------|---------|
| `recentlyDoneStartedAt: DateTime?` | StatusBar | Drives the 5-minute green-dot timer. Set when queue empties; cleared on next user action. |
| `recoveredJobIds: Set<int>` | JobDao (in-memory) | Drives the "Recovered after restart" indicator. Set in `recoverStaleJobs()`; an ID is removed only when the operator acts on that specific job (resume/cancel/delete/retry). |
| `lastSlackTestResult: ({DateTime at, bool success})?` | SettingsScreen | Drives the persistent "Last test: …" line. Lives only in widget state. |
| `selectedQueueJobId: int?` | ShellScreen | Drives keyboard navigation (`↑/↓` selection) and `Space`/`Enter` actions on the queue. |
| `expandedJobIds: Set<int>` | HomeScreen | Tracks which job cards are expanded inline. Multiple cards may be expanded simultaneously. |
| `currentSettingsTab: SettingsSection` | SettingsScreen | Side-nav active tab. Defaults to Notifications. |
| `currentDetailTab: DetailTabKey` | Per JobCardActive | Active tab in the detail tabs (Files/Audit/Errors). Defaults to Files. |
| `filesTabFilter: FileStatus?` | Per FilesTab | Filter chip state. `null` = "All". |

None of these require schema changes or migrations.

## Path / behavior changes (no model impact)

- **Erase action location**: moves from `JobDetailScreen` body to active card header. The action invokes the same `EraseDriveAction` widget, which calls the same `driveService.eraseDrive(...)`. No model change.
- **Activity column grouping**: `jobDao.watchCompletedJobs()` returns the existing list; the panel groups by `completedAt` date in the widget. No model change.
- **Sources panel polling**: `driveService.getRemovableDrives()` is called every 3 seconds via a `Timer.periodic`. No model change.
- **Conflict dialog size comparison**: the dialog now reads source-file size via `File(path).lengthSync()` and shows it next to the existing destination size. No model change.

## Migration plan

None required. v2.3.0 and v2.4.0 use identical Drift schema (v5).
