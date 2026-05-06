# Research: High-Priority QA Bug Fixes

## Decision 1: QA-7 startProcessing() race condition — real bug or false positive?

**Decision**: False positive in Dart's single-threaded event loop. No code change needed.

**Rationale**: Dart executes synchronous code atomically between `await` points. In `startProcessing()`, lines 46-47 (`if (_isProcessing) return; _isProcessing = true;`) execute synchronously — no other code can run between the check and the assignment. A second call to `startProcessing()` can only be scheduled after the first call reaches an `await` (line 50), at which point `_isProcessing` is already `true` and the guard works correctly.

**Alternatives considered**:
- Adding a `Completer` lock — unnecessary overhead for single-threaded Dart.
- Using a `synchronized` pattern — Dart doesn't have threading; the event loop serializes synchronous code naturally.

## Decision 2: QA-10 reorder — swap by ID approach

**Decision**: Change `reorderJobs(int oldIndex, int newIndex)` to `reorderJobs(int movedJobId, int targetJobId)`. The DAO fetches both jobs, swaps their `sortOrder` values.

**Rationale**: ID-based reordering is index-agnostic — it doesn't matter what list (filtered or unfiltered) the caller uses. The swap is a simple 2-row update instead of rewriting all sort orders.

**Alternatives considered**:
- Passing the filtered list to the DAO — couples UI filtering logic to the database layer.
- Rebuilding all sort orders from the filtered list — more writes, harder to reason about.

## Decision 3: QA-13 settings null handling — nullable return vs default object

**Decision**: Change to `watchSingleOrNull()` / `getSingleOrNull()` with nullable return types. Callers handle null by providing defaults.

**Rationale**: The database already seeds a default settings row in `migration.onCreate` (database.dart:31-34), so null should be rare (only if DB is externally modified). Using nullable types makes the edge case explicit without hiding it behind a fake default object.

**Alternatives considered**:
- Creating a default `AppSetting` object in the DAO — Drift's generated classes don't have simple constructors; building a fake row is messy.
- Ensuring the row always exists via a startup check — adds a write on every launch for a case that shouldn't happen.

## Decision 4: QA-14 listVideoFiles — return type for skipped paths

**Decision**: Change return type to a record `({List<FileSystemEntity> files, List<String> skippedPaths})`. Wrap the `await for` loop body in try/catch per entity, collecting errors. Callers check `skippedPaths` and show a blocking dialog if non-empty.

**Rationale**: Returning a record keeps the method signature clean and gives callers the information they need to show the blocking dialog (per clarification). Using per-iteration try/catch allows scanning to continue past individual errors.

**Alternatives considered**:
- Throwing a custom exception with partial results — callers would need try/catch, less ergonomic.
- Using `.handleError()` on the stream — doesn't easily allow collecting which paths failed.
