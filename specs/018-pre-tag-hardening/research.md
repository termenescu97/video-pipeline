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

**Rationale**: SQLite documentation (https://www.sqlite.org/foreignkeys.html#fk_enable) states the pragma is per-connection, not per-database. Drift's connection layer can open multiple connections (e.g., for `customStatement` paths in some configurations), so the pragma must be set on each.

**Drift lifecycle (corrected after Codex round-22 P3)**: Drift's `MigrationStrategy` runs in this order:
1. `onCreate` (fresh databases) OR `onUpgrade` (schema migrations) — runs FIRST.
2. `beforeOpen` callback — runs SECOND, after migrations complete.
3. Normal DAO queries — run THIRD.

So `beforeOpen` covers all subsequent DAO queries but does NOT cover the migration runner itself. For this feature that's acceptable: the v8 migration is already shipped (with its own transaction discipline) and adding FK enforcement to its execution would require changes to migration code, which is out of scope. The `beforeOpen` ordering is sufficient because the v8 migration does not insert dangling parent references — only operator deletes (which only happen at runtime, AFTER `beforeOpen`) can produce them.

**Order constraint within beforeOpen**: cleanup BEFORE pragma flip. If the pragma is enabled while dangling refs exist, SQLite's `PRAGMA foreign_keys = ON` itself does NOT validate existing data (per docs: "PRAGMA foreign_keys does not check the database"), but the FIRST write touching the affected table can trigger deferred constraint failures depending on settings. Cleanup-first is the safe order. The cleanup statement is idempotent — `UPDATE jobs SET parent_job_id = NULL WHERE parent_job_id IS NOT NULL AND parent_job_id NOT IN (SELECT id FROM jobs)` is a no-op when no dangling refs exist (typical case).

**EXPLAIN QUERY PLAN (corrected after Codex round-22 P3)**:
```
SCAN jobs
SEARCH jobs USING INTEGER PRIMARY KEY (rowid=?)
```
The OUTER filter (`WHERE parent_job_id IS NOT NULL`) does a full table scan because there is no index on `parent_job_id`. The inner sub-select (`SELECT id FROM jobs`) uses the implicit ROWID PRIMARY KEY for the inclusion check. At the project's scale (tens to low hundreds of jobs) the full scan is sub-millisecond and acceptable. Adding an index on `parent_job_id` is deferred to v2.6 if production observes a regression. The original research claim of "SEARCH jobs USING ROWID" for the outer filter was wrong; the corrected plan above is what SQLite actually generates.

**Test coverage**: must include both production (`NativeDatabase.createInBackground`) and test (`AppDatabase.forTesting`) connection paths. Both go through `beforeOpen` per Drift convention; assert pragma state on each.

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

**Decision**: Add a private `bool _stopRequested = false` field to `JobQueueService`. `stopProcessing` sets it to `true` synchronously, then awaits the existing `_stopCompleter` for drain confirmation. The processing loop checks `_stopRequested` (NOT `_isProcessing`) at every loop iteration boundary. `startProcessing` checks `_stopCompleter`:
- If null: proceed.
- If non-null and unresolved: `await _stopCompleter.future`, then **synchronously re-check `_isProcessing` and return immediately if true** (no awaits between re-check and the `_isProcessing = true` flip).
- If non-null and resolved: same as above (re-check + flip atomically).

**Rationale**: The current design conflates "processing is in flight" (`_isProcessing`) with "should the loop continue?". Splitting them is the standard pattern for cancellable async loops. Dart's single-threaded event loop guarantees `_stopRequested` writes are visible to the loop on the next await resumption — no `volatile` semantics needed. The `_stopCompleter` already exists; we just give it teeth.

**Codex round-22 P2 — multiple queued starters**: if TWO `startProcessing()` calls arrive during the same in-flight stop, BOTH await the same `_stopCompleter.future`. When the completer resolves, both awaits are scheduled as microtasks (FIFO). The first microtask runs: re-checks `_isProcessing` (false), flips to `true`, continues. The second microtask runs: re-checks `_isProcessing` (now true — set synchronously by the first microtask with no intervening await), returns. Because Dart microtasks run to completion (or first await), the re-check + flip is atomic with respect to other microtasks — no second concurrent loop spawns.

**Critical implementation rule**: there must be NO `await` between the re-check and the `_isProcessing = true` flip. If any future refactor inserts an await there, the race re-opens. Add an inline comment AND a unit test (`start_stop_race_test.dart`) that fires N concurrent `startProcessing` calls during an in-flight stop and asserts loop count = 1.

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

**Decision**: When `transferFile` creates a staging dir at `<destDir>/.tmp_robocopy_<tag>/`, also write a marker file at `<destDir>/.tmp_robocopy_<tag>/.live` containing the current process PID + the absolute path of the running executable. The marker write is **load-bearing** — if it fails, the transfer aborts before robocopy starts. The startup sweep at `recoverStaleJobs`-time considers a staging dir as "orphan" when ANY of:
- The dir is empty (no `.live` marker) — pre-marker era OR a crash between mkdir and marker write under the previous run. Both are safe to delete (the previous process is dead per the OS-level instance lock; deleting an empty unmarked dir cannot disrupt a live transfer).
- The `.live` marker contains a PID that doesn't exist in the OS process table.
- The `.live` marker contains a PID whose executable path doesn't match the current process's executable path.

**Codex round-22 P3 correction**: the original research wording suggested "marker write failed" as merely a sweep classifier. That misses the live-but-unmarked danger: if marker write fails MID-TRANSFER and `transferFile` continues anyway, a future sweep (or even the same-session crash recovery) could delete the still-active staging dir. **The correction**: marker write must be awaited and load-bearing — if it fails, `transferFile` deletes the staging dir and fails the transfer BEFORE invoking robocopy. This way a marker-less dir at sweep time means the previous process died (either before marker write or by the OS-level instance lock), not a current-session in-flight transfer.

**Note on `instance_lock.dart` analogy**: the existing `instance_lock` uses an OS-level file lock (`RandomAccessFile.lock`) for proven liveness. The PID-marker approach used here is diagnostic, NOT proof of liveness in the OS-lock sense — it identifies WHO owns the dir, but the actual single-instance guarantee comes from the OS lock at the app level. Combined: only one instance runs (OS lock); within that instance, the marker says "this dir belongs to me right now" so concurrent transfers within the same process don't step on each other's staging dirs.

**Order in `transferFile` (revised)**:
1. Create staging dir (existing).
2. Write `.live` marker with PID + exe path. **If write fails: rmdir staging, throw — transfer fails before robocopy starts.** (NEW)
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

**Decision**: New atomic DAO methods (e.g., `JobFileDao.markFileUnverifiedAndIncrement(int fileId)`) wrap their `transaction(() async { ... })` body. The CALLER still wraps the DAO call in `_safeWrite`.

**Composition guarantee (corrected after Codex round-22 P3)**: `_safeWrite` provides ROW/COUNTER ATOMICITY, not abandonment preemption. The actual semantics:
- If `_shutdownAbandoned == true` BEFORE the closure runs: `_safeWrite` drops the closure entirely. No rows mutate. Atomic.
- If `_shutdownAbandoned` flips to `true` DURING the closure (e.g., Phase B times out mid-write): `_safeWrite` does NOT cancel the in-flight transaction. The transaction either commits (if the DB stays open long enough) OR throws (if the DB is closed by Phase C under it). Either outcome is internally atomic — Drift transactions roll back on exception — but the LATE COMMIT case means a write CAN persist after the abandonment flag flips.

This is acceptable for FR-013's purpose: the row state and the counter always agree (atomicity intact), even if the WHOLE pair commits late. What `_safeWrite` does NOT promise is "no writes after abandonment" — which it never promised to begin with; that's `_shutdownAbandoned`'s job for the NEXT closure call.

**Code shape (unchanged)**:

```dart
await _safeWrite(() => _jobFileDao.markFileUnverifiedAndIncrement(file.id));
```

The original research wording ("drops the entire transaction or lets it run to completion") was technically true but missed the late-commit-after-abandon case. The honest formulation: `_safeWrite` skips closures dispatched after abandonment AND lets in-flight closures finish (committing or throwing) atomically.

**Alternatives considered**:
- Move `_safeWrite` INSIDE the DAO method. Rejected: the wrapper checks `_shutdownAbandoned` which is owned by `JobQueueService`; pushing it into DAOs creates a circular dependency.
- Make the increment column a `GENERATED ALWAYS AS (SELECT count...)` stored column. Rejected: SQLite supports it but Drift's migration tooling for generated columns is awkward; the recompute-on-read fallback achieves the same property without the schema change.

---

## R7. Migration Phase 7 errorMessage extension (FR-012) — and idempotent connection-open cleanup

**Decision (revised after Codex round-22 P2)**: Extend the existing v8 migration's Phase 7 `UPDATE jobs SET status = 'completed' ...` statement to also set `error_message = NULL` on the same lifted rows. Same WHERE clause; one more column in the SET clause. AND ALSO: add an idempotent maintenance UPDATE at connection-open (alongside the FR-009 cleanup) that catches lifted jobs whose `error_message` was not cleared by an earlier migration run.

**Rationale**: The original research argued "017A+017B is still pending the v2.5.0 tag, so this is a non-issue". Codex round-22 P2 correctly flagged that the repo already has `v2.5.0-pre` acceptance flow language — pre-tag testers (operator's Windows workstation, possibly others) MAY have run the v8 migration on a real database AFTER round-19 landed but BEFORE Phase 7's errorMessage extension. Those operators carry stale `errorMessage` and never see the cleanup because the migration guard is `from < 8`. Relying on "not production yet" is a wave-away, not a fix.

**Two-mechanism approach**:
1. Migration Phase 7 SET clause extended with `error_message = NULL`. Catches new operators upgrading from v7 directly to this feature's v8 build.
2. Idempotent connection-open UPDATE (in `beforeOpen`, alongside the FR-009 FK cleanup):
   ```sql
   UPDATE jobs
   SET error_message = NULL
   WHERE status = 'completed'
     AND id IN (SELECT DISTINCT job_id FROM job_files WHERE verify_status IN ('mismatch', 'unverified'))
     AND id NOT IN (SELECT DISTINCT job_id FROM job_files WHERE status = 'failed')
     AND error_message IS NOT NULL
   ```
   Catches existing-v8 testers retroactively. Idempotent — re-runs are no-ops because `error_message IS NULL` after the first run filters the row out. Sub-millisecond at project scale.

**Why not bump to v9**: A v9 migration would also work but adds a schema-version bump that downstream readers (CLAUDE.md, generated Drift code, agent scripts) all have to chase. The connection-open cleanup is equivalent in correctness AND lighter-weight. Bump deferred to a future feature that genuinely needs schema changes.

**Order in `beforeOpen`** (revised): cleanup statements first (FR-009 FK cleanup + this errorMessage cleanup, in any order — they touch different columns of the same table), THEN `PRAGMA foreign_keys = ON`. Total: 3 statements per connection-open.

**Alternatives considered**:
- Suppress `error_message` rendering at the UI layer when status is completed. Rejected: information should be correct at the source, not papered over. Future code that reads `error_message` (CSV export, future history queries) would see the lie.
- Rewrite `error_message` to a migration-provenance string like "Migrated from v7: hash failures reclassified as verify warnings". Rejected: adds noise; NULL is the correct semantic for "no error to report".

---

## R7b. Centralized chain-dedup gate (FR-007, post Codex round-22 P2)

**Decision**: Replace the multi-call-site chain creation with a single gate method `JobQueueService.createChainedCompressionJobIfAbsent(int parentJobId)`. Both call sites — `_processJob` (post-clean-transfer auto-chain) and `maybeChainCompression` (operator Accept-driven resume) — route through this method. Other ad-hoc paths that today call `_createChainedCompressionJob(job)` directly are migrated to the gate too.

**Rationale**: Codex round-22 P2 correctly flagged that wrapping `hasChainedChild + _createChainedCompressionJob` ONLY inside `maybeChainCompression` leaves `_processJob`'s direct call uncovered — a future refactor or operator action could spawn duplicates. Centralizing at the gate makes the dedup invariant unmissable.

**Method shape**:
```dart
Future<int?> createChainedCompressionJobIfAbsent(int parentJobId) async {
  return await _safeWrite(() => _jobDao.transaction(() async {
    if (await _jobDao.hasChainedChild(parentJobId)) return null;
    final parent = await _jobDao.getJob(parentJobId);
    if (parent == null) return null;  // FR-009 cleanup may have nulled it
    final childFiles = await _eligibleFilesForCompression(parent);
    if (childFiles.isEmpty) return null;  // gate: nothing to compress
    final maxSortOrder = await _jobDao.getMaxSortOrder();
    return await _jobDao.insertChainedCompression(parent: parent, files: childFiles, sortAfter: maxSortOrder);
  }));
}
```

**Transaction span**: Codex's secondary concern was that `_createChainedCompressionJob` does a lot inside the transaction — file reads, filtering, getMaxSortOrder, nested job creation. Acceptable: SQLite write transactions hold an exclusive lock that blocks OTHER writes but NOT reads. The chain-creation transaction touches `jobs` and `job_files` tables only; readers (UI streams via `watchAllJobs`) get the snapshot from before the transaction began until COMMIT. The transaction's wall-clock duration is tens of milliseconds at typical file counts (~50). At project scale, no operator-perceptible blocking.

**If transaction span ever becomes a problem**: split into (a) read parent + childFiles + maxSortOrder (no transaction), (b) one-shot transactional `INSERT INTO jobs ... WHERE NOT EXISTS (SELECT 1 FROM jobs WHERE parent_job_id = ?)` plus child-file inserts. SQLite's `INSERT ... WHERE NOT EXISTS` IS atomic at the statement level; combined with FR-007's transaction, the gate stays correct with a shorter held lock. Defer until/unless metrics motivate it.

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

## R9. Resolution of original open questions from plan.md

**Q1 (cleanup-then-pragma crash safety)**: Both statements run in the same `beforeOpen` callback. If the connection drops between them, the next connection-open re-runs both. Cleanup is idempotent; pragma is per-connection. Safe.

**Q2 (`_stopRequested` new race)**: addressed by R4's revised design: re-check + flip is atomic across microtasks because there's no await between them. See R4 "multiple queued starters" sub-section.

**Q3 (recovery-branch order assumption)**: The current order is `markFileUnverified` THEN `incrementUnverified`. Reversing or atomically combining is safe because the recovery branch's continuation already reads `_jobFileDao.getFile(id)` for any state-dependent decision later — never the counter. No call site reads the counter mid-iteration.

**Q4 (`hasChainedChild` outside transaction)**: see R7b — the gate is now centralized AND transactional, both call sites route through it. The original concern (caller relies on a stale-but-consistent read) was hypothetical; no actual caller does this.

**Q5 (PID marker on remounted drive)**: If the drive remounts under a different path (`\\nas01\share` → `Z:\`), the staging dir lives at `Z:\.tmp_robocopy_<tag>\.live`. The sweep enumerates by destination root from job records — uses whatever path was stored at job-creation time. If the job's destinationPath was `\\nas01\share\...` and the drive now appears as `Z:\`, the sweep won't find it (FileSystemEntity treats them as different paths). Acceptable: orphans on drives that have moved are out-of-scope per the bounded-scope decision (clarify Q4).

## R10. Codex round-22 review fold-back

Round 22 surfaced 10 findings (1 P1, 3 P2, 6 P3). All folded into spec/plan/research/data-model:

- **P1 — size-mode "progress" fix wrote success before verification**: spec.md FR-014 rewritten to mirror SHA-256 sequence exactly (`markFileCompleted(verified: false)` BEFORE size verify; `markFileSizeOnlyVerified` only on success); plan.md Summary #5 rewritten to match.
- **P2 — multiple queued starters race**: research.md R4 spelled out re-check-after-await + atomic flip; added a critical-implementation-rule callout.
- **P2 — chain dedup not centralized**: research.md R7b added (new `createChainedCompressionJobIfAbsent` gate; both call sites route through it); plan.md Summary #3 implicitly covered by FR-007's centralization.
- **P2 — existing v8 dbs not fixed**: research.md R7 expanded to TWO mechanisms: migration Phase 7 SET clause extension AND idempotent connection-open `UPDATE ... WHERE error_message IS NOT NULL`. Catches both new and pre-tag-tester operators.
- **P3 — FK lifecycle claim overstated**: research.md R2 corrected ("`beforeOpen` runs AFTER migrations, not before"). Added test-coverage note for both production and forTesting connection paths.
- **P3 — FK cleanup query plan claim wrong**: research.md R2 corrected (actual plan is `SCAN jobs` + rowid lookups, not `SEARCH USING ROWID`); plan.md Risks corrected; index deferred to v2.6.
- **P3 — _safeWrite cancellation overclaim**: research.md R6 corrected (acknowledges late-commit-after-abandon case; honest formulation: "skips closures dispatched after abandonment AND lets in-flight closures finish atomically").
- **P3 — counter self-healing read paths not specified**: data-model.md updated to name the specific DAO read paths (`watchAllJobs`, `watchCompletedJobs`, `watchJob`).
- **P3 — SC-009 tautological**: spec.md SC-009 rewritten (controlled completer assertion; observe persisted counters at the blocked-verify moment).
- **P3 — staging marker liveness underspecified**: research.md R5 corrected (marker write is load-bearing; if it fails, abort transfer before robocopy starts; clarified PID-marker is diagnostic vs OS-lock proof of liveness).

Round 22 found NO issues with: typed-confirmation work (FR-003 — FR-006), atomic retry direction (FR-001/FR-002), atomic counter pattern (FR-013 fundamentals).

The plan now reflects all round-22 corrections. Ready for `/speckit-tasks`.

---

## Summary of decisions

All NEEDS-CLARIFICATION items resolved. No external dependencies introduced (all use existing primitives). No new abstractions (R3, R6 reuse, R5 mirrors `instance_lock.dart`). Performance bounded (R2 sub-millisecond per connection-open; R5 sub-500ms per startup).

Ready to proceed to Phase 1 (data-model.md, quickstart.md, agent context update).
