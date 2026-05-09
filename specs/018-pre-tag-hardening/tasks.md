# Tasks: Pre-Tag Hardening (v2.5.0)

**Input**: Design documents from `/specs/018-pre-tag-hardening/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md, quickstart.md (all committed)
**Tests**: included as per-FR unit tests — they're the success criteria for SC-001 through SC-010 and the gate for SC-012 (Codex round-23).

**Organization**: tasks grouped by user story (US1–US6, in priority order P1×2 → P2×2 → P3×2). Within each story, sequencing is DAO/SQL → service → UI → test.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable with other [P] tasks in the same phase (different files, no dependency).
- **[Story]**: which user story (US1…US6); Setup / Foundational / Polish phases have no story label.
- File paths absolute under `lib/` or `test/`.

---

## Phase 1: Setup (Shared Infrastructure)

No new dependencies. No new top-level directories. The existing Flutter + Drift + ConfirmationDialog primitives are sufficient (per spec.md Assumptions). Skipping straight to Phase 2.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Connection-open hook infrastructure that BOTH US4 (FK + cleanup) and US5 (errorMessage retroactive cleanup) consume. Must exist before either of those user stories can land.

⚠️ **CRITICAL**: The hook itself MUST be wired into Drift's `MigrationStrategy.beforeOpen` callback in `lib/database/database.dart`. Codex round-22 P3 verified this runs AFTER migrations and BEFORE all DAO queries.

- [ ] T001 In `lib/database/database.dart`, add a `beforeOpen: (details) async { ... }` callback to the `MigrationStrategy` returned from `migration` getter. Inside the callback, run statements in this order: (1) FR-009 dangling-FK cleanup `UPDATE`, (2) FR-012 stale-errorMessage cleanup `UPDATE`, (3) `PRAGMA foreign_keys = ON`. Each statement issued via `await customStatement(...)`. No early returns; all three run on every connection open.

**Checkpoint**: `database.dart` opens and `flutter analyze` is clean. No tests yet — those land per-story.

---

## Phase 3: User Story 1 — Atomic per-file retry (Priority: P1) 🎯 MVP

**Goal**: Operator-driven per-file retry survives a process crash with no silent intent loss.

**Independent Test**: `test/unit/retry_atomicity_test.dart` — synthetic interruption matrix; assert no "ghost pending" state reachable. Closes finding F-1, satisfies SC-001.

- [ ] T002 [US1] In `lib/database/daos/job_dao.dart`, add `Future<void> applyPerFileRetry({required int jobId, required int fileId, required bool forceDestDelete}) async`. Wrap the body in `transaction(() async { ... })`. Inside: (1) call `db.jobFileDao.resetFileForRetry(fileId, forceDestDeleteApproved: forceDestDelete)` semantics inline (file row reset preserving startedAt + clearing verify axis + setting forceDestDeleteApproved) — DO NOT call the existing method (it has its own transaction; nesting is fine but the gateway is cleaner inline), (2) update `jobs.status = JobStatus.queued`, `errorMessage = null`, `completedAt = null` for the parent jobId, (3) call `recomputeCountersFromFiles(jobId)`. Return on transaction commit; throw on any failure (caller's `_safeWrite` decides retry).

- [ ] T003 [US1] In `lib/services/job_queue_service.dart::retryFile`, replace the two existing `_safeWrite` calls (`_jobFileDao.resetFileForRetry(...)` + `_jobDao.requeueJobForFileRetry(...)`) with ONE: `await _safeWrite(() => _jobDao.applyPerFileRetry(jobId: file.jobId, fileId: fileId, forceDestDelete: forceDestDelete));`. The public signature `retryFile(int fileId, {bool forceDestDelete = false})` MUST stay unchanged. Existing log lines (the `forceDestDelete=true` warning) preserved.

- [ ] T004 [US1] Create `test/unit/retry_atomicity_test.dart`. Test cases: (1) successful per-file retry on a `verifyStatus=mismatch` row leaves file at `status=pending, verifyStatus=pending, forceDestDeleteApproved=true` AND parent at `status=queued, completedFiles/Bytes recomputed`; (2) successful retry on `verifyStatus=unverified` decrements `Job.unverifiedFiles`; (3) using `fake_async` + a Drift in-memory DB, schedule `applyPerFileRetry` and force a synthetic exception inside the transaction (mock the JobsTable `update` to throw at the second write) — assert NO state change is persisted (file row unchanged, parent unchanged, counters unchanged); (4) `forceDestDelete=false` does NOT touch `forceDestDeleteApproved` from a prior `true` value (idempotency).

**Checkpoint**: US1 testable on its own. SC-001 passing.

---

## Phase 4: User Story 2 — Typed-gate on trust-lowering decisions (Priority: P1)

**Goal**: Accept-mismatched, Accept-unverified, and Skip-mismatch require typed-confirmation matching the project convention.

**Independent Test**: `test/unit/typed_gate_coverage_test.dart` (widget tests) — for each of the three actions, assert button-disabled-until-typed-match-exact, case-sensitive, with case-hint surfacing on mismatch. Closes finding F-2, satisfies SC-002.

- [ ] T005 [P] [US2] In `lib/ui/widgets/job_card_done.dart`, locate the Accept-mismatched menu handler. Replace its current plain `AlertDialog.show...` (or `showDialog<bool>`) with `ConfirmationDialog.showDestructive(context: context, title: 'Accept mismatched files?', message: '<existing message>', typedConfirmation: 'accept mismatch', confirmLabel: 'Accept', cancelLabel: 'Cancel')`. Same on the Accept-unverified menu handler with `typedConfirmation: 'accept unverified'`. Both branches preserve their existing `if (confirmed) { /* call acceptMismatch / acceptUnverified */ ... }` shape.

- [ ] T006 [P] [US2] In `lib/ui/widgets/job_card_active.dart`, locate the `_VerifyMismatchBanner`'s Skip handler. Replace the plain `AlertDialog` with `ConfirmationDialog.showDestructive(context: context, title: 'Skip mismatched files?', message: '<existing message>', typedConfirmation: 'skip mismatch', confirmLabel: 'Skip', cancelLabel: 'Cancel')`.

- [ ] T007 [US2] Create `test/unit/typed_gate_coverage_test.dart` using `flutter_test`'s `WidgetTester`. Pump each of the three dialogs (mock the underlying acceptMismatch/acceptUnverified to no-op). Assertions per dialog: (1) Confirm button is disabled at first render; (2) typing the wrong phrase keeps it disabled; (3) typing a case-different variant of the phrase shows the "Case-sensitive match required" inline hint AND keeps the button disabled; (4) typing the exact phrase enables the button; (5) clicking the enabled button resolves with `true`; (6) clicking Cancel resolves with `false` regardless of what was typed.

**Checkpoint**: US2 testable on its own. SC-002 passing. US1 + US2 together = MVP per the spec's MVP scope.

---

## Phase 5: User Story 3 — Concurrency under operator interaction (Priority: P2)

**Goal**: Two-Accept stress produces one chained child (FR-007); stop-then-start race produces one processing loop (FR-008).

**Independent Test**: two unit tests — `test/unit/chain_dedup_test.dart` for FR-007 (SC-003), `test/unit/start_stop_race_test.dart` for FR-008 (SC-004).

- [ ] T008 [US3] In `lib/services/job_queue_service.dart`, add `Future<int?> createChainedCompressionJobIfAbsent(int parentJobId)` per research.md R7b. Wrap the entire body (`hasChainedChild` check + parent fetch + eligible-files computation + `getMaxSortOrder` + chained-job INSERT) in `_jobDao.transaction(() async { ... })`. Return `null` on dedup hit; return new child job id on insert. Wrap the outer call in `_safeWrite`.

- [ ] T009 [US3] In `lib/services/job_queue_service.dart`, replace the direct `_createChainedCompressionJob(job)` call site in `_processJob` (post-clean-transfer auto-chain) with `await createChainedCompressionJobIfAbsent(job.id);`. Also replace the `maybeChainCompression` body's gate path with the same call. The legacy private `_createChainedCompressionJob` method becomes an internal helper that the new gate calls inside its transaction; it MUST NO LONGER be called from outside the gate.

- [ ] T010 [US3] In `lib/services/job_queue_service.dart`, add a private `bool _stopRequested = false` field. Modify `stopProcessing()` to: (a) set `_stopRequested = true` synchronously before any other work, (b) preserve existing `_isProcessing = false` + `_stopCompleter` resolution. Modify the processing loop's `while (_isProcessing)` to `while (_isProcessing && !_stopRequested)`. Modify `startProcessing()`: if `_stopCompleter != null && !_stopCompleter.isCompleted`, `await _stopCompleter.future;` THEN synchronously re-check `if (_isProcessing) return;` THEN flip `_isProcessing = true; _stopRequested = false;` (the re-check + flip pair MUST be on consecutive lines with NO `await` between them — add a comment locking this in).

- [ ] T011 [P] [US3] Create `test/unit/chain_dedup_test.dart`. Use `fake_async` + in-memory Drift. Seed a transferAndCompress parent job with mixed mismatch + unverified files. Schedule TWO concurrent `createChainedCompressionJobIfAbsent(parentId)` calls. `flushMicrotasks()`. Assert `_jobDao.getChildrenOf(parentId).length == 1`. Repeat 100× to catch ordering edge cases.

- [ ] T012 [P] [US3] Create `test/unit/start_stop_race_test.dart`. Use `fake_async` + a stub queue with one synthetic job. Schedule `startProcessing()`, advance to mid-iteration, schedule `stopProcessing()`, then immediately schedule a second `startProcessing()` BEFORE flushing. Flush microtasks. Assert: only one processing loop is observed (track via a counter incremented at each loop entry). Repeat with N=100 concurrent second-starters; all should yield loop-count=1.

**Checkpoint**: US3 testable on its own. SC-003 + SC-004 passing.

---

## Phase 6: User Story 4 — FK enforcement + retroactive cleanup (Priority: P2)

**Goal**: PRAGMA foreign_keys = ON observably enforced; pre-existing dangling parent references cleaned up on first launch after this release.

**Independent Test**: `test/unit/fk_pragma_and_cleanup_test.dart` — seed dangling reference, open db, assert pragma + cleanup. Closes findings F-3, satisfies SC-005.

Phase 2 (T001) already wired the connection-open hook. This phase adds the test coverage for the FK side. (US5 will add the test coverage for the errorMessage side.)

- [ ] T013 [US4] Create `test/unit/fk_pragma_and_cleanup_test.dart`. Use a temp file-backed Drift database (NOT in-memory — pragma per-connection semantics matter). Test cases: (1) freshly-created db: `PRAGMA foreign_keys` returns `1`; (2) seed a dangling parent reference via `customStatement('INSERT INTO jobs ... parent_job_id=999, ...; DELETE FROM jobs WHERE id = 999;')` → close db → reopen → assert dangling row's `parent_job_id IS NULL`; (3) attempt to insert a new dangling reference (`INSERT INTO jobs (..., parent_job_id, ...) VALUES (..., 99999, ...)`) → expect FK violation error; (4) delete an existing parent that has a chained child → assert child's `parent_job_id` becomes NULL on subsequent read.

**Checkpoint**: US4 testable on its own. SC-005 passing.

---

## Phase 7: User Story 5 — Operator-facing reporting truthfulness (Priority: P3)

**Goal**: Slack messages, error text, counters, and progress credit all match underlying state. Bundles findings F-6, F-7, F-8, F-10.

**Independent Test**: 4 unit tests, one per sub-fix. Closes findings F-6/7/8/10, satisfies SC-006/SC-007/SC-008/SC-009.

### F-6 — Slack truth on size-mode transfer

- [ ] T014 [US5] In `lib/services/slack_service.dart::notifyTransferCompleted`, add a `int? notVerifiedFiles` named parameter. Update the verify-line composition: when `mismatched == 0 && unverified == 0`, render the passed-label using `verified + (notVerifiedFiles ?? 0)` — wording mirrors the round-20 fix to `notifyCompressionCompleted` (e.g., "$N verified · Passed" / "$N size-verified · Passed" / "A verified + B size-only · Passed"). Behavior unchanged for sha256-only transfers (notVerifiedFiles==0).

- [ ] T015 [US5] In `lib/services/job_queue_service.dart::_processTransfer`, after the existing per-state count tally for the Slack call, also count `verifyStatus == VerifyStatus.notVerified` from the local file iterations. Pass to `notifyTransferCompleted` as `notVerifiedFiles: notVerifiedCount`. Plumb the new variable through the loop the same way `verifiedCount` etc. flow.

- [ ] T016 [P] [US5] Create `test/unit/slack_size_mode_truth_test.dart`. Stub the Slack `_send` method to capture the body. Test cases: (1) clean size-mode transfer of 5 files → body must NOT contain "Verified: 0"; body must contain "5 size-verified · Passed" or equivalent non-zero phrasing; (2) clean SHA-256 transfer of 5 files → body must contain "5 verified · Passed" (regression — round-20 fix preserved); (3) mixed (operator-accepted history) → body shows verified + size-only sums.

### F-7 — Migration errorMessage cleanup

- [ ] T017 [US5] In `lib/database/database.dart`, locate the v8 migration's Phase 7 statement (the `UPDATE jobs SET status='completed' WHERE ...` block). Extend its SET clause to also write `error_message = NULL`. The WHERE clause is unchanged (rows being lifted from failed → completed because their only failed children were hash-only failures).

- [ ] T018 [US5] In `lib/database/database.dart`'s `beforeOpen` callback (added in T001), the `errorMessage` cleanup statement is the SECOND statement (between FR-009 cleanup and PRAGMA). The exact statement: `UPDATE jobs SET error_message = NULL WHERE status = 'completed' AND id IN (SELECT DISTINCT job_id FROM job_files WHERE verify_status IN ('mismatch', 'unverified')) AND id NOT IN (SELECT DISTINCT job_id FROM job_files WHERE status = 'failed') AND error_message IS NOT NULL;`. Idempotent (subsequent runs no-op via the `error_message IS NOT NULL` filter).

- [ ] T019 [P] [US5] Create `test/unit/migration_errormessage_test.dart`. Two test cases: (1) v7 → v8 migration on a synthetic db with one job (status=failed, errorMessage='5/10 files transferred, 5 failed copy', file rows = 5 hash-mismatch entries with no copy errors): after migration, assert job status=completed AND errorMessage IS NULL; (2) already-v8 db with the same shape (job lifted by Phase 7 but errorMessage NOT cleared in an earlier migration run): open the db with the new `beforeOpen` hook, assert errorMessage IS NULL after the open completes.

### F-8 — Counter consistency

- [ ] T020 [US5] In `lib/database/daos/job_file_dao.dart`, add `Future<void> markFileUnverifiedAndIncrement(int fileId)`. Wrap body in `transaction(() async { ... })`. Inside: (1) `(update(jobFiles)..where((t) => t.id.equals(fileId))).write(JobFilesCompanion(verifyStatus: Value(VerifyStatus.unverified), failureKind: Value(FailureKind.verifyUnreliable)))`, (2) `await db.jobDao.incrementUnverified(jobId)` where jobId is read from the file row in the same transaction. Return on commit.

- [ ] T021 [US5] In `lib/services/job_queue_service.dart::_processTransfer`, replace the two-call pattern at line ~459 (recovery branch SHA-256-fail) AND line ~797 (forward path SHA-256 subsystem failure) with single calls: `await _safeWrite(() => _jobFileDao.markFileUnverifiedAndIncrement(file.id));`. Also drop the local `unverifiedCount++` if the existing increment was paired with the DAO increment (read the surrounding code carefully — the local counter is used for end-of-loop Slack tally and may need to stay).

- [ ] T022 [US5] In `lib/database/daos/job_dao.dart`, wrap each of these read methods to invoke a self-healing recompute: `watchAllJobs()`, `watchCompletedJobs()`, `watchJob(int jobId)`, `getJob(int jobId)` (the four named in data-model.md). Pattern: before returning the row(s), run `recomputeUnverifiedIfDrifted(jobId)` for each affected job — a lightweight check that compares stored `unverifiedFiles` to `COUNT(*) WHERE verify_status='unverified'` and runs `recomputeCountersFromFiles(jobId)` if they disagree. Add the helper method.

- [ ] T023 [P] [US5] Create `test/unit/counter_consistency_test.dart`. Test cases: (1) `markFileUnverifiedAndIncrement` is atomic (synthetic exception inside transaction → no row change, no counter change); (2) seed a Job with stored `unverifiedFiles=0` but 2 file rows at `verifyStatus=unverified` (drift state), call `getJob(jobId)`, assert returned `unverifiedFiles=2` (self-healing fired); (3) same seed, call `watchJob(jobId)`.first, assert the same; (4) drift in the OTHER direction (stored=5, actual=0) is also corrected.

### F-10 — Size-mode progress crediting parity (POST CODEX ROUND-22 P1 CORRECTION)

- [ ] T024 [US5] In `lib/services/job_queue_service.dart::_processTransfer`'s size-mode branch (line ~824-865), restructure to match SHA-256 sequence EXACTLY: (1) after robocopy succeeds, call `await _safeWrite(() => _jobFileDao.markFileCompleted(file.id, verified: false));` (sets status=completed but verified=false — the v8 "copied but not yet verified" state), (2) `completedCount++; completedBytes += file.fileSize;` and `await _safeWrite(() => _jobDao.updateJobProgress(...))` (credit bytes immediately), (3) THEN call `await _transferService.verifyTransfer(...)`, (4) on success: `await _safeWrite(() => _jobFileDao.markFileSizeOnlyVerified(file.id));` (this finalizes verify axis to notVerified + flips legacy verified to true), (5) on failure: `await _safeWrite(() => _jobFileDao.markFileFailed(file.id, 'Verification failed: size mismatch'));` AND `failedCount++` AND undo the credited bytes (`completedCount--; completedBytes -= file.fileSize; await _safeWrite(() => _jobDao.updateJobProgress(...))` — yes, decrement is required because failed bytes shouldn't count). DO NOT use the original "reorder markFileSizeOnlyVerified before verifyTransfer" plan; that was the Codex round-22 P1 correction.

- [ ] T025 [P] [US5] Create `test/unit/size_mode_progress_order_test.dart`. Use a controlled `TransferService` test double whose `verifyTransfer` blocks on a `Completer<bool>` until released. Test: (1) spawn `_processTransfer` for a size-mode job with one 1GB file; (2) wait for robocopy mock to return success; (3) BEFORE releasing the verify completer, read `Job.completedBytes` from the DB — assert it equals 1GB (bytes credited immediately); (4) release verify completer with `true`; (5) read file row — assert verifyStatus=notVerified, verified=true; (6) repeat with verify completer released with `false` — assert file row at status=failed AND `Job.completedBytes` is back to 0 (decrement applied).

**Checkpoint**: US5 testable on its own. SC-006 + SC-007 + SC-008 + SC-009 all passing.

---

## Phase 8: User Story 6 — Filesystem hygiene (Priority: P3)

**Goal**: Orphaned staging dirs swept at startup; live ones (PID-marker validated) untouched.

**Independent Test**: `test/unit/staging_dir_sweep_test.dart`. Closes finding F-9, satisfies SC-010.

- [ ] T026 [US6] In `lib/services/transfer_service.dart::transferFile`'s renamed-destination branch, after the existing staging dir creation (`stagingDir = Directory(...)..createSync(recursive: true)`), write a `.live` marker file at `<stagingDir.path>/.live` containing two lines: `pid=${pid}\nexe=${Platform.resolvedExecutable}`. The write MUST be load-bearing: if `await markerFile.writeAsString(...)` throws, await `stagingDir.delete(recursive: true)` then rethrow. The transfer aborts before `robocopy` is invoked — operator sees the failed file with a clean error.

- [ ] T027 [US6] In `lib/services/job_queue_service.dart`, add `Future<void> sweepOrphanedStagingDirs()`. Behavior: (1) collect distinct destination roots from jobs in non-terminal status (queued, paused, inProgress) UNION the most-recently-completed job's destination root; (2) for each root: if not currently mounted (Directory.existsSync returns false), skip silently; (3) for each mounted root, list children matching pattern `.tmp_robocopy_*`; (4) for each match: read the `.live` marker — if absent OR PID doesn't exist in OS process table OR PID's executable path doesn't match `Platform.resolvedExecutable`, `await dir.delete(recursive: true)`; (5) log every removal at INFO level with `LogPhase.recover`. Wire the call into `recoverStaleJobs` (or whatever method orchestrates startup recovery) so it runs at the same hook point.

- [ ] T028 [P] [US6] Create `test/unit/staging_dir_sweep_test.dart`. Use a temp directory as the synthetic destination root. Test cases: (1) seed an empty `.tmp_robocopy_FAKETAG/` (no `.live`) → `sweepOrphanedStagingDirs()` removes it; (2) seed `.tmp_robocopy_FAKETAG/.live` containing `pid=99999\nexe=/nonexistent/path` → removed; (3) seed `.tmp_robocopy_FAKETAG/.live` with the current process's PID + exe path → NOT removed; (4) seed an unmounted destination root path (a directory deleted between seed and sweep) → no error, no removal attempt; (5) verify total wall-clock latency for a 3-root sweep under 500ms via `Stopwatch`.

**Checkpoint**: US6 testable on its own. SC-010 passing.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T029 Run `flutter analyze --no-pub` from repo root. MUST report 0 issues. Fix any analyzer warnings introduced by the new code (likely zero; the patterns reused are existing).

- [ ] T030 Run `flutter test` from repo root. MUST report 88 passing (78 existing + 10 new from T004/T007/T011/T012/T013/T016/T019/T023/T025/T028). Investigate any regression in the existing 78 tests — this would indicate a behavior change in shared paths and likely needs review.

- [ ] T031 Update `CLAUDE.md` "v8 (017A) Load-Bearing Conventions" + "v8 (017B) Load-Bearing Conventions" sections with new invariants from this feature: (a) per-file retry is atomic (single transaction in `applyPerFileRetry`), (b) typed-confirmation gate on Accept-mismatched / Accept-unverified / Skip-mismatch via `ConfirmationDialog.showDestructive`, (c) chain-dedup centralized via `createChainedCompressionJobIfAbsent`, (d) `_stopRequested` flag pattern with no-await between re-check and flip, (e) `PRAGMA foreign_keys = ON` set in `beforeOpen`, (f) connection-open idempotent cleanup statements (FK + errorMessage), (g) `markFileUnverifiedAndIncrement` is the single atomic primitive for SHA-256 subsystem failure paths, (h) self-healing recompute on the 4 named DAO read paths, (i) size-mode `_processTransfer` mirrors SHA-256 sequence (markFileCompleted before verify), (j) `.live` marker write in `transferFile` is load-bearing.

- [ ] T032 Codex round-23 adversarial review on the implementation (`codex exec -c model="gpt-5.5" -c model_reasoning_effort="high"` with a hostile review prompt referencing the new code). Fold any P1/P2 findings back into source + tests; commit fixes; re-run T029 + T030. P3 findings: defer to v2.5.1 (logged, not fixed).

- [ ] T033 Update `RELEASE_NOTES_v2.5.0.md` with a "Pre-tag hardening (018)" subsection listing the 10 closed findings + the 1 P1 + 3 P2 + 6 P3 round-22 corrections + the round-23 verdict.

- [ ] T034 Merge `018-pre-tag-hardening` → `017-ux-restructuring` (which carries the v2.5.0 staging) → `main`. Tag `v2.5.0-pre`, push, let GitHub Actions build the Windows .exe.

- [ ] T035 Operator acceptance — Windows workstation runs the 13-step T067 checklist from RELEASE_NOTES_v2.5.0.md. After all 13 pass, promote `v2.5.0-pre` → `v2.5.0` (re-tag, re-push).

---

## Dependencies

- Phase 2 (T001) BLOCKS Phase 6 (T013 reads pragma state) AND Phase 7 (T018 needs the connection-open hook to exist).
- Phase 3 (US1) is independent of everything else.
- Phase 4 (US2) is independent of everything else (UI-only changes + widget tests).
- Phase 5 (US3): T008/T009 (chain dedup) are independent of T010 (stop/start flag); T011 depends on T008; T012 depends on T010.
- Phase 6 (US4) depends on Phase 2 (T001).
- Phase 7 (US5): T014/T015/T016 (Slack) independent of T017/T018/T019 (errorMessage) independent of T020/T021/T022/T023 (counter atomicity) independent of T024/T025 (size-mode reorder). All 4 sub-clusters parallel within US5.
- Phase 8 (US6): T026 (marker write) BLOCKS nothing else; T027 (sweep helper) reads marker semantics from T026 conceptually but is implementable in parallel with code stubs; T028 depends on both.
- Phase 9 polish runs sequentially: T029 → T030 → T031 → T032 → T033 → T034 → T035.

## Parallel execution opportunities

Within the same `[P]` group + same phase, the following sets can run in parallel:

- Phase 4 (US2): T005 + T006 (different files: job_card_done.dart vs job_card_active.dart).
- Phase 5 (US3): T011 + T012 (different test files; T011 depends on T008 done, T012 depends on T010 done).
- Phase 7 (US5): T016 + T019 + T023 + T025 (four different test files, no inter-dependency once their respective implementation tasks are done).
- Phase 8 (US6): T026 implementation can proceed in parallel with T027 implementation (different files, marker-format is contractual — agree on the 2-line key=value format upfront).

## Implementation strategy

**MVP**: Phase 2 (foundational) + Phase 3 (US1) + Phase 4 (US2). After this slice merges + tests pass, the v2.5.0 tag could theoretically go out — the two P1 findings are closed. But the operator's "bundle deferred fixes before asking for QA" preference means we hold for the full bundle.

**Incremental delivery**: each user story is independently testable + reviewable. Phases 3, 4, 5, 6, 7, 8 could each be its own PR if we wanted; bundling in one branch matches the project's existing pattern.

**Risk gates**: T030 (88 tests pass) + T032 (Codex round-23 no new P1/P2) + T035 (operator T067 acceptance) are the three gates. Failing any gate means iterate, not skip.

## Validation

Total tasks: 35. Each follows the strict checklist format with checkbox + ID + (optional) [P] + (optional) [Story] + file path. All file paths are absolute under `lib/` or `test/`. Every user story has at minimum one DAO/service/UI task + one test task. The polish phase covers the project-policy gates (analyze, test, CLAUDE.md, Codex round, release notes, merge, tag, acceptance).
