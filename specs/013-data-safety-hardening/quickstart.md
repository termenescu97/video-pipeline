# Quickstart: Data Safety & Reliability Hardening

**Feature**: 013-data-safety-hardening  
**Date**: 2026-05-07

## What This Feature Changes

This is a hardening feature — no new UI screens, no new database tables. It fixes 14 validated bugs across data safety, crash recovery, subprocess management, and operational correctness.

## Files Modified

### Critical Path (data loss prevention)
- `lib/services/job_queue_service.dart` — per-card subfolders, conflict detection in batch, compression path fix
- `lib/ui/screens/create_job_screen.dart` — conflict detection dialog, transactional job creation
- `lib/database/daos/job_dao.dart` — `recoverStaleJobs()`, `createJobWithFiles()`, sortOrder-based queue ordering
- `lib/main.dart` — startup recovery call

### Safety & Reliability
- `lib/ui/screens/job_detail_screen.dart` — erase re-verification, size-only warning, typed confirmation
- `lib/services/transfer_service.dart` — cancellable SHA-256 via ProcessRunner
- `lib/utils/process_runner.dart` — always drain stdout/stderr
- `lib/ui/screens/shell_screen.dart` — window close intercept, awaited shutdown
- `lib/utils/instance_lock.dart` — fix PID write, fail closed

### Correctness
- `lib/services/drive_service.dart` — `_runPowerShell` helper, `$args` pattern for getDriveIdentity
- `lib/utils/constants.dart` — remove `appVersion`
- `pubspec.yaml` — version bump to 2.3.0, add `package_info_plus`

## Build & Test

```bash
# After changes
flutter pub get              # New dependency: package_info_plus
dart run build_runner build   # Regenerate Drift code (if DAO signatures change)
flutter analyze               # Must pass
flutter test                  # Must pass (fix widget_test.dart if needed)

# Manual testing on Windows
# 1. Insert two SD cards with overlapping DCIM structures → batch copy → verify subfolders
# 2. Create job to destination with existing files → verify conflict dialog
# 3. Kill app during transfer → restart → verify job recovered as paused
# 4. Stop queue during SHA-256 hashing → verify hash cancelled
# 5. Close window during transfer → verify graceful shutdown
# 6. Launch two instances → verify second is blocked
# 7. Reorder queue → start → verify processing follows display order
```

## Key Decisions

- **No schema migration**: all changes are behavioral, not structural
- **Per-card subfolder**: always `label_driveletter` format, never label-only
- **Recovery to paused**: operator must manually resume after crash
- **Conflict detection**: at job creation time, not transfer time
- **Instance lock**: keep PID file (fix bugs), don't switch to named mutex
- **SHA-256 cancellation**: route through ProcessRunner, not custom cancel token
- **Version**: single-sourced via `package_info_plus`, remove constants.dart version
