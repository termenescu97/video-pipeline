# Implementation Plan: Medium-Priority Fixes

**Branch**: `010-medium-fixes` | **Date**: 2026-05-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/010-medium-fixes/spec.md`

## Summary

Implement 8 medium-priority quality-of-life improvements: last-used destination auto-fill, operator name tracking, CSV history export, relative timestamps on history cards, and 4 quick code fixes (favorite path parsing, lowercase drive erase, path length warning, formatBytes negative handling). Requires schema v4 migration for 4 new columns.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (3.41.9)
**Primary Dependencies**: Drift (SQLite ORM), file_picker, path package
**Storage**: SQLite via Drift (schema v3 → v4)
**Testing**: Manual testing on Windows 11
**Target Platform**: Windows 11 desktop
**Project Type**: Desktop app
**Scale/Scope**: 8 fixes across 12 files, 1 schema migration

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | PASS | Path length warning is dismissible, not blocking |
| II. Single Codebase | PASS | All Dart |
| III. Resilient Pipeline | PASS | No pipeline changes |
| IV. Minimal Complexity | PASS | No new dependencies; CSV via string concatenation; relative time via simple function |
| V. Observable Progress | PASS | Operator name improves accountability; CSV export adds reporting |
| VI. Update Transparency | PASS | No changes |

## Project Structure

### Source Code (files to modify)

```text
lib/
├── database/
│   ├── tables.dart              # PM-6, PM-7 (4 new columns)
│   ├── database.dart            # Schema v4 migration
│   └── daos/
│       ├── settings_dao.dart    # PM-6, PM-7 (setter methods)
│       └── job_dao.dart         # PM-8 (getCompletedJobs for export)
├── services/
│   ├── slack_service.dart       # PM-7 (operator in notifications)
│   └── drive_service.dart       # QA-17 (regex fix)
├── ui/
│   ├── screens/
│   │   ├── create_job_screen.dart # PM-6, PM-7, QA-16, QA-18
│   │   ├── settings_screen.dart   # PM-7 (operator name field)
│   │   ├── home_screen.dart       # PM-8 (export button)
│   │   └── job_detail_screen.dart # PM-7 (show operator)
│   └── widgets/
│       └── job_card.dart          # PM-9 (relative timestamp)
└── utils/
    └── format_utils.dart          # PM-9, QA-19 (relative time + N/A)
```

## Changes by Issue

### PM-6: Last-used destination
- `tables.dart`: Add `lastUsedDestination`, `lastUsedOutput` text columns to AppSettings
- `settings_dao.dart`: Add `setLastUsedDestination(String)`, `setLastUsedOutput(String)`
- `create_job_screen.dart`: In `initState()` load last-used paths; in `_createJobInner()` save used paths after job creation

### PM-7: Operator name
- `tables.dart`: Add `operatorName` text column to AppSettings + nullable `operatorName` to Jobs
- `settings_dao.dart`: Add `setOperatorName(String)`
- `settings_screen.dart`: Add TextField for operator name with debounce save
- `create_job_screen.dart`: Read operator name from settings, pass to job insert
- `slack_service.dart`: Include `job.operatorName` in notification messages (skip if null/empty)
- `job_detail_screen.dart`: Show operator name in info rows

### PM-8: CSV export
- `home_screen.dart`: Add Export icon in history header; `_exportHistory()` method generates CSV and saves via `FilePicker.platform.saveFile()`
- `job_dao.dart`: Add `getCompletedJobs()` (non-stream version for export)

### PM-9: Relative timestamps
- `format_utils.dart`: Add `formatRelativeTime(DateTime)` function
- `job_card.dart`: Show relative timestamp in subtitle for completed/failed jobs

### QA-16: path.split fix → `p.basename(path)` on line 351
### QA-17: regex fix → `r'^[A-Za-z]:\\$'` on line 147
### QA-18: Path length warning after file enumeration in `_createJobInner()`
### QA-19: `if (bytes < 0) return 'N/A'` in formatBytes

## Complexity Tracking

No constitution violations. No complexity tracking needed.
