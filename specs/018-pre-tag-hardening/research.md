# Research: Pre-Tag Hardening (v2.5.0)

**Phase 0 output for plan.md.** Resolves all NEEDS-CLARIFICATION items implied by the spec + the open questions in plan.md's "Open questions for Codex review" section. Each entry: Decision + Rationale + Alternatives considered.

---

## R1. Drift transaction primitive for atomic counter writes (FR-001, FR-007, FR-013)

**Decision**: Use Drift's `transaction(() async { ... })` block to wrap each paired write. All writes inside the block are SQLite-transactional (BEGIN IMMEDIATE / COMMIT). Failures inside the block roll back via Drift's exception propagation.

**Rationale**: Existing pattern — `acceptUnverified`, `requeueJobForFileRetry`, `resetJobForRetry`, and the v7→v8 migration all use `transaction(() async { ... })`. No new primitive; just consistent application. SQLite's rollback-journal mode (project default) makes the transaction atomic across power loss because the journal file is fsynced before COMMIT writes back.

**Alternatives considered**:
- Drift's `customStatement('BEGIN/COMMIT')` — manual transaction control. Rejected: easy to forget the COMMIT path on early-return, doesn't integrate with Drift's exception unwinding.
- A higher-level "atomic counter" wrapper class. Rejected: over-engineering for ~5 call sites; the `transaction(() async {})` block is already the wrapper.
- Skip atomicity, only self-healing. Rejected by Q3 clarification — operator chose "both atomic AND self-healing as defense-in-depth" (option A).

---

## R2. SQLite `PRAGMA foreign_keys` lifecycle in Drift (FR-009)

**Decision**: Set the pragma on every connection-open via Drift's `beforeOpen` callback. Run the cleanup `UPDATE` statement BEFORE issuing the pragma flip, in the same callback.

