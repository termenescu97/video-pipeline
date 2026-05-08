---
description: "Implementation tasks for feature 017 — executor correctness (v2.5.0)"
---

# Tasks: Executor Correctness (v2.5.0)

**Input**: Design documents from `/specs/017-executor-correctness/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md, quickstart.md (all complete; Codex round-4 ship verdict 2026-05-08)

**Tests**: Test tasks are explicitly required by spec — argv-shape regression (FR-001 enforcement), progress decoupling (FR-002), recovery (FR-006/007/018), case-only collision (FR-008), log goldens (FR-010/011/012), `_PlannedFile` contract (R-A9). Each appears as its own task.

**Organization**: Foundational schema + helper work first (blocks every story). Then US1 (P1, MVP — visible progress) → US2 (P1 — verification trust) → US3 (P1 — recovery) → US4 (P2 — logging) → US5 (P2 — collisions). Polish at the end.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete prior task)
- **[Story]**: F = foundational, US1-US5 = user stories, P = polish
- File paths absolute from repo root

---

## Phase 1: Setup

No setup tasks — project is established (CLAUDE.md, Drift, Flutter, GitHub Actions all in place).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Schema v8, PowerShell helpers, LogService, `_PlannedFile` consolidation, and DAO method additions. All five user stories depend on these.

**⚠️ CRITICAL**: No US1–US5 work can begin until this phase is complete.

### F-A3 Schema v8

- [ ] **T001** [F] Add enums `VerifyStatus { pending, verified, mismatch, unverified }` and `FailureKind { none, copyError, verifyMismatch, verifyUnreliable }` at the top of `lib/database/tables.dart` alongside existing enums.
- [ ] **T002** [F] Add 5 new columns to existing tables in `lib/database/tables.dart`: `JobFiles.verifyStatus` (textEnum, default 'pending'), `JobFiles.failureKind` (textEnum, default 'none'), `Jobs.unverifiedFiles` (integer, default 0), `Jobs.parentJobId` (nullable integer, references Jobs.id), `AppSettings.sourcesPanelCollapsed` (boolean, default false). Match `data-model.md` definitions verbatim.
- [ ] **T003** [F] Bump `schemaVersion` from 7 to 8 in `lib/database/database.dart`.
- [ ] **T004** [F] Add `if (from < 8) { … }` block to `onUpgrade` in `lib/database/database.dart` per `data-model.md` Migration v7 → v8 section. Wrap column adds + 6 backfill `customStatement` calls in `await transaction(() async { … })`. Do NOT split into separate transactions.
- [ ] **T005** [F] Run `dart run build_runner build --delete-conflicting-outputs` to regenerate `database.g.dart` after T001–T004. Commit the generated file.
- [ ] **T006** [F] [P] Add migration unit test at `test/unit/migration_v7_to_v8_test.dart`. Seed an in-memory `NativeDatabase.memory()` with v7 schema + sample rows (1 sha256-completed, 1 size-completed, 1 failed-with-hash-mismatch error, 1 failed-with-could-not-compute error, 1 failed-with-other-error, 1 transferAndCompress completed, 1 chained compression). Run migration. Assert backfill values per `data-model.md` rules.

### F-A1 PowerShell helper

- [ ] **T007** [F] Add `String escapePsLiteral(String s) => s.replaceAll("'", "''")` to a new `lib/utils/ps_escape.dart` (top-level function, exported). Add doc comment citing FR-001 and naming the safety claim (PS single-quote literals + `-LiteralPath`).
- [ ] **T008** [F] Add `Future<int> runPowerShellInlineScript({required String script, required String tag})` method to `lib/utils/process_runner.dart`. Internally: `Process.start('powershell', ['-NoProfile', '-Command', script])`. Assert (via Dart `assert` AND a runtime check) that `arguments.length == 3`. Stream stdout/stderr same as existing `run` method.
- [ ] **T009** [F] [P] Add unit test at `test/unit/process_runner_argv_test.dart`. Mock `Process.start` (use a local `IOOverrides` or a thin wrapper). Call `runPowerShellInlineScript`. Assert `arguments.length == 3` and the third element is the script string. Test runs on macOS without invoking PS.
- [ ] **T010** [F] [P] Add unit test at `test/unit/ps_escape_test.dart`. Fixtures: `Tibi's reels.mp4`, `IMG_[001].MP4`, `Ep. 60-63 *.MP4`, `file?.MP4`, `back\`tick.MP4`, `dollar$.MP4`, paths with U+2018, U+2019, ASCII path 280 chars long. Each fixture: assert `escapePsLiteral` doubles every `'` and leaves all other chars untouched.

### F-A2 PowerShell migration in services

- [ ] **T011** [F] Replace the broken pattern in `lib/services/transfer_service.dart::computeFileHash` (lines 87-101). New body uses `escapePsLiteral(filePath)` + `runPowerShellInlineScript({script: "(Get-FileHash -LiteralPath '${escapePsLiteral(filePath)}' -Algorithm SHA256).Hash", tag: 'computeFileHash'})`. Path validation: `if (filePath.isEmpty) throw ArgumentError('path empty')`. Long-path probe: log a `WARNING` (with `phase: LogPhase.preflight`) once per job if `filePath.length > 260`.
- [ ] **T012** [F] Replace the broken pattern in `lib/services/drive_service.dart::getDiskFreeSpace` (line ~141-148). Validate `dirPath`: reject empty, detect UNC via `dirPath.startsWith(r'\\')` (return null + log warning "free space check skipped for UNC path; v3.0 NAS feature adds support"). Drive-letter regex tightened to `^[A-Za-z]:` (caller passes `E:` not `E`). Use inline script `Get-PSDrive -Name <validatedLetter> | Select-Object -ExpandProperty Free` (single ASCII letter — no escape needed). Additionally implement the preflight long-path warning (FR-013 + R-A1): when `dirPath.length > 260` (or any planned destination > 260), log `WARNING` once at `phase=preflight` ("path exceeds Windows MAX_PATH; PS 5.1 may fail without `\\?\` prefix — surfacing only, not blocking job creation"). The warning does NOT block job creation.
- [ ] **T013** [F] Replace the broken pattern in `lib/services/drive_service.dart::getDriveIdentity` (lines ~172-184) using single-quote-escaped `-LiteralPath` for the WMI query parameter.
- [ ] **T014** [F] Replace the broken pattern in `lib/services/drive_service.dart::eraseDrive` (lines ~217-220) using single-quote-escaped `-LiteralPath` for `Remove-Item`.
- [ ] **T015** [F] [P] Audit other PowerShell call sites: `grep -n 'Get-FileHash\|Get-PSDrive\|Get-CimInstance\|Get-Volume\|Remove-Item\|Test-Path' lib/services/`. Migrate any survivors to inline-script + escape pattern. Document zero remaining `\$args\[` matches in the commit message.
- [ ] **T016** [F] Add CI guard: extend `.github/workflows/*.yml` (or local pre-commit if no CI lint workflow exists) with `! grep -rn '\$args\[' lib/`. Failing the build closes the loop on FR-001 forever.

### F-A6 LogService refactor

- [ ] **T017** [F] Add `enum LogPhase { enqueue, preflight, transfer, verify, compress, finalize, recover, shutdown }` to `lib/services/log_service.dart`.
- [ ] **T018** [F] Refactor `LogService.info`, `LogService.warning`, `LogService.error` to take optional named params `{int? jobId, int? fileIndex, int? totalFiles, LogPhase? phase}`. `error` ALSO takes `String? subprocessStderr`. Format per `research.md` R-A6 8-case table. One-arg calls (`info('App started')`) continue to work with no context bracket.
- [ ] **T019** [F] Implement stderr truncation INSIDE `LogService.error`: import `package:characters/characters.dart`, take first line via `split('\n').first.trim()`, then truncate by grapheme clusters via `firstLine.characters.take(200).toString()` + ellipsis when truncated.
- [ ] **T020** [F] [P] Migrate existing call sites of `logService.info/warning/error` to named-param API. Touch every file in `lib/` that imports `log_service.dart`. Mechanical migration: where the call already concatenates `Job #${job.id}`, extract to `jobId: job.id` and shorten the message. Where no useful context exists (e.g. `info('App started')`), leave one-arg.
- [ ] **T021** [F] [P] Replace the existing manual stderr-with-stack truncation in `lib/services/transfer_service.dart::computeFileHash` (lines 116-118, 125-128, 136-139) with `logService.error(..., subprocessStderr: stderr)` / `subprocessStderr: e.toString()` calls. Remove the multi-line stderr concatenation.
- [ ] **T022** [F] [P] Add INFO-level events at every phase boundary in `lib/services/job_queue_service.dart`. Specifically: phase=enqueue (job created), phase=preflight start/end, phase=transfer start/end + per-file copy success, phase=verify start/end + per-file verify success, phase=compress start/end + per-file compression success, phase=finalize (Slack sent), phase=recover (per rescued file), phase=shutdown (Phase A/B/C transitions in `lib/ui/screens/shell_screen.dart`).
- [ ] **T023** [F] [P] Add golden tests at `test/unit/log_format_test.dart`. Cover: (a) the no-context one-arg case explicitly: `info('App started')` → `[2026-05-08 14:00:00] [INFO] App started` (no bracket, backward-compat) — Codex round-1 L8 acceptance; (b) 4 levels × 9 phases (36 lines) for full-context calls; (c) 8 partial-context combinations from `research.md` R-A6 table; (d) truncation cases: empty stderr (skip the colon entirely), Windows CRLF, > 200-char single line (ellipsis suffix), multi-line (take first), emoji or surrogate-pair stderr (no mojibake — verify via `characters.length`).

### F-A9 `_PlannedFile` consolidation

- [ ] **T024** [F] Create `lib/services/planned_file.dart` with the consolidated immutable class: 5 fields (`sourcePath`, `destinationPath`, `fileName`, `fileSize`, `wasOverwriteApproved`), `copyWith({String? destinationPath, bool? wasOverwriteApproved})`. Mark `class PlannedFile` (drop the leading `_` since it's now public to both consumers).
- [ ] **T025** [F] Replace the duplicate definition in `lib/services/job_queue_service.dart:1048-1078` with `import 'planned_file.dart'`. Update all use sites in this file. Replace mutable assignments to `destinationPath`/`wasOverwriteApproved` with `copyWith` calls.
- [ ] **T026** [F] Replace the duplicate definition in `lib/ui/screens/create_job_screen.dart:1140-1173` with `import '../../services/planned_file.dart'`. Update all use sites.
- [ ] **T027** [F] [P] Add contract test at `test/contract/planned_file_contract_test.dart`. Test cases per `research.md` R-A9: full population, default `wasOverwriteApproved=false`, overwrite-true, rename via copyWith, skip resolution. Each test exercises BOTH consumers (`createBatchTransferJobs` mock + `_applyResolution` direct call).

### F DAO additions

- [ ] **T028** [F] Modify `lib/database/daos/job_file_dao.dart::markFileCompleted` (line ~58) to make `verified` parameter optional with default `false`. Existing call sites passing `verified: true` continue to work.
- [ ] **T029** [F] Add to `lib/database/daos/job_file_dao.dart`: `markFileVerified(int fileId, {required String sourceHash, required String destHash})` — sets `verified=true`, `verifyStatus=verified`, persists hashes. `markFileVerifyMismatch(int fileId, {String? sourceHash, String? destHash})` — sets `verifyStatus=mismatch`, `failureKind=verifyMismatch`. `markFileUnverified(int fileId)` — sets `verifyStatus=unverified`, `failureKind=verifyUnreliable`.
- [ ] **T030** [F] Add to `lib/database/daos/job_file_dao.dart`: `getFilesByStateAndVerify({required FileStatus status, required VerifyStatus verifyStatus})` — used by recovery (T046).
- [ ] **T031** [F] Add to `lib/database/daos/job_dao.dart`: `incrementVerified(int jobId)`, `incrementUnverified(int jobId)`. Both bump the relevant counter via raw `UPDATE jobs SET … = … + 1 WHERE id = ?` in a Drift `customUpdate`.
- [ ] **T032** [F] Add to `lib/database/daos/job_dao.dart`: `recomputeCountersFromFiles(int jobId)` — single Drift transaction running `UPDATE jobs SET completed_files = (...), completed_bytes = (...), unverified_files = (...) WHERE id = ?` derived from `JobFile` rows. Used by FR-018 recovery counter re-derivation.
- [ ] **T033** [F] Add to `lib/database/daos/job_dao.dart`: `getRescuedJobIds()` — returns `Future<Set<int>>` per FR-018 union: `Job.status='inProgress' UNION (jobs with any JobFile in inProgress OR (completed AND verifyStatus=pending))`.

**Checkpoint**: Foundation ready. F1-F33 must all be `[x]` before US1 begins.

---

## Phase 3: User Story 1 — Real-time progress visibility (Priority: P1) 🎯 MVP

**Goal**: Operator sees progress bar advance, file counter increment, phase indicator transition during a transfer — even if downstream verify is broken.

**Requires**: T028-T033 (DAO additions for `markFileVerified`/`markFileVerifyMismatch`/`markFileUnverified`/`incrementVerified`/`incrementUnverified`). T034 also depends on T028 (`markFileCompleted` made `verified: false` default).

**Independent Test**: Start a transferAndCompress with verbose logging. Watch the progress bar move within 5 s of the first file copy completing; counter increments; phase pill transitions. No need to wait for entire job.

- [ ] **T034** [US1] In `lib/services/job_queue_service.dart::_processTransfer` (lines 436-540), split the post-robocopy `_safeWrite` into two calls per `research.md` R-A4. After robocopy success: first `_safeWrite(() => _jobFileDao.markFileCompleted(file.id, verified: false))`, then `_safeWrite(() => _jobDao.updateJobProgress(job.id, completedFiles: completedCount, completedBytes: completedBytes))`. **Do NOT gate either on verify outcome** — bytes credit immediately when bytes are on disk.
- [ ] **T035** [US1] After hash check (lines ~488-512 in `_processTransfer`): on hash MATCH, call `_jobFileDao.markFileVerified(file.id, sourceHash, destHash)` + `_jobDao.incrementVerified(job.id)` (each in its own `_safeWrite`). On hash MISMATCH: `markFileVerifyMismatch` + `incrementFailed`. On hash subsystem error: `markFileUnverified` + `incrementUnverified`. **Never decrement** `completedFiles`/`completedBytes` from any verify outcome.
- [ ] **T036** [US1] In `lib/ui/widgets/job_card_active.dart`, perform all three card UI changes in sequence within a single PR slice (NOT [P] — same file): (a) `JobType.compression` UI hide-rule for verify counters per FR-017 — when `job.type == JobType.compression`, suppress the verify-axis stats line and show only `12 / 27 files · 38 GB / 161 GB`; (b) promote phase indicator to top of the card with `[Transfer] → [Verify] → [Compress?]` pills (active-phase primary, completed muted, upcoming outline; for `compression`-only show single `[Compress]` pill); (c) add second-line stats `verified / total · unverified` with warning color when `unverified > 0`, tabular figures on numerics so digit changes don't reflow. *(Codex tasks-review M5: original split into T036/T037/T038 [P] was unsafe — same file. Consolidated.)*
- [ ] **T037** [US1] [P] Add unit test at `test/unit/progress_decouple_test.dart`. Mock `TransferService.computeFileHash` to throw on every call (simulate broken hash subsystem). Run a 3-file `_processTransfer`. Assert: `Job.completedFiles == 3`, `Job.completedBytes == sum(fileSize)`, `Job.unverifiedFiles == 3`, `Job.status` NOT failed. Each file has `status=completed`, `verifyStatus=unverified`.

---

## Phase 4: User Story 2 — Trustworthy verification (Priority: P1)

**Goal**: SHA-256 verification works on all real Windows path shapes; mismatch surfaces actionable banner; Retry forces re-copy.

**Requires**: T028-T033 (DAO methods); T036 (active card UI) for the banner integration in T041.

**Independent Test**: Stage 27 files with varied path special chars. Run a transferAndCompress with SHA-256 enabled. All 27 files end at `verifyStatus=verified`. No PS parser errors in log.

- [ ] **T040** [US2] Wire `forceDestDelete: bool = false` parameter through `JobQueueService.retryFile(int fileId, {bool forceDestDelete = false})` and downstream `_processTransfer` (when called for a single retried file). When `forceDestDelete=true`: **bypass the entire feature-015 delete predicate** `wasOverwriteApproved || (everAttempted && isPartial)` AND short-circuit the size-match "skip robocopy" path. Concretely: at the dest-delete decision in `_processTransfer`, the gating expression becomes `forceDestDelete || wasOverwriteApproved || (everAttempted && isPartial)`. Even when `wasOverwriteApproved=false` and the dest size matches the source, `forceDestDelete=true` forces the delete-then-robocopy sequence so corrupt-but-same-size dests are actually replaced (Codex H2 closure, FR-005, SC-004). Log loudly with `phase=recover` and operator-driven attribution.
- [ ] **T041** [US2] [P] In `lib/ui/widgets/job_card_active.dart`, add verify-mismatch banner (FR-005). When job has any file at `verifyStatus=mismatch`: show banner with file count + actions `[Investigate]` (opens detail tabs) / `[Retry]` (calls `retryFile(forceDestDelete: true)` for each mismatched file — explicit `forceDestDelete=true` is operator-attribution per Constitution I) / `[Skip]` (marks file as skipped, removes from "needs attention"). Banner visible until all mismatch files resolve. *(Sequenced after T036 by Requires note above; safe to mark [P] vs T040, T042, T043, T044, T045 — different files.)*
- [ ] **T042** [US2] [P] In `lib/ui/widgets/files_tab.dart`, add per-file verifyStatus chip: ✓ verified (green), ⚠ unverified (yellow warning), ✗ mismatch (red), pending (no chip — show only if status != completed).
- [ ] **T043** [US2] [P] In `lib/services/slack_service.dart::notifyTransferCompleted`, expand signature with `int verifiedFiles, int unverifiedFiles, int mismatchedFiles` per `research.md` Slack expansion section. Body shows `Verified: N · Unverified: N · Mismatch: N`. Verdict line: warning prefix when `mismatched > 0` or `unverified > 0`; clean checkmark only when both zero. Update caller in `_processTransfer` to pass aggregate counts.
- [ ] **T044** [US2] [P] In `lib/services/slack_service.dart::notifyCompressionCompleted`, add 4 nullable params `Job? parentTransferJob, int? parentVerifiedFiles, int? parentUnverifiedFiles, int? parentMismatchedFiles`. When non-null: show "Transfer verification: …" line per `research.md` snippet. When all null: omit the line (standalone compression). *(Same file as T043 — these MUST be sequenced together in one PR slice; both edit `slack_service.dart`. Marked [P] vs all NON-slack-service tasks.)*
- [ ] **T045** [US2] In `lib/services/job_queue_service.dart::_createChainedCompressionJob` (line ~984), set `parentJobId: Value(transferJob.id)` in the `JobsCompanion.insert` call. Single-line addition. In `_processCompression` finalize (line ~725), if `job.parentJobId != null`: query parent via `_jobDao.getJob(job.parentJobId!)`, query parent's JobFile rows, count by verifyStatus, pass through to `notifyCompressionCompleted`. Graceful fallback if parent deleted: pass nulls.
- [ ] **T045a** [US2] [P] Add SC-004 acceptance test at `test/unit/retry_force_dest_delete_test.dart`. Seed: 1 file `status=completed`, `verifyStatus=mismatch`, `failureKind=verifyMismatch`, `wasOverwriteApproved=false`, dest exists with same size as source but different bytes (e.g., source: "abc", dest: "xyz", both 3 bytes). Call `JobQueueService.retryFile(fileId, forceDestDelete: true)`. Assert: dest is deleted before robocopy is invoked (mock robocopy and observe call order via `ProcessRunner` spy); after robocopy completes, file has `verifyStatus=verified`. **Crucial**: assert the loop does NOT short-circuit on size match.

---

## Phase 5: User Story 3 — Reliable recovery from abandoned shutdown (Priority: P1)

**Goal**: Job killed mid-verify resumes verify-only on relaunch. No double-credited bytes, no stranded files. Counters accurate.

**Requires**: T028-T033 (DAO methods, especially `getRescuedJobIds` and `recomputeCountersFromFiles`).

**Independent Test**: Start a job, kill the app between robocopy success and SHA-256 finish for one file. Relaunch. That file is verify-only on next run.

- [ ] **T046** [US3] In `lib/services/job_queue_service.dart::recoverStaleJobs`, extend per `quickstart.md` recovery example: collect `rescuedJobIds` via `_jobDao.getRescuedJobIds()`, reset inProgress files to pending (existing behavior preserved), then for each `status=completed && verifyStatus=pending` row: if source+dest exist on disk, queue verify-only via new `queueVerifyOnly(fileId)` method; else mark `unverified` + log warning at `phase=recover`.
- [ ] **T047** [US3] Add `JobQueueService.queueVerifyOnly(int fileId)` — schedules a verify-only retry for the file. Implementation: insert a small "verify-only" task into the queue or invoke verify pathway directly from the recovery loop without robocopy.
- [ ] **T048** [US3] After all stale-row mutations in `recoverStaleJobs` complete (FR-018), iterate `rescuedJobIds` and call `_jobDao.recomputeCountersFromFiles(jobId)` for each. Single re-derivation per job, regardless of which stale states were detected.
- [ ] **T049** [US3] [P] Add recovery integration test at `test/unit/recovery_test.dart`. Seed in-memory DB with: job in `status=inProgress`, JobFile rows in mix of `inProgress` and `completed + verifyStatus=pending`. Run `recoverStaleJobs`. Assert: inProgress files reset to pending; completed+pending files routed to verify; counters re-derived correctly; no double-credit.

---

## Phase 6: User Story 4 — Honest, structured logs (Priority: P2)

**Goal**: Operator can reconstruct any successful run from the log alone. Errors are concise.

**Requires**: T017-T023 (LogService API + LogPhase + truncation + goldens).

**Note on parallelism**: T050-T056 ALL edit `lib/services/job_queue_service.dart` (or its single-file callers within `_processJob`). Codex tasks-review HIGH 2 — these CANNOT run in parallel; same-file edits would conflict. Consolidated into ONE task (T050) covering every log boundary in `job_queue_service.dart`. Only T057 (different file) is left separate.

**Independent Test**: Run a successful 27-file job. Open log. INFO entries at every phase boundary + per-file copy + per-file verify success.

- [ ] **T050** [US4] In `lib/services/job_queue_service.dart`, add INFO-level structured log entries at ALL phase boundaries and per-file successes within `_processJob`/`_processTransfer`/`_processCompression`/`recoverStaleJobs`/`_finalize`. Single sweep, single file:
   - **enqueue** (job created): `'Job queued — type=$type, files=$totalFiles, bytes=$totalBytes'`
   - **preflight** start/end: include verdict (free space, conflicts, long-path warnings)
   - **transfer** start: `'Transfer phase started — N files, $bytes'`
   - **transfer** per-file success: `'Copied $fileName ($formatBytes(fileSize) in ${elapsed}s)'` with `jobId, fileIndex, totalFiles` set
   - **transfer** end: `'Transfer phase complete — copied=N/total, bytes=N/total, verified=N, unverified=N, mismatch=N, duration=Xm'`
   - **verify** start: `'Verify phase started — $verifyMode mode, N files'`
   - **verify** per-file success: `'$fileName verified (SHA-256 match)'`
   - **verify** end: `'Verify phase complete — verified=N, mismatch=N, unverified=N'`
   - **compress** start/per-file/end (analogous)
   - **finalize** (Slack sent, audit row inserted): `'Job $jobId finalized — Slack notified, audit row written'`
   - **recover** per rescued file: from T046's existing `phase=recover` warning, add an INFO companion when verify-only resume succeeds
- [ ] **T051** [US4] [P] In `lib/ui/screens/shell_screen.dart::_gracefulShutdown`, add INFO logs at each phase transition with `phase=shutdown`: Phase A start/end ("acquire shutdown flag"), Phase B start ("queue drain — timeout 10s") and end (success or timeout), Phase C start/end ("DB close, instance lock release, log close"). Different file from T050 — safe to mark [P].

---

## Phase 7: User Story 5 — NTFS case-only collision detection (Priority: P2)

**Goal**: Two source files differing only in case detected at preflight before they collide on NTFS.

**Independent Test**: Stage source with `DCIM/IMG_001.MOV` + `dcim/img_001.mov`. Start a transfer. Preflight detects collision and offers rename.

- [ ] **T058** [US5] In `lib/services/job_queue_service.dart::createBatchTransferJobs` (and the equivalent single-job path), build a `Set<String>` of `destinationPath.toLowerCase()` keys. On second-insertion collision: route through existing `_suffixed` rename pattern. Use the normalized-key set as the input to `_suffixed` so generated suffixes don't re-collide.
- [ ] **T059** [US5] [P] In `lib/ui/screens/create_job_screen.dart::_applyResolution`, surface case-only collisions to operator via inline list with auto-suggested rename per file (`img_001.mov → img_001 (1).mov`). Operator confirms or cancels.
- [ ] **T060** [US5] [P] Add unit test at `test/unit/collision_normalize_test.dart`. Fixture: 2 source files at `DCIM/IMG_001.MOV` and `subdir/img_001.MOV` mapped to same destination drive. Assert: normalized-key collision detected; `_suffixed` produces 2 distinct keys; both files end at distinct destinations.

---

## Phase 8: Polish & Validation

- [ ] **T061** [P] Run `flutter analyze`. Fix any new warnings introduced by tasks T001-T060.
- [ ] **T062** [P] Run `dart test` (or `flutter test`). All new tests pass; no existing tests broken.
- [ ] **T063** [P] Verify CI guard: `! grep -rn '\$args\[' lib/` returns empty. Run locally as well.
- [ ] **T064** [P] Update `CLAUDE.md` "Load-Bearing Conventions" section to add the v8 invariants: `verifyStatus` × `failureKind` axes; `Job.parentJobId` set only at chain time; `markFileCompleted(verified: false)` is the post-robocopy signal; counter re-derivation must run once per rescued job at end of recovery.
- [ ] **T065** [P] Update `CLAUDE.md` "Current State" + "What Works" sections to reflect v2.5.0-pending state for 017A.
- [ ] **T066** Run a Codex adversarial review of the implementation (`gpt-5.5 effort=high`). Address findings; iterate until clean.
- [ ] **T067** Operator runs Windows acceptance scenario on the workstation. Concrete checklist (must all pass; tag `v2.5.0-pre` is the test build):
   1. **SC-001 / FR-001 — hash path fixed**: insert SD card with 27 files / 161 GB containing paths with spaces, apostrophes, and special chars (`Tibi's reels.mp4` style). Start a transferAndCompress with SHA-256 enabled. Open log: zero `[ERROR]` lines containing `Unexpected token` or PowerShell parser dumps. All 27 files end with `verifyStatus=verified`.
   2. **SC-002 / FR-002 — progress bar unfrozen**: while transfer phase runs, the active job card shows progress bar advancing (bytes change visibly at least every 5 s) and file counter incrementing (`1 / 27 → 2 / 27 → …`) within 5 s of each file completing.
   3. **SC-002 / FR-003 — verify column / status visible**: per-file detail tabs show ✓ verified chip on completed files; mid-job, files show pending; on simulated mismatch (rename one source file mid-copy), affected file shows ✗ mismatch chip.
   4. **SC-004 / FR-005 — mismatch retry replaces destination**: rename a source file mid-copy to force a real mismatch (3 bytes differ at same total size). Operator clicks Retry on the file. Confirm via log + filesystem: dest file is deleted before robocopy runs. After robocopy + verify, file ends `verifyStatus=verified`.
   5. **SC-008 / FR-016 / FR-019 — Slack payloads include verify counts**: inspect the actual Slack webhook payloads (operator can replay via dev webhook). `notifyTransferCompleted` body includes `Verified: 27 · Unverified: 0 · Mismatch: 0`. For transferAndCompress, `notifyCompressionCompleted` body includes a `Transfer verification: Passed` line.
   6. **SC-005 / FR-010-FR-012 — log readable**: open `copiatorul3000.log`. INFO entries for every phase boundary + per-file copy success + per-file verify success with `[job=N file=K/27 phase=…]` prefix. ERROR entries (if any) are one line each; no multi-line PS parser dumps.
   7. **SC-003 / FR-006-FR-007 — recovery**: kill the app via Task Manager between copy and verify of one file. Relaunch. Job resumes; that file enters verify-only state on next run; bytes are NOT double-credited. Counter re-derivation matches expected per-row state.
   8. **SC-006 / FR-008-FR-009 — case-only collision**: stage source with `DCIM/IMG_001.MOV` + `dcim/img_001.mov`. Start a transfer. Preflight detects the collision and offers a rename option. Operator confirms; both files end at distinct destination paths.
   9. **SC-007 / FR-014-FR-015 — schema migration**: confirm via `sqlite3 video_pipeline.db .schema` that v8 columns are present and historical rows backfilled correctly (size-only completed → `unverified`; sha256-completed + `verified=1` → `verified`).

---

## Dependency notes

- F-A3 schema (T001-T006) **blocks** everything that touches `JobFile` / `Job` / `AppSettings`.
- F-A1/A2 PowerShell helpers (T007-T016) **block** US2 (T040-T045).
- F-A6 LogService (T017-T023) **blocks** US4 (T050-T057) but only because USR4 *is* the LogService work.
- F-A9 `_PlannedFile` (T024-T027) **blocks** US5 (T058-T060) — collision detection runs in the consolidated planning pathway.
- F DAO additions (T028-T033) **block** US1 (T034-T039), US2 (T043-T045), US3 (T046-T049).

Within Foundational phase: T001-T005 sequential (Drift codegen). Then T006 || T007-T010 || T017-T019 || T024-T027 in parallel.

US1 and US3 can run in parallel after Foundational completes (different file regions).

Polish phase (T061-T065) can interleave with US4 and US5; T066-T067 are end-to-end gates.

---

## Estimated tasks: 62

After Codex tasks-review consolidations:
- T036/T037/T038 (active-card UI) → consolidated to T036 (same file)
- T050-T056 (job_queue_service.dart logging) → consolidated to T050 (same file)
- T040 amended with explicit predicate-bypass language
- T012 extended with FR-013 long-path warning
- T023 extended with no-bracket backward-compat fixture
- T045a added (SC-004 force-dest-delete acceptance test)
- T067 expanded to enumerated 9-step operator checklist
- US1, US2, US3 headers gain explicit `Requires` annotations

5 user stories + 33 foundational + 7 polish + 1 added test (T045a) = 62 tasks. Aligns with plan.md Phase 2 estimate. The consolidations reduce parallel-execution risk without changing scope coverage.
