# Research: Critical Bug Fixes

No technical unknowns for this feature. All fixes use existing code, patterns, and dependencies.

## Decisions

### File Enumeration Approach

**Decision**: Use existing `DriveService.listVideoFiles()` to scan the source path at job creation time.

**Rationale**: The method already exists, filters by `.mov`/`.mp4`, and returns `FileSystemEntity` objects with paths and sizes. No new code needed for scanning — just need to wire it into the job creation flow.

**Alternatives considered**:
- Scan at processing time instead of creation time — rejected because the user needs to see file counts immediately and we need totals for progress tracking
- Use robocopy's own file listing — rejected, adds unnecessary complexity

### Singleton Pattern for Services

**Decision**: Use top-level `late final` variables in `main.dart` for service singletons.

**Rationale**: Simplest approach that solves the problem. No new dependencies (`get_it`, `Provider`). The app is single-user, single-window — a formal DI framework is overkill. All services are created once at startup and shared across screens.

**Alternatives considered**:
- `get_it` service locator — adds a dependency for a problem solved by 10 lines of code
- `Provider`/`InheritedWidget` — Flutter-idiomatic but verbose for services that don't need rebuild triggers
- Static singletons on each service class — couples instantiation to the class, harder to test

### Verification Method

**Decision**: File size comparison (existing `TransferService.verifyTransfer()`).

**Rationale**: Already implemented, just never called. File size comparison catches truncated copies (the most common failure mode with large files). Checksum verification (MD5/SHA256) would be more thorough but adds significant time for 50-100 GB files — deferred to a future enhancement.

### Paused Job Resumption

**Decision**: Modify `getNextQueuedJob()` to also pick up `paused` jobs. Paused jobs resume from the next `pending` file (already-completed files are skipped by the existing `if (file.status == FileStatus.completed) continue` check).

**Rationale**: Minimal change. The existing file loop already handles resumption — it checks each file's status and skips completed ones. We just need to make sure paused jobs re-enter the queue.
