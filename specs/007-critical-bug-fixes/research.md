# Research: Critical Bug Fixes

## Decision 1: Subdirectory preservation strategy

**Decision**: Use `p.relative(entity.path, from: sourcePath)` to compute the relative path from the source root, then join with the destination. This preserves the full directory tree (e.g., `DCIM/100CANON/IMG_0001.MOV`).

**Rationale**: `p.relative()` is already available via the `path` package (imported as `p`). It handles edge cases like trailing slashes and normalizes separators. For flat sources (files directly in root), the relative path is just the filename — no empty parent folders created.

**Alternatives considered**:
- Suffix on collision (`IMG_0001_2.MOV`) — loses semantic directory info, harder to trace back to source.
- Strip common parent — ambiguous when files are at mixed depths.

## Decision 2: Stream awaiting pattern in ProcessRunner

**Decision**: Replace `.listen()` with `await stream.transform(...).forEach(...)` for both stdout and stderr. Use `Future.wait([stdoutDone, stderrDone])` to await both streams before `await process.exitCode`.

**Rationale**: Dart's `Stream.forEach()` returns a `Future` that completes when the stream is done. This guarantees all output is processed before checking the exit code. The `.listen()` pattern is fire-and-forget by default and requires manual `Completer` wiring to achieve the same result — `forEach` is simpler and idiomatic.

**Alternatives considered**:
- `listen()` + `Completer` — more boilerplate, same result.
- `drain()` after listen — doesn't guarantee processing order.

## Decision 3: Graceful shutdown via system tray

**Decision**: Replace `exit(0)` with an async shutdown method that calls `jobQueueService.stopProcessing()`, marks in-progress job as `paused` (reusing existing enum), awaits `database.close()`, then calls `exit(0)`.

**Rationale**: The existing `paused` status is already used by `stopProcessing()` (lines 163, 217 of job_queue_service.dart) and is retryable via the existing retry mechanism. Adding a new "stopped" enum would require schema migration and UI changes for no behavioral difference. Reusing `paused` keeps the change minimal.

**Alternatives considered**:
- New `stopped` enum value — requires Drift schema migration (v2 → v3), extension updates, and UI label/color additions. Overkill for this bug fix.
- Leave as `inProgress` and detect stale jobs on startup — fragile, requires timeout heuristics.

## Decision 4: Verification race condition fix

**Decision**: Check the verification result first, then call either `markFileCompleted` or `markFileFailed` — never both. This mirrors the pattern already used in the compression flow (lines 199-207).

**Rationale**: Single-write-per-file is crash-safe. If the app crashes before the write, the file stays as `inProgress` (retryable). The compression flow already implements this pattern correctly — the transfer flow should match.

**Alternatives considered**:
- Database transaction wrapping both calls — unnecessary since we're eliminating the second call entirely.
