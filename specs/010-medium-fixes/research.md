# Research: Medium-Priority Fixes

## Decision 1: Schema migration v3→v4 — combined columns

**Decision**: Add all 4 new columns in one migration step (v3→v4): `lastUsedDestination`, `lastUsedOutput`, `operatorName` on AppSettings; `operatorName` on Jobs.

**Rationale**: Drift handles multi-column migrations cleanly in a single `onUpgrade` block. Batching avoids multiple version bumps for related changes.

**Alternatives considered**:
- Separate migrations per feature — unnecessary complexity for columns added in the same release.

## Decision 2: CSV export implementation

**Decision**: Use `file_picker`'s `saveFile()` method for the save dialog. Generate CSV as a plain string with comma separation and proper quoting for fields containing commas. Write to the chosen path.

**Rationale**: `file_picker` is already a dependency (used for folder selection). Its `saveFile()` returns a path where the user wants to save. No new dependencies needed.

**Alternatives considered**:
- `csv` package — adds a dependency for something achievable with string interpolation and proper escaping.

## Decision 3: Relative timestamp formatting

**Decision**: Add `formatRelativeTime(DateTime date)` to `format_utils.dart`. Rules: <1min = "Just now", <60min = "X min ago", <24h = "X hours ago", <48h = "Yesterday", else "MMM d" format (e.g., "May 3").

**Rationale**: Simple function, no dependency. Uses `DateTime.now().difference()` for calculation. The `intl` package could provide `DateFormat` for the absolute date fallback, but it's already available as a transitive dependency through Flutter.

**Alternatives considered**:
- `timeago` package — unnecessary dependency for 15 lines of code.

## Decision 4: Path length check — when and how

**Decision**: Check after file enumeration in `_createJobInner()`, before the disk space check. For each file, compute `p.join(destPath, relativePath).length`. Collect all paths >260 chars. If any, show a dismissible warning dialog listing them. The operator can proceed anyway.

**Rationale**: Warning (not blocking) aligns with the spec. Checking after enumeration means we have the real file list. Using `p.join()` for path construction matches how destination paths are built.

**Alternatives considered**:
- Blocking dialog — too aggressive for a warning about a Windows limitation that can be worked around with `\\?\` prefix.
- Check at the drive selection step — too early, don't have the file list yet.
