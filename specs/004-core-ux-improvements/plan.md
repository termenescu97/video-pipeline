# Implementation Plan: Core UX Improvements

**Branch**: `004-core-ux-improvements` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/004-core-ux-improvements/spec.md`

## Summary

Transform the app from a developer prototype into a polished desktop tool for non-technical video editors. 10 user stories covering: batch copy, disk space awareness, retry, ETA/speed, subprocess cancellation, erase safety, master-detail layout, job history, error guidance, and small UX fixes.

## Technical Context

**Language/Version**: Dart 3.x (via Flutter SDK stable)
**Framework**: Flutter 3.x (desktop, Windows target)
**New Dependencies**: `window_manager` (minimum window size)
**Existing Dependencies**: win32, drift, dio, file_picker, path (all already installed)
**Target Platform**: Windows 11 (x64)
**Project Type**: Desktop application — UX improvement release

## Constitution Check

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Human-in-the-Loop | ✅ PASS | Erase safety gates strengthened; retry requires confirmation; batch copy requires destination confirmation |
| II. Single Codebase | ✅ PASS | All changes in existing Flutter/Dart codebase |
| III. Resilient Pipeline | ✅ PASS | Retry, subprocess cancellation, and resume improve resilience |
| IV. Minimal Complexity | ✅ PASS | Master-detail uses built-in Flutter widgets, no new frameworks |
| V. Observable Progress | ✅ PASS | ETA, speed, current file name, disk space — all improve observability |
| VI. Update Transparency | ✅ PASS | No change to update mechanism |

## New Files

| File | Purpose |
|------|---------|
| `lib/utils/error_mapper.dart` | Maps raw error strings to human-friendly messages |
| `lib/utils/format_utils.dart` | Shared formatters: file size, duration, speed |
| `lib/ui/screens/shell_screen.dart` | Master-detail shell (replaces HomeScreen as app entry) |

## Files Modified

| File | Changes |
|------|---------|
| `pubspec.yaml` | Add `window_manager` dependency |
| `lib/main.dart` | Add window_manager init, set minimum size |
| `lib/app.dart` | Route to ShellScreen instead of HomeScreen |
| `lib/ui/screens/home_screen.dart` | Refactor to be the left panel (queue list only); add "Copy All Cards" button; show snackbar on start/stop |
| `lib/ui/screens/create_job_screen.dart` | Add disk space display next to destination picker; add space warning; wrap _createJob in try-catch |
| `lib/ui/screens/job_detail_screen.dart` | Add retry button; move erase to bottom; gate erase on verification; add drive identity check; show ETA/speed; show current file name; use error_mapper for friendly errors |
| `lib/ui/screens/settings_screen.dart` | No changes needed |
| `lib/ui/widgets/job_card.dart` | Shorten paths (last folder name + tooltip); show progress % and current file on active jobs |
| `lib/ui/widgets/progress_bar.dart` | Add ETA, elapsed, speed fields |
| `lib/services/transfer_service.dart` | Store Process reference; add cancel() method; expose progress stream |
| `lib/services/compression_service.dart` | Store Process reference; add cancel() method; expose progress stream |
| `lib/services/job_queue_service.dart` | Wire cancel on stop; add retry method; batch job creation |
| `lib/services/drive_service.dart` | Add getDiskFreeSpace() method; add getDriveInfo() for identity verification |
| `lib/database/daos/job_dao.dart` | Add watchCompletedJobs() for history; add resetJobForRetry() |

## Architecture

### Master-Detail Shell

```
ShellScreen (StatefulWidget)
├── Row
│   ├── SizedBox(width: 320) ── HomeScreen (queue list, left panel)
│   ├── VerticalDivider
│   └── Expanded ── [selected content: JobDetailScreen | CreateJobScreen | empty]
```

State: `_selectedJobId` and `_showCreateJob` held in `ShellScreen`. Callbacks passed to `HomeScreen`. Settings remains a separate pushed route.

### Subprocess Cancellation Flow

```
User taps "Stop Queue"
  → JobQueueService.stopProcessing()
    → _isProcessing = false
    → transferService.cancel() OR compressionService.cancel()
      → process.kill()  (Windows: TerminateProcess)
    → Current file marked as "pending"
    → Job marked as "paused"
```

### Error Mapping

```
error_mapper.dart:
  "Access is denied" → "The destination folder is protected. Try running as Administrator."
  "There is not enough space" → "Destination drive is full. Free up space or choose a different drive."
  "The system cannot find the path" → "Source path no longer exists. The SD card may have been removed."
  [default] → "An unexpected error occurred." + expandable raw error
```

## Complexity Tracking

No constitution violations. The master-detail layout is the biggest structural change but uses only built-in Flutter widgets.