**Rationale**: SQLite documentation (https://www.sqlite.org/foreignkeys.html#fk_enable) states the pragma is per-connection, not per-database. Drift's connection layer can open multiple connections (e.g., for `customStatement` paths in some configurations), so the pragma must be set on each. The `beforeOpen` callback is Drift's documented hook for connection-init work and runs synchronously before any DAO query lands.

**Order constraint**: cleanup BEFORE pragma flip. If the pragma is enabled while dangling refs exist, SQLite's `PRAGMA foreign_keys = ON` itself does NOT validate existing data (per docs: "PRAGMA foreign_keys does not check the database"), but the FIRST write touching the affected table can trigger deferred constraint failures depending on settings. Cleanup-first is the safe order. The cleanup statement is idempotent — `UPDATE jobs SET parent_job_id = NULL WHERE parent_job_id IS NOT NULL AND parent_job_id NOT IN (SELECT id FROM jobs)` is a no-op when no dangling refs exist (typical case).

**EXPLAIN QUERY PLAN check**:
```
SEARCH jobs USING ROWID
SEARCH jobs USING INTEGER PRIMARY KEY (rowid=?)
```
Sub-select uses the implicit ROWID index. Linear in number of jobs with `parent_job_id IS NOT NULL` (typically 0 — only chained-compression children have parents, and there are usually fewer than 5 of those per database). Cost is negligible.

**Alternatives considered**:
- Run cleanup as a numbered v9 migration. Rejected: would force a schema bump for a connection-init concern; the cleanup is idempotent so it's correct to run on every open.
- Skip the cleanup; let constraint errors surface. Rejected by Q5 clarification.
- Use `PRAGMA foreign_key_check` to log violations without auto-correcting. Rejected: operator-visible warnings on a release where the operator did nothing wrong (the dangling ref is FROM the bug being fixed) is a poor UX.

---

## R3. ConfirmationDialog typed-gate API (FR-003 — FR-006)

**Decision**: Use `ConfirmationDialog.showDestructive` (or `showCritical` if the action is operator-categorized as catastrophic). Both already accept a `typedConfirmation: String` parameter. Phrases:
- Accept mismatch → `accept mismatch`
- Accept unverified → `accept unverified`
- Skip mismatch (active-card banner) → `skip mismatch`

The primitive already enforces case-sensitivity AND surfaces an inline "case-sensitive match required" hint when the operator types a case-different variant (verified at `lib/ui/widgets/confirmation_dialog.dart:206-213`).

**Rationale**: Convention conformance — the SD-erase flow already uses this exact primitive with phrase `erase`. The branch's own load-bearing convention treats trust-lowering operator decisions as "destructive". The primitive is sufficient with no API changes.

**Severity choice (`showDestructive` vs `showCritical`)**: Use `showDestructive` for all three. `showCritical` is reserved for SD-erase-class actions (irreversibly destroys source data). Accept-mismatch and Accept-unverified do NOT destroy source data — they bless destination bytes. Skip is similarly non-destructive at the action point (it's the downstream chain that becomes operator-permitted, not the action itself).

**Alternatives considered**:
- A new Accept-specific dialog primitive. Rejected: violates Principle IV (Minimal Complexity) — the existing primitive fits.
- Make Accept-mismatch use `showCritical` (because of the downstream encode-and-erase chain). Rejected: the typed phrase is the gate, not the dialog severity color. `showDestructive` already disables the confirm button until the typed match. Severity is a UX-coloring concern; the security-relevant control is the typed gate.

---

## R4. `_stopRequested` flag pattern (FR-008)

**Decision**: Add a private `bool _stopRequested = false` field to `JobQueueService`. `stopProcessing` sets it to `true` synchronously, then awaits the existing `_stopCompleter` for drain confirmation. The processing loop checks `_stopRequested` (NOT `_isProcessing`) at every loop iteration boundary. `startProcessing` checks `_stopCompleter` — if non-null and unresolved, await it before starting; if non-null and resolved, reset the flag and proceed; if null, proceed immediately.

**Rationale**: The current design conflates "processing is in flight" (`_isProcessing`) with "should the loop continue?". Splitting them is the standard pattern for cancellable async loops. Dart's single-threaded event loop guarantees `_stopRequested` writes are visible to the loop on the next await resumption — no `volatile` semantics needed. The `_stopCompleter` already exists; we just give it teeth.

**Race scenario the design closes**:
- T0: `stopProcessing()` sets `_isProcessing = false` (today's behavior) → completer awaiter created.
- T0+1ms: queue loop is mid-await on robocopy subprocess (does not see `_isProcessing` change yet).
- T0+2ms: operator clicks Accept → `maybeChainCompression` → `startProcessing()` reads `_isProcessing == false`, spawns second loop.
- T0+500ms: original loop's robocopy returns, loop checks `while (_isProcessing)` → reads `false` (the SECOND loop's startProcessing flipped it back to true after the first read, but timing here is implementation-detail-dependent). Either way: two loops have observed the queue.

The fix:
- `stopProcessing` sets `_stopRequested = true` (one-way latch until reset by next `startProcessing`).
- Loop iteration: `if (_stopRequested) break`. Even if `_isProcessing` is observed as true, the requested-stop signal exits the loop.
- `startProcessing`: `if (_stopCompleter != null && !_stopCompleter.isCompleted) await _stopCompleter.future;` then proceed (resetting `_stopRequested = false`).

**Alternatives considered**:
- Use a `Mutex` from the `synchronized` package. Rejected: adds dependency; over-engineering for one-call coordination.
- Reject any `startProcessing` call during in-flight stop with a thrown exception. Rejected: callers like `maybeChainCompression` would need try/catch wrappers everywhere; await-and-proceed is more ergonomic.
- Use `Stream.asyncExpand` to model the loop. Rejected: too large a refactor for a targeted race fix.

---

## R5. Staging-dir liveness detection via PID marker (FR-015)

**Decision**: When `transferFile` creates a staging dir at `<destDir>/.tmp_robocopy_<tag>/`, also write a marker file at `<destDir>/.tmp_robocopy_<tag>/.live` containing the current process PID + the absolute path of the running executable. The startup sweep at `recoverStaleJobs`-time considers a staging dir as "orphan" when ANY of:
- The dir is empty (no `.live` marker) — pre-marker era or marker write failed.
- The `.live` marker contains a PID that doesn't exist in the OS process table.
- The `.live` marker contains a PID whose executable path doesn't match the current process's executable path.

**Rationale**: Mirrors the existing `instance_lock.dart` approach (PID + executable-path validation) — proven on Windows 11. Reading process info on Windows uses the same `dart:io` APIs already in the project. The triple-check (PID exists AND exe matches) prevents both stale-PID-reuse-after-reboot and PID-collision scenarios.

**Order in `transferFile`**:
1. Create staging dir (existing).
2. Write `.live` marker with PID + exe path. (NEW)
3. Robocopy into staging dir (existing).
4. Rename staged file to final destination (existing).
5. Best-effort delete `.live` marker, then `rmdir` staging dir (existing, cleanup split per Codex round-11).

**Sweep order in startup**:
1. Read jobs in non-terminal status + most-recently-completed job → collect distinct destination roots.
2. For each root: skip if not currently mounted.
3. For each root: list children matching pattern `.tmp_robocopy_*`.
4. For each match: check `.live` marker. If absent or invalid (per criteria above): `rmdir`.

**Alternatives considered**:
- File-locking (`RandomAccessFile.lock`) on the marker file. Rejected: would require holding an open file handle for the full transfer duration; complicates error-handling. PID-check is sufficient and matches the existing pattern.
- Time-based heuristic (older than N minutes = orphan). Rejected: a long compression run could leave a "stale" staging dir while the parent transfer is still legitimately in flight.
- Skip the sweep — defer to operator-triggered "Clean staging dirs" in Settings. Rejected by Q4 clarification (option C was rejected; option B chose automatic bounded sweep).

---

## R6. Counter atomicity with `_safeWrite` integration (FR-013)

**Decision**: New atomic DAO methods (e.g., `JobFileDao.markFileUnverifiedAndIncrement(int fileId)`) wrap their `transaction(() async { ... })` body. The CALLER still wraps the DAO call in `_safeWrite`. The wrapper composes correctly: `_safeWrite` either drops the entire transaction (when `_shutdownAbandoned == true`) or lets it run to completion (rolling back atomically on exception).

**Rationale**: Preserves the v2.4.0 load-bearing convention `_safeWrite` covers every DAO write in the processing loop (CLAUDE.md). The transaction is INSIDE the wrapped function call, not OUTSIDE it. Code shape:

```dart
await _safeWrite(() => _jobFileDao.markFileUnverifiedAndIncrement(file.id));
```

`_safeWrite` either drops the closure entirely (atomicity intact — no rows mutate at all) or executes it (transaction commits or rolls back atomically). Either way the per-row state and the counter agree.

**Alternatives considered**:
- Move `_safeWrite` INSIDE the DAO method. Rejected: the wrapper checks `_shutdownAbandoned` which is owned by `JobQueueService`; pushing it into DAOs creates a circular dependency.
- Make the increment column a `GENERATED ALWAYS AS (SELECT count...)` stored column. Rejected: SQLite supports it but Drift's migration tooling for generated columns is awkward; the recompute-on-read fallback achieves the same property without the schema change.

---

## R7. Migration Phase 7 errorMessage extension (FR-012)

**Decision**: Extend the existing v8 migration's Phase 7 `UPDATE jobs SET status = 'completed' ...` statement to also set `error_message = NULL` on the same lifted rows. Same WHERE clause; one more column in the SET clause.

**Rationale**: The migration already runs Phase 7 in a transaction with the other phases. Adding the column is mechanical and idempotent. Backward concerns: operators who already migrated to v8 (early adopters of this 017A+017B branch) will not re-run Phase 7 because `from < 8` is the migration guard. Those operators may carry stale error messages from the failed era — but they are NOT in production yet (017A+017B is still pending the v2.5.0 tag), so this is a non-issue.

**Future-proofing**: Add an idempotent maintenance pass at connection-open OR a v9 migration for production v8 operators if/when that group exists. Defer to v2.5.1 if it ever applies.

**Alternatives considered**:
- Suppress `error_message` rendering at the UI layer when status is completed. Rejected: information should be correct at the source, not papered over. Future code that reads `error_message` (CSV export, future history queries) would see the lie.
- Rewrite `error_message` to a migration-provenance string like "Migrated from v7: hash failures reclassified as verify warnings". Rejected: adds noise; NULL is the correct semantic for "no error to report".

---

## R8. Test patterns for race conditions in Dart (US3)

**Decision**: Use a deterministic test runner — the `fake_async` package (already a transitive dep via `flutter_test`). Construct synthetic timeline: schedule both Accept handlers / both stop+start calls / both Drift transactions on the test runner's controlled clock. Advance time deterministically and assert the database state at each step.

**Rationale**: Wall-clock-based stress tests are flaky. `fake_async` lets us control microtask + timer ordering precisely. SQLite via Drift uses the same isolate (no real OS threads), so all races are about microtask ordering — exactly what `fake_async` controls.

**Sample shape** (chain-dedup):
```dart
test('two paired Accept calls produce one chained child', () {
  fakeAsync((async) {
    final f1 = service.maybeChainCompression(parentJobId);
    final f2 = service.maybeChainCompression(parentJobId);
    async.flushMicrotasks();
    expect(jobDao.getChildrenOf(parentJobId).length, 1);
  });
});
```

**Alternatives considered**:
- Real subprocess-based stress with `flutter_driver`. Rejected: heavy infra for a single-process race.
- Probabilistic stress (run 1000× and assert no failure). Rejected: doesn't prove correctness, only luck.

---

## R9. Resolution of Codex/Opus open questions from plan.md

**Q1 (cleanup-then-pragma crash safety)**: Both statements run in the same `beforeOpen` callback. If the connection drops between them, the next connection-open re-runs both. Cleanup is idempotent; pragma is per-connection. Safe.

**Q2 (`_stopRequested` new race)**: `startProcessing` after `stopCompleter` resolves, before final teardown — addressed by the design at R4. The `_stopRequested = false` reset happens AFTER awaiting the completer, so the new loop starts clean. The previous loop's "final teardown writes" are inside its already-completed transactions (via `_safeWrite`); no shared mutable state remains.

**Q3 (recovery-branch order assumption)**: The current order is `markFileUnverified` THEN `incrementUnverified`. Reversing or atomically combining is safe because the recovery branch's continuation already reads `_jobFileDao.getFile(id)` for any state-dependent decision later — never the counter. No call site reads the counter mid-iteration.

**Q4 (`hasChainedChild` outside transaction)**: One caller (`_processJob` post-transfer in `maybeChainCompression`) reads the result inside a logical "decide whether to chain" block. Wrapping the check + insert in a transaction preserves the semantics — the caller sees a definitive yes/no AT TRANSACTION TIME, which is the correct semantic. No caller relies on a stale-but-consistent read.

**Q5 (PID marker on remounted drive)**: If the drive remounts under a different path (`\\nas01\share` → `Z:\`), the staging dir lives at `Z:\.tmp_robocopy_<tag>\.live`. The sweep enumerates by destination root from job records — uses whatever path was stored at job-creation time. If the job's destinationPath was `\\nas01\share\...` and the drive now appears as `Z:\`, the sweep won't find it (FileSystemEntity treats them as different paths). Acceptable: orphans on drives that have moved are out-of-scope per the bounded-scope decision (Q4 clarification).

---

## Summary of decisions

All NEEDS-CLARIFICATION items resolved. No external dependencies introduced (all use existing primitives). No new abstractions (R3, R6 reuse, R5 mirrors `instance_lock.dart`). Performance bounded (R2 sub-millisecond per connection-open; R5 sub-500ms per startup).

Ready to proceed to Phase 1 (data-model.md, quickstart.md, agent context update).
