# Research: High-Priority Product Gaps

## Decision 1: Progress data plumbing architecture

**Decision**: Add a `ValueNotifier<ProgressData?>` on `JobQueueService` that emits real-time progress. `JobDetailScreen` listens via `ValueListenableBuilder` and passes fields to `PipelineProgressBar`.

**Rationale**: `ValueNotifier` is lightweight, synchronous, and already part of Flutter core — no new dependencies. It updates the UI on every progress callback without needing streams or state management. The data flows: parser → service callback → JobQueueService notifier → JobDetailScreen widget.

**Alternatives considered**:
- `StreamController` — more boilerplate for the same result; `ValueNotifier` is simpler for single-value state.
- Store progress in the database — too many writes per second; progress is ephemeral, not persistent.

## Decision 2: Transfer speed and ETA calculation

**Decision**: Calculate in `JobQueueService._processTransfer()` using `transferService.fileStartTime`, `transferService.fileTotalBytes`, and elapsed time. Speed = bytes transferred / elapsed seconds. ETA = remaining bytes / speed.

**Rationale**: Robocopy's output doesn't include speed or ETA. The transfer service already exposes `fileStartTime` and `fileTotalBytes` via getters. Calculating at the queue service level keeps the parser simple and reuses existing data.

**Alternatives considered**:
- Parse speed from robocopy summary output — only available after completion, not during transfer.
- Use file-level progress percentage from parser — percentage * totalBytes gives transferred bytes, which enables speed calculation.

## Decision 3: Log service design

**Decision**: Simple singleton class with `log(String level, String message)` method. Writes to `copiatorul3000.log` next to the executable. Uses `IOSink` for buffered writes. On startup, checks file size and truncates to last 5MB if over 10MB.

**Rationale**: Minimal complexity (Constitution IV). No need for a logging framework — this is a single-machine desktop app with one user. File-based logging is the simplest approach that meets the requirement.

**Alternatives considered**:
- Dart `logging` package — adds a dependency for something achievable in 30 lines.
- SQLite log table — overkill, hard to read externally.

## Decision 4: Single-instance lock implementation

**Decision**: Write a `copiatorul3000.lock` file next to the executable containing the current PID. On startup, read the file, check if the PID's process is running via `Process.run('tasklist', ['/FI', 'PID eq $pid'])`. If running → show `MessageBox`-style dialog and `exit(1)`. If stale → delete and re-acquire.

**Rationale**: PID-based locking is the standard approach for desktop apps. Using `tasklist` is Windows-native and reliable. The lock file lives next to the executable (same as the log file) — consistent and predictable.

**Alternatives considered**:
- Named mutex via FFI — more robust but requires Win32 FFI calls, adding complexity.
- Socket-based lock (listen on a port) — fragile, port conflicts possible.

## Decision 5: Schema migration for firstRunCompleted

**Decision**: Add `firstRunCompleted` boolean column to `AppSettings` table with default `false`. Bump schema to v3. Add `if (from < 3) await m.addColumn(appSettings, appSettings.firstRunCompleted)` to migration.

**Rationale**: Drift's migration system handles this cleanly. Existing users get the column with default `false` (showing welcome on next launch). New installs get it via `onCreate`. The `dart run build_runner build` regenerates the Drift code.

**Alternatives considered**:
- Store in a separate file (e.g., `first_run.flag`) — inconsistent with existing settings pattern.
- Check if any jobs exist as proxy for first run — breaks when user deletes all jobs (clarified in spec).
