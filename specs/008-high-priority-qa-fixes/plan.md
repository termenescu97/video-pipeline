# Implementation Plan: High-Priority QA Bug Fixes

**Branch**: `008-high-priority-qa-fixes` | **Date**: 2026-05-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/008-high-priority-qa-fixes/spec.md`

## Summary

Fix 8 high-priority QA bugs from the v2.0.0 review: race condition guard verification, chained compression missing totals, preset validation, reorder indices mismatch, retry counter reset, context menu retry handler, settings null safety, and filesystem error handling. One bug (QA-7) is a false positive in Dart's single-threaded event loop. All other fixes are surgical changes to 7 existing files.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (3.41.9)
**Primary Dependencies**: Drift (SQLite ORM), path package, tray_manager, window_manager
**Storage**: SQLite via Drift (schema v2 — no migration needed)
**Testing**: Manual testing on Windows 11 (no automated test suite)
**Target Platform**: Windows 11 desktop
**Project Type**: Desktop app
**Constraints**: Single codebase (Constitution II), no new dependencies (Constitution IV)
**Scale/Scope**: 7 targeted bug fixes across 7 files (1 false positive skipped)

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | PASS | QA-14 adds blocking dialog for scan errors — operator sees what was skipped |
| II. Single Codebase | PASS | All changes in existing Dart files |
| III. Resilient Pipeline | PASS (fixes violations) | QA-8 fixes progress tracking, QA-11 fixes retry counters, QA-14 makes scanning resilient |
| IV. Minimal Complexity | PASS | No new abstractions — reuses existing DAO patterns |
| V. Observable Progress | PASS (fixes violation) | QA-8 ensures chained compression shows accurate progress |
| VI. Update Transparency | PASS | No changes to update mechanism |

**Post-design re-check**: PASS — no violations introduced.

## Project Structure

### Documentation (this feature)

```text
specs/008-high-priority-qa-fixes/
├── plan.md              # This file
├── research.md          # Phase 0: technical decisions
├── spec.md              # Feature specification
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit-tasks)
```

### Source Code (files to modify)

```text
lib/
├── services/
│   ├── job_queue_service.dart    # QA-7 (false positive), QA-8 (chained totals)
│   └── drive_service.dart        # QA-14 (filesystem error handling)
├── database/daos/
│   ├── job_dao.dart              # QA-10 (reorder by ID), QA-11 (retry counters)
│   └── settings_dao.dart         # QA-13 (null-safe settings)
├── ui/
│   ├── screens/
│   │   ├── create_job_screen.dart # QA-9 (preset validation)
│   │   └── home_screen.dart       # QA-10 (reorder call site), QA-12 (retry call site)
│   └── widgets/
│       └── job_card.dart          # QA-12 (onRetry callback)
```

## Changes by Bug

### QA-7: startProcessing() race condition — FALSE POSITIVE

**File**: `lib/services/job_queue_service.dart:44-47`
**Finding**: Dart is single-threaded. Lines 46-47 (`if (_isProcessing) return; _isProcessing = true;`) execute synchronously — no interleaving possible before the first `await` at line 50. The guard works correctly.
**Action**: No code change. Document as false positive (same as QA-5 in feature 007).

### QA-8: Chained compression missing totals

**File**: `lib/services/job_queue_service.dart:300-333`
**Change**: After `await _jobFileDao.insertFiles(compressionFiles)` (line 332), calculate total bytes and call `updateJobTotals`:

```dart
final totalBytes = compressionFiles.fold<int>(
  0, (sum, f) => sum + (f.fileSize as Value<int>).value);
await _jobDao.updateJobTotals(jobId, compressionFiles.length, totalBytes);
```

### QA-9: Preset validation in _canCreate()

**File**: `lib/ui/screens/create_job_screen.dart:386-397`
**Change**: Add preset check before the final `return true`:

```dart
if (_jobType != JobType.transfer && _selectedPreset == null) return false;
```

### QA-10: Reorder by job ID instead of indices

**Files**: `lib/database/daos/job_dao.dart:23-47`, `lib/ui/screens/home_screen.dart:116-121`

**DAO change**: Replace `reorderJobs(int oldIndex, int newIndex)` with `reorderJobs(int movedJobId, int targetJobId)`. Fetch both jobs, swap their `sortOrder` values.

**UI change**: Pass job IDs instead of indices:
```dart
onReorder: (oldIndex, newIndex) {
  if (newIndex > oldIndex) newIndex--;
  jobDao.reorderJobs(activeJobs[oldIndex].id, activeJobs[newIndex].id);
},
```

### QA-11: Retry doesn't reset counters

**File**: `lib/database/daos/job_dao.dart:160-186`
**Change**: Add to the JobsCompanion in `resetJobForRetry`:
```dart
completedFiles: Value(0),
completedBytes: Value(0),
```

### QA-12: Context menu retry handler

**Files**: `lib/ui/widgets/job_card.dart`, `lib/ui/screens/home_screen.dart`

**job_card.dart**: Add `VoidCallback? onRetry` parameter. Add handler:
```dart
if (value == 'retry') onRetry?.call();
```

**home_screen.dart**: Pass `onRetry` callback to JobCard that calls `jobDao.resetJobForRetry(job.id)`.

### QA-13: Settings null safety

**File**: `lib/database/daos/settings_dao.dart:13-21`
**Change**: 
- `watchSingle()` → `watchSingleOrNull()`
- `getSingle()` → `getSingleOrNull()`
- Return types become `Stream<AppSetting?>` and `Future<AppSetting?>`
- Update all callers to handle null with defaults

### QA-14: Filesystem error handling in listVideoFiles

**File**: `lib/services/drive_service.dart:74-88`
**Change**: Wrap `await for` body in try/catch. Collect skipped paths. Change return type to `({List<FileSystemEntity> files, List<String> skippedPaths})`. Callers check `skippedPaths.isNotEmpty` and show a blocking `AlertDialog` listing skipped paths.

## Complexity Tracking

No constitution violations. No complexity tracking needed.
