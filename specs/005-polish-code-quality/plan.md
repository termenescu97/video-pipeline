# Implementation Plan: Polish & Code Quality

**Branch**: `005-polish-code-quality` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)

## Summary

Code deduplication, desktop power-user features (keyboard shortcuts, right-click, drag-reorder, system tray), visual consistency (theme extensions), and security/stability hardening (path validation, debounce, error handling).

## Technical Context

**New Dependencies**: `tray_manager` (system tray icon)
**Built-in features used**: `ReorderableListView`, `Shortcuts`/`Actions`, `GestureDetector.onSecondaryTapDown`, `ThemeExtension`, `Timer` (debounce)

## Constitution Check

All 6 principles pass. No violations.

## New Files

| File | Purpose |
|------|---------|
| `lib/utils/process_runner.dart` | Shared subprocess stdout streaming utility |
| `lib/database/extensions.dart` | Extension methods on JobType and JobStatus (label, color) |

## Files Modified

| File | Changes |
|------|---------|
| `pubspec.yaml` | Add `tray_manager` |
| `lib/ui/theme/app_theme.dart` | Add `StatusColors` ThemeExtension |
| `lib/ui/widgets/job_card.dart` | Use extensions, add right-click menu, remove duplicate labels |
| `lib/ui/screens/job_detail_screen.dart` | Use extensions, use formatBytes, use watchJob |
| `lib/ui/screens/home_screen.dart` | Add keyboard shortcuts, use ReorderableListView, drive refresh feedback, queue hint |
| `lib/ui/screens/create_job_screen.dart` | Rename "Both" to "Copy & Compress", drive refresh feedback |
| `lib/ui/screens/shell_screen.dart` | Wrap with Shortcuts/Actions, remove FAB, add system tray init |
| `lib/ui/screens/settings_screen.dart` | Debounce webhook save |
| `lib/services/transfer_service.dart` | Use ProcessRunner |
| `lib/services/compression_service.dart` | Use ProcessRunner |
| `lib/services/drive_service.dart` | Add path validation regex |
| `lib/services/job_queue_service.dart` | Use videoExtensions constant in batch method |
| `lib/services/slack_service.dart` | Use formatBytes |
| `lib/database/daos/job_dao.dart` | Add watchJob(id) method |
| `lib/app.dart` | Wrap _checkForUpdates in try-catch |
| `lib/main.dart` | Wrap database in class (optional) |
