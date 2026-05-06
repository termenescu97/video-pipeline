# Tasks: Medium-Priority Fixes

**Input**: Design documents from `specs/010-medium-fixes/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No automated tests — manual testing on Windows 11 per project convention.

**Organization**: Tasks grouped by user story. Schema migration is foundational (blocks US1, US2).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Foundational — Schema Migration v3→v4

**Purpose**: Add 4 new columns across AppSettings and Jobs tables. Must complete before US1 and US2.

- [x] T001 Add `lastUsedDestination`, `lastUsedOutput`, and `operatorName` text columns (default '') to `AppSettings` table in `lib/database/tables.dart`
- [x] T002 Add nullable `operatorName` text column to `Jobs` table in `lib/database/tables.dart`
- [x] T003 Bump `schemaVersion` to 4 in `lib/database/database.dart`. Add migration: `if (from < 4)` adding all 4 new columns (3 on appSettings, 1 on jobs)
- [x] T004 Add `setLastUsedDestination(String)`, `setLastUsedOutput(String)`, and `setOperatorName(String)` methods to `lib/database/daos/settings_dao.dart`
- [x] T005 Run `dart run build_runner build` to regenerate Drift code for schema v4

**Checkpoint**: Schema v4 compiles. `flutter analyze` passes.

---

## Phase 2: User Story 1 — Last-used destination auto-fill (Priority: P1) 🎯 MVP

**Goal**: Remember last-used destination and compression output paths, pre-fill on next job creation.

**Independent Test**: Create a job with destination D:\Footage. Close form, reopen. Verify D:\Footage is pre-filled.

### Implementation for User Story 1

- [x] T006 [US1] In `lib/ui/screens/create_job_screen.dart` `initState()`, load last-used destination and output paths from `settingsDao.getSettings()` and pre-fill `_destinationPath` and `_compressionOutputPath` if not empty.
- [x] T007 [US1] In `lib/ui/screens/create_job_screen.dart` `_createJobInner()`, after successful job creation, save the used destination via `settingsDao.setLastUsedDestination(_destinationPath!)` and output via `settingsDao.setLastUsedOutput(_compressionOutputPath!)` if applicable.

**Checkpoint**: Destination auto-fills across form reopens and app restarts.

---

## Phase 3: User Story 2 — Operator name tracking (Priority: P1)

**Goal**: Operator sets their name in settings; it appears on Slack notifications and job details.

**Independent Test**: Set "Alex" in settings. Run a job. Verify Slack notification includes "Operator: Alex."

### Implementation for User Story 2

- [x] T008 [US2] Add operator name TextField to `lib/ui/screens/settings_screen.dart` after the Slack webhook section. Use debounced save via `settingsDao.setOperatorName()`, same pattern as webhook URL.
- [x] T009 [US2] In `lib/ui/screens/create_job_screen.dart` `_createJobInner()`, read operator name from settings and pass it to the `JobsCompanion.insert()` call via the new `operatorName` field.
- [x] T010 [US2] In `lib/services/slack_service.dart`, add operator name to all notification methods (`notifyTransferStarted`, `notifyTransferCompleted`, `notifyTransferFailed`, `notifyCompressionStarted`, `notifyCompressionCompleted`). Include "Operator: {name}" line if `job.operatorName` is not null/empty.
- [x] T011 [US2] In `lib/ui/screens/job_detail_screen.dart`, add an `_infoRow('Operator', job.operatorName!)` line when `job.operatorName` is not null and not empty.

**Checkpoint**: Operator name shows in Slack messages and job detail screen.

---

## Phase 4: User Story 3 — CSV history export (Priority: P2)

**Goal**: Export job history as CSV via file save dialog.

**Independent Test**: Complete 3 jobs. Click Export. Verify CSV saved with correct data.

### Implementation for User Story 3

- [x] T012 [US3] Add `Future<List<Job>> getCompletedJobsList()` method to `lib/database/daos/job_dao.dart` — non-stream version of `watchCompletedJobs()` for one-time export use.
- [x] T013 [US3] Add "Export" icon button in the history section header in `lib/ui/screens/home_screen.dart` (in the Row with the "History" text). Add `_exportHistory()` method that: gets completed jobs list, generates CSV string (Date, Type, Source, Destination, Files, Size, Status, Duration, Operator), uses `FilePicker.platform.saveFile()` with default filename `copiatorul3000-history-YYYY-MM-DD.csv`, writes the file. Show snackbar on success or "No history" message if empty.

**Checkpoint**: CSV file saved with accurate job data, openable in Excel.

---

## Phase 5: User Story 4 — Relative timestamps on history cards (Priority: P2)

**Goal**: History job cards show "5 min ago", "Yesterday", or absolute date.

**Independent Test**: Complete a job. Verify card shows "Just now" or "1 min ago."

### Implementation for User Story 4

- [x] T014 [P] [US4] Add `formatRelativeTime(DateTime date)` function to `lib/utils/format_utils.dart`. Rules: <1min = "Just now", <60min = "X min ago", <24h = "X hours ago", <48h = "Yesterday", else "MMM d" (e.g., "May 3").
- [x] T015 [US4] In `lib/ui/widgets/job_card.dart`, add relative timestamp to the subtitle for completed/failed jobs. After the `$src → $dst` text, show ` · ${formatRelativeTime(job.completedAt!)}` when `job.completedAt != null`.

**Checkpoint**: History cards show accurate relative timestamps.

---

## Phase 6: User Story 5 — Favorite label path parsing fix (Priority: P3)

**Goal**: Favorite label auto-fills correctly on both Windows and macOS paths.

**Independent Test**: Save favorite with path `/Users/test/footage`. Verify label is "footage."

### Implementation for User Story 5

- [x] T016 [P] [US5] In `lib/ui/screens/create_job_screen.dart` line 351, change `path.split(r'\').last` to `p.basename(path)`.

**Checkpoint**: Labels correct for both `/forward/slash` and `\back\slash` paths.

---

## Phase 7: User Story 6 — Erase accepts lowercase drive letters (Priority: P3)

**Goal**: Drive erase validation accepts both uppercase and lowercase letters.

**Independent Test**: Validate drive path `d:\`. Verify accepted.

### Implementation for User Story 6

- [x] T017 [P] [US6] In `lib/services/drive_service.dart` line 147, change `r'^[A-Z]:\\$'` to `r'^[A-Za-z]:\\$'`.

**Checkpoint**: Lowercase drive letters accepted for erase.

---

## Phase 8: User Story 7 — Path length warning (Priority: P3)

**Goal**: Warn operator during job creation if destination paths exceed 260 characters.

**Independent Test**: Create job with very long destination. Verify warning dialog appears.

### Implementation for User Story 7

- [x] T018 [US7] In `lib/ui/screens/create_job_screen.dart` `_createJobInner()`, after file enumeration and before disk space check: iterate all files, compute `p.join(destPath, relativePath).length`, collect paths >260 chars. If any, show a dismissible `AlertDialog` listing them. Operator can proceed after dismissing.

**Checkpoint**: Warning appears for long paths. Operator can still proceed.

---

## Phase 9: User Story 8 — Disk space "N/A" for negative values (Priority: P3)

**Goal**: Show "N/A" instead of "0 B" when disk space is unavailable.

**Independent Test**: Simulate disk space returning -1. Verify "N/A" displayed.

### Implementation for User Story 8

- [x] T019 [P] [US8] In `lib/utils/format_utils.dart`, change `if (bytes <= 0) return '0 B';` to `if (bytes < 0) return 'N/A'; if (bytes == 0) return '0 B';`

**Checkpoint**: Negative values show "N/A". Zero shows "0 B".

---

## Phase 10: Polish & Cross-Cutting Concerns

- [x] T020 Run `flutter analyze` to verify zero analysis errors across all modified files
- [x] T021 Update known issues and feature table in `CLAUDE.md` to reflect 010 completion

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Foundational)**: Must complete first — schema v4 + codegen
- **Phase 2 (US1)**: Depends on Phase 1
- **Phase 3 (US2)**: Depends on Phase 1
- **Phases 4-9**: Independent of each other and Phase 1
- **Phase 10 (Polish)**: Depends on all phases complete

### Parallel Opportunities

After Phase 1:
```
Phase 2 (US1: last-used dest)     ──┐
Phase 3 (US2: operator name)      ──┤
Phase 4 (US4: timestamps)         ──┤
Phase 5 (US5: path parsing fix)   ──┼──→ Phase 10 (Polish)
Phase 6 (US6: erase regex)        ──┤
Phase 7 (US7: path length warn)   ──┤
Phase 8 (US8: formatBytes)        ──┤
Phase 9 (US3: CSV export)         ──┘
```

---

## Implementation Strategy

### Recommended Sequential Order (Solo Developer)

Group by shared files:

1. **Phase 1**: Schema migration + codegen (foundational)
2. **Quick wins**: T016 (QA-16), T017 (QA-17), T019 (QA-19) — one-line fixes, parallel
3. **format_utils.dart**: T014 (relative time) — same file as T019
4. **job_card.dart**: T015 (timestamps) — depends on T014
5. **create_job_screen.dart**: T006+T007 (US1), T009 (US2), T018 (US7) — same file, batch together
6. **settings_screen.dart**: T008 (US2)
7. **slack_service.dart**: T010 (US2)
8. **job_detail_screen.dart**: T011 (US2)
9. **home_screen.dart + job_dao.dart**: T012+T013 (US3)
10. **Phase 10**: Analyze + docs

---

## Notes

- Schema migration v3→v4 required (4 new columns)
- No new files — all modifications to existing code
- Total: 21 tasks across 10 phases
- PM-10 (selective file copy) deferred to v3.0
- QA-15 already fixed in feature 009
