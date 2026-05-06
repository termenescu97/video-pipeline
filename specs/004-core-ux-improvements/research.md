# Research: Core UX Improvements

## Master-Detail Layout

**Decision**: Use `Row` + `SizedBox(width: 320)` + `Expanded` — no package needed.

**Rationale**: Flutter's built-in widgets handle this. A `StatefulWidget` holds the selected job ID; the left panel shows the queue list, the right panel shows detail/create based on selection. Official Flutter samples use this exact pattern.

**Alternatives considered**:
- `NavigationRail` — too opinionated, designed for top-level navigation, not master-detail
- Third-party split-view packages — unnecessary complexity for a simple two-panel layout

## Disk Free Space

**Decision**: Use PowerShell `Get-PSDrive` (consistent with existing drive detection pattern). On non-Windows, return -1.

**Rationale**: The app already uses PowerShell for drive detection. Adding a second PowerShell call for free space keeps the pattern consistent. `win32` `GetDiskFreeSpaceEx` is faster but requires FFI boilerplate that's overkill for a one-time check.

**Alternatives considered**:
- `win32` `GetDiskFreeSpaceEx` — faster but adds FFI complexity
- `dart:io` `FileStat` — doesn't expose free space

## Subprocess Cancellation

**Decision**: Store the `Process` reference in `TransferService`/`CompressionService`. Expose a `cancel()` method that calls `process.kill()`. On Windows, this calls `TerminateProcess()` internally.

**Rationale**: `process.kill()` works on Windows and terminates immediately. Robocopy's `/Z` flag means partial files can be resumed on retry. No special handling needed.

**Alternatives considered**:
- `taskkill /im robocopy.exe /f` — kills all robocopy instances, not just ours
- Sending Ctrl+C signal — not available via Dart's Process API on Windows

## Minimum Window Size

**Decision**: Add `window_manager` package. Call `windowManager.setMinimumSize(Size(800, 600))` in `main()`.

**Rationale**: Cleanest cross-platform approach. One line of code. Alternative (modifying `windows/runner/main.cpp`) is harder to maintain.

## Tooltips

**Decision**: Use Flutter's built-in `Tooltip` widget. Works on desktop hover out of the box.

**Rationale**: No package needed. Standard behavior — shows after ~200ms hover delay, dismisses on mouse leave.

## Error Message Mapping

**Decision**: Create an `error_mapper.dart` utility with a map of regex patterns → human-friendly messages. Fallback to the raw error with a "Technical Details" expandable.

**Rationale**: Simple, maintainable, easy to extend. No NLP or AI needed — common errors have predictable patterns.
