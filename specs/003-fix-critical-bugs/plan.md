# Implementation Plan: Critical Bug Fixes

**Branch**: `003-fix-critical-bugs` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/003-fix-critical-bugs/spec.md`

## Summary

Fix 6 critical bugs discovered during architecture and UX review: jobs created without files (pipeline no-op), multiple service instances (race condition), verification never called, partial completion lies, stopped queue lies, and Windows path issues. All changes are to existing files — no new dependencies or architectural changes.

## Technical Context

**Language/Version**: Dart 3.x (via Flutter SDK stable)
**Framework**: Flutter 3.x (desktop, Windows target)
**Primary Dependencies**: drift, sqflite_common_ffi, path (already installed)
**Storage**: SQLite via drift ORM (existing)
**Testing**: flutter_test (existing)
**Target Platform**: Windows 11 (x64)
**Project Type**: Desktop application — bug fix release

## Constitution Check

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Human-in-the-Loop | ✅ PASS | No change to destructive action flows |
| II. Single Codebase | ✅ PASS | All fixes in existing Dart codebase |
| III. Resilient Pipeline | ✅ PASS | Fixes directly improve resilience: actual verification, proper pause/resume, file enumeration |
| IV. Minimal Complexity | ✅ PASS | No new abstractions — fixes use existing patterns |
| V. Observable Progress | ✅ PASS | Fixes improve accuracy of reported status and Slack notifications |
| VI. Update Transparency | ✅ PASS | No change to update mechanism |

No violations.

## Changes by File

### Bug 1: Jobs Created With Zero Files

**File: `lib/ui/screens/create_job_screen.dart`**
- In `_createJob()`, after inserting the job, enumerate video files from the source path
- Use `DriveService.listVideoFiles()` (already exists) to scan the source
- For each file, create a `JobFilesCompanion` with source path, destination path (using `p.join`), file name, and file size
- Insert all files via `JobFileDao.insertFiles()`
- Update the job's `totalFiles` and `totalBytes` via `JobDao`
- If zero video files found, show error snackbar and don't create the job

**File: `lib/database/daos/job_dao.dart`**
- Add `updateJobTotals(int jobId, int totalFiles, int totalBytes)` method

### Bug 2: Multiple Service Instances (Singleton)

**File: `lib/main.dart`**
- Create and expose singleton instances of all services: `JobQueueService`, `TransferService`, `CompressionService`, `SlackService`, `DriveService`, all DAOs
- Store them as top-level `late final` variables alongside `database`

**Files: `lib/ui/screens/home_screen.dart`, `create_job_screen.dart`, `job_detail_screen.dart`, `settings_screen.dart`**
- Remove local service/DAO instantiation from `initState()`
- Import and use the singleton instances from `main.dart`

### Bug 3: Transfer Verification

**File: `lib/services/job_queue_service.dart`**
- In `_processTransfer`, after `transferService.transferFile()` succeeds, call `transferService.verifyTransfer()` with the source and destination paths
- Pass the actual verification result to `markFileCompleted(verified: actualResult)`
- If verification fails, mark file as failed with error "Verification failed: size mismatch"

**File: `lib/services/slack_service.dart`**
- Update `notifyTransferCompleted` to accept and report actual verification status instead of hardcoded "Passed"

### Bug 4: Partial Compression Status

**File: `lib/services/job_queue_service.dart`**
- In `_processCompression`, after the file loop, count how many files failed
- If any files failed: mark job as `failed` with error message "X/Y files compressed, Z failed"
- If all succeeded: mark job as `completed` (current behavior)
- Track failed count with a variable alongside `completedCount`

### Bug 5: Stopped Queue = Paused, Not Completed

**File: `lib/services/job_queue_service.dart`**
- In both `_processTransfer` and `_processCompression`, after the file loop, check if the loop was interrupted by `!_isProcessing`
- If interrupted: mark job as `paused` instead of `completed`, skip the Slack completion notification
- The existing queue startup logic already picks up `queued` jobs — also add `paused` to the pickup query

**File: `lib/database/daos/job_dao.dart`**
- Update `getNextQueuedJob()` to also pick up `paused` jobs: `status == queued OR status == paused`

### Bug 6: Windows Path Joining

**File: `lib/services/job_queue_service.dart`**
- Add `import 'package:path/path.dart' as p;`
- Replace `'$outputPath/${f.fileName}'` with `p.join(outputPath, f.fileName)`
- Apply same fix in `_createJob()` in create_job_screen.dart for destination file paths

**File: `lib/ui/screens/create_job_screen.dart`**
- Use `p.join()` when constructing destination file paths during file enumeration

### Bug 7 (cascading): Auto-Chain Only Includes Verified Files

**File: `lib/services/job_queue_service.dart`**
- In `_createChainedCompressionJob`, filter on `f.status == FileStatus.completed && f.verified` (not just `completed`)

## Architecture

No new layers or components. All changes are within existing files. The only structural change is moving service instantiation from individual screens to `main.dart` (singleton pattern).

```
Before:                          After:
HomeScreen creates services      main.dart creates services (once)
CreateJobScreen creates services All screens import from main.dart
JobDetailScreen creates services
SettingsScreen creates services
```

## Complexity Tracking

No constitution violations. No new complexity. Changes simplify the codebase (fewer service instantiations).
