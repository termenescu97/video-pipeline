# Implementation Plan: Critical Bug Fixes

**Branch**: `007-critical-bug-fixes` | **Date**: 2026-05-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/007-critical-bug-fixes/spec.md`

## Summary

Fix 6 critical bugs from the v2.0.0 QA/PM review that cause data loss (duplicate filename overwrites, verify-then-overwrite race), lost progress output (streams not awaited), app corruption (hard exit from tray), a compile error (wrong dropdown parameter), and a runtime crash (untyped batch parameter). All fixes are surgical changes to existing files with no new dependencies or schema migrations.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x
**Primary Dependencies**: Drift (SQLite ORM), path package, tray_manager, window_manager
**Storage**: SQLite via Drift (schema v2 — no migration needed)
**Testing**: Manual testing on Windows 11 (no automated test suite)
**Target Platform**: Windows 11 desktop
**Project Type**: Desktop app
**Performance Goals**: N/A (bug fixes, no new perf requirements)
**Constraints**: Single codebase (Constitution II), no new dependencies (Constitution IV)
**Scale/Scope**: 6 targeted bug fixes across 4 files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | PASS | Graceful shutdown (QA-4) adds confirmation-like behavior — no silent data destruction |
| II. Single Codebase | PASS | All changes in existing Dart files, no new runtimes |
| III. Resilient Pipeline | PASS (fixes violations) | QA-1 fixes data loss, QA-2 fixes false-positive verification, QA-3 fixes lost progress signals |
| IV. Minimal Complexity | PASS | No new abstractions — reuses `p.relative()`, `Stream.forEach()`, existing `paused` status |
| V. Observable Progress | PASS (fixes violation) | QA-3 ensures 100% of progress lines are captured |
| VI. Update Transparency | PASS | No changes to update mechanism |

**Post-design re-check**: PASS — no violations introduced.

## Project Structure

### Documentation (this feature)

```text
specs/007-critical-bug-fixes/
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
│   └── job_queue_service.dart    # QA-1 (path preservation), QA-2 (verify race), QA-6 (typed param)
├── ui/screens/
│   ├── create_job_screen.dart    # QA-1 (path preservation), QA-5 (dropdown param)
│   └── shell_screen.dart         # QA-4 (graceful shutdown)
├── utils/
│   └── process_runner.dart       # QA-3 (stream awaiting)
└── main.dart                     # QA-4 (expose shutdown helper)
```

**Structure Decision**: No new files. All changes are modifications to existing source files in the established project structure.

## Changes by Bug

### QA-1: Duplicate filenames overwrite at destination

**Files**: `lib/services/job_queue_service.dart` (lines 272-288), `lib/ui/screens/create_job_screen.dart` (lines 485-500)

**Change**: Replace `p.basename(entity.path)` with `p.relative(entity.path, from: sourcePath)` for the destination path. The `fileName` field stays as `p.basename()` (it's display-only). The `destinationFilePath` becomes `p.join(destination, relativePath)`.

**In batch method** (job_queue_service.dart:272-288):
```dart
// Before:
final fileName = p.basename(entity.path);
destinationFilePath: p.join(destination, fileName),

// After:
final relativePath = p.relative(entity.path, from: drivePath);
final fileName = p.basename(entity.path);
destinationFilePath: p.join(destination, relativePath),
```

**In create_job_screen.dart** (lines 485-500): Same pattern, using the selected source path as the `from:` parameter.

### QA-2: File marked completed then overwritten as failed

**File**: `lib/services/job_queue_service.dart` (lines 130-145)

**Change**: Check `verified` before calling any status method. Call `markFileCompleted` only if verified, `markFileFailed` only if not. Mirrors the compression flow pattern (lines 199-207).

```dart
// Before:
await _jobFileDao.markFileCompleted(file.id, verified: verified);
if (!verified) {
  await _jobFileDao.markFileFailed(file.id, 'Verification failed: size mismatch');
  failedCount++;
} else {
  completedCount++;
}

// After:
if (verified) {
  await _jobFileDao.markFileCompleted(file.id, verified: true);
  completedCount++;
} else {
  await _jobFileDao.markFileFailed(file.id, 'Verification failed: size mismatch');
  failedCount++;
}
```

### QA-3: Process streams not awaited before exitCode

**File**: `lib/utils/process_runner.dart` (lines 17-31)

**Change**: Replace `.listen()` with `Stream.forEach()` which returns an awaitable `Future`. Await both stream futures before awaiting exitCode.

```dart
// Before:
process.stdout.transform(...).listen((data) { ... });
process.stderr.transform(...).listen((data) { ... });
final exitCode = await process.exitCode;

// After:
final stdoutDone = onStdoutLine != null
    ? process.stdout.transform(const SystemEncoding().decoder).forEach((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) onStdoutLine(line);
        }
      })
    : Future<void>.value();

final stderrDone = onStderrLine != null
    ? process.stderr.transform(const SystemEncoding().decoder).forEach((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) onStderrLine(line);
        }
      })
    : Future<void>.value();

await Future.wait([stdoutDone, stderrDone]);
final exitCode = await process.exitCode;
```

### QA-4: Hard exit from system tray

**File**: `lib/ui/screens/shell_screen.dart` (line 64), `lib/main.dart`

**Change**: Replace `exit(0)` with an async graceful shutdown sequence:
1. `jobQueueService.stopProcessing()` — stops queue and kills subprocesses (already marks job as `paused`)
2. `await database.close()` — flushes pending writes and closes SQLite
3. `exit(0)` — clean exit after all resources released

The `database` and `jobQueueService` globals are already accessible from `main.dart`. The tray handler in `shell_screen.dart` calls a new `_gracefulShutdown()` async method.

### QA-5: Wrong dropdown parameter name

**File**: `lib/ui/screens/create_job_screen.dart` (line 238)

**Change**: `initialValue:` → `value:`

### QA-6: Untyped batch parameter

**File**: `lib/services/job_queue_service.dart` (lines 238-239, 246)

**Change**:
- Parameter: `List<dynamic> drives` → `List<DetectedDrive> drives`
- Remove cast: `drive.path as String` → `drive.path`
- Add import for `DetectedDrive` if not already imported

## Complexity Tracking

No constitution violations. No complexity tracking needed.
