# Tasks: Workflow-Integrity Hardening (v2.5.0)

**Branch**: `019-workflow-integrity-hardening`
**Plan**: [plan.md](./plan.md)
**Spec**: [spec.md](./spec.md)
**Findings**: [v2.5.0-audit-findings.md](../v2.5.0-audit-findings.md)

Tasks are grouped by phase from `plan.md`. Within a phase, tasks are sequenced — `[P]` means the task can run in parallel with other `[P]`s in the SAME phase. `[USn]` tags trace back to the user story in spec.md. Each task names the file(s) it touches AND the test that verifies it.

## Phase 1 — Schema v8 → v9

- [ ] **T001** [US1] In `lib/database/tables.dart`, add `TextColumn get sourceDriveSerial => text().nullable()();` to the `Jobs` table. Place it near the existing `operatorName` column for grouping.
- [ ] **T002** [US1] In `lib/database/database.dart`, bump `schemaVersion` from 8 to 9. Add a new `if (from < 9) { await m.addColumn(jobs, jobs.sourceDriveSerial); }` block to `onUpgrade`. NO backfill UPDATE — legacy rows stay null and are detected via the runtime banner path. Place this block AFTER the existing `if (from < 8)` block, OUTSIDE the v8 transaction (each migration step is its own atomicity boundary).
- [ ] **T003** [US1] Run `dart run build_runner build --delete-conflicting-outputs` to regenerate `lib/database/database.g.dart`. Commit the generated file. Verify no other generated files churned.
- [ ] **T004** [P] [US1] Create `test/unit/migration_v8_to_v9_test.dart`. Cases: (1) fresh-install opens AppDatabase at v9, asserts `schemaVersion == 9` AND the `sourceDriveSerial` column exists; (2) seed a v8 db (use `MigrationStrategy` with explicit `from: 8`), open as v9, assert column added with NULL for all existing rows AND no other rows touched; (3) `beforeOpen` invariants from 018 (FK pragma, `idx_job_files_job_id`, errorMessage cleanup) still fire post-migration.

## Phase 2 — Drive-identity capture + re-check (US1, FR-001 — FR-004)

- [ ] **T005** [US1] In `lib/services/job_queue_service.dart::createBatchTransferJobs`, before each `JobsCompanion.insert(...)`, call `final serial = await _driveService.getDriveIdentity(card.path);`. Pass `sourceDriveSerial: Value(serial)` to the companion. If `getDriveIdentity` returns null (transient WMI failure), log a warning at `LogPhase.preflight` and proceed with `Value(null)` — the job will trigger the legacy-banner path at first transfer-resume.
- [ ] **T006** [US1] In `lib/ui/screens/create_job_screen.dart`, mirror the T005 capture for the single-job creation path. Same null-handling rule.
- [ ] **T007** [US1] In `lib/services/job_queue_service.dart::_processJob`, immediately after the existing `if (!await sourceDir.exists())` check (line ~417), insert the drive-identity re-check block per plan.md "Re-check at transfer-resume". Three branches:
  - **Job has serial AND current matches**: proceed to existing logic.
  - **Job has serial AND current differs OR current is null**: `_safeWrite` `markJobPaused(reason: '...')`, surface UI mismatch banner, return without processing.
  - **Job has no serial (legacy v8)**: surface a one-time per-job legacy banner via a new `_legacyJobBannerShown` Set keyed by job.id, then proceed without re-check.
- [ ] **T008** [US1] In `lib/database/daos/job_dao.dart`, verify `markJobPaused` accepts a reason parameter that gets persisted to `Job.errorMessage`. If not, add `Future<void> markJobPaused(int jobId, {String? reason})`. The reason text becomes the operator-visible banner content.
- [ ] **T009** [US1] In `lib/ui/widgets/erase_drive_action.dart`, in the eligibility evaluation function (likely `_evaluateEraseEligibility` or similar), after the existing checks, add the drive-identity re-check per plan.md "Re-check at erase-eligibility". Same three-branch logic. The mismatch / null cases return `EraseEligibility.refused(message)` so the typed-confirmation dialog never opens.
- [ ] **T010** [US1] Create `test/unit/drive_identity_check_test.dart`. Stub `DriveService.getDriveIdentity` to return controllable values. Cases: (1) job created with serial X, resume when current returns X → executor proceeds; (2) job created with serial X, resume when current returns Y → executor pauses with "Card identity mismatch" reason; (3) job created with serial X, resume when current returns null → executor pauses with "Could not verify card identity" reason; (4) job created with null serial (legacy v8 row), resume → executor proceeds, banner-shown set populated; (5) erase-eligibility on serial-X job with current=Y → refused; (6) erase-eligibility on serial-X job with current=X → typed-gate proceeds.

## Phase 3 — Erase-time card-content reconciliation (US2, FR-005 — FR-007)

- [ ] **T011** [US2] In `lib/ui/widgets/erase_drive_action.dart` (eligibility function), AFTER the Phase 2 identity re-check, add the card-content reconciliation block per plan.md "Erase-time card-content reconciliation". Use `await driveService.listVideoFiles(job.sourcePath)` (existing function) to enumerate current files. Build the planned-paths set from `jobFileDao.getFilesForJob(job.id)` with case-insensitive normalization (`p.canonicalize(...).toLowerCase()`). Diff: any file present on card NOT in planned set → refusal.
- [ ] **T012** [US2] In `lib/utils/constants.dart`, expose the video-extension allowlist as a public const (or verify it's already exposed) so `listVideoFiles` and the rescan use the same source. NO modifications to the allowlist — symmetric criteria are the load-bearing invariant per Q2/A.
- [ ] **T013** [US2] In the refusal message construction, format as: `"${unplanned.length} file(s) added to card after job created (${unplanned.take(5).map((f) => p.basename(f.path)).join(", ")}${unplanned.length > 5 ? "..." : ""}) — re-create job or remove files before erase."`. The sample-of-5 keeps the message scannable.
- [ ] **T014** [P] [US2] Create `test/unit/erase_rescan_test.dart`. Use a temp directory as the synthetic SD card source. Cases: (1) seed 5 .MOV files, create a job covering all 5, rescan → eligibility passes; (2) seed 5 .MOV files, create a job covering 5, then drop a 6th .MOV onto the temp dir → eligibility refused with count=1 + filename in message; (3) seed 5 .MOV files, create a job covering 5, then DELETE one .MOV from the temp dir → eligibility passes (operator-driven deletion is permitted); (4) seed 5 .MOV files + 2 .THM sidecars, create job (only .MOV in planned set per allowlist), rescan → eligibility passes (the .THM files are not in the rescan set either, so no false positive); (5) seed 30 .MOV files, drop 8 unplanned, rescan → refusal message lists 5 + "..." truncation marker.

## Phase 4 — Source-side symlink guard (US3, FR-008 — FR-009)

- [ ] **T015** [US3] In `lib/services/drive_service.dart::listVideoFiles`, change `dir.list(recursive: true)` to `dir.list(recursive: true, followLinks: false)`. Per-entry, before yielding, call `final type = await FileSystemEntity.type(entity.path, followLinks: false);` and `continue` if `type == FileSystemEntityType.link`. Log skipped entries via `_logService?.warning('Skipped symlink at ${entity.path}', phase: LogPhase.preflight)`.
- [ ] **T016** [US3] In `lib/services/job_queue_service.dart::createBatchTransferJobs`'s enumeration (the `Directory.list` call site at line ~1400), apply the same `followLinks: false` + per-entry type check. Same warning log on skip.
- [ ] **T017** [US3] In `lib/services/drive_service.dart::prepTestCards` (line ~291, also uses `recursive: true`), apply the same guard. Test-card prep is operator-driven and shouldn't blindly walk symlinks either.
- [ ] **T018** [P] [US3] Create `test/unit/source_symlink_guard_test.dart`. Use temp dirs to construct: (1) a source dir with 3 regular .MOV files + 1 symlink to an unrelated dir → `listVideoFiles` yields exactly 3 entries, log records 1 "Skipped symlink"; (2) a source dir with a junction pointing back into itself → `listVideoFiles` completes in < 1 s (no infinite recursion), the junction is skipped + logged; (3) a source dir with 5 regular .MOV files (no symlinks) → identical behavior to v2.4.0 (5 entries, no log noise).

## Phase 5 — Force-delete deferred clear (US4, FR-010 — FR-012)

- [ ] **T019** [US4] In `lib/services/job_queue_service.dart::_processTransfer`, REMOVE the `clearForceDestDeleteApproved` call from the top-of-loop block (line ~705-709). The local `forceDestDelete = file.forceDestDeleteApproved` variable assignment STAYS (it drives the in-loop delete logic).
- [ ] **T020** [US4] In `lib/services/job_queue_service.dart::_processTransfer`, ADD a `clearForceDestDeleteApproved` call IMMEDIATELY AFTER `markFileCompleted(verified: false)` in BOTH the SHA-256 path AND the size-mode path (the T024-restructured one). Wrap in `if (forceDestDelete) { await _safeWrite(() => _jobFileDao.clearForceDestDeleteApproved(file.id)); }` — no work if not armed.
- [ ] **T021** [US4] In `lib/database/daos/job_file_dao.dart::acceptMismatch`, add `forceDestDeleteApproved: const Value(false)` to the existing `JobFilesCompanion` write. Mirror in `acceptUnverified`. These are already wrapped in transactions; the addition is one column to the existing write.
- [ ] **T022** [P] [US4] Create `test/unit/force_delete_deferred_clear_test.dart`. Cases: (1) arm forceDestDelete on a file, run executor with a controllable TransferService that returns success → after run, column reads `false` (cleared on success); (2) arm forceDestDelete, run executor with a TransferService that returns failure → column STILL reads `true` (preserved on failure); (3) arm forceDestDelete, run executor with TransferService that throws mid-call (simulates crash) → column STILL reads `true`; (4) arm forceDestDelete on a mismatch file, call `acceptMismatch` → column reads `false` (accept clears stale approval); (5) arm forceDestDelete on an unverified file, call `acceptUnverified` → column reads `false`.

## Phase 6 — HandBrake staging + sweep extension (US5, FR-013 — FR-017)

- [ ] **T023** [US5] In `lib/services/compression_service.dart::compressFile`, refactor to the staging-dir pattern per plan.md "HandBrake staging". Construct `<dirname>/.tmp_handbrake_<microsecondsTag>/`. Create dir, write `.live` marker (host=, pid=, exe=) with the SAME inner-try-catch + Error.throwWithStackTrace pattern as 018 T026. Pass `<stagingDir>/<basename>` as HandBrake's `-o` argument. On exit code 0: `File.rename` staging file → final output; best-effort staging-dir cleanup with separate try/catch (per 018 round-11 P3 split). On non-zero exit: best-effort staging-dir cleanup; return false.
- [ ] **T024** [US5] In `lib/services/startup_sweep.dart::sweepOrphanedStagingDirs`, extend the roots collection. Currently collects `j.destinationPath` from non-terminal + recent terminal jobs. ADD: `j.compressionOutputPath` from the same job sets when non-null. Dedup the `roots` set (already a `Set<String>`).
- [ ] **T025** [US5] In `lib/services/startup_sweep.dart`, extend the matcher in the per-root loop. Currently: `if (!name.startsWith('.tmp_robocopy_')) continue;`. Change to: `if (!name.startsWith('.tmp_robocopy_') && !name.startsWith('.tmp_handbrake_')) continue;`. The host-only liveness check (round-25) applies identically — same `_readMarkerOwner` + same delete logic.
- [ ] **T026** [P] [US5] Create `test/unit/handbrake_staging_test.dart`. Use a controllable CompressionService double if needed, OR (cleaner) a real CompressionService with a stub ProcessRunner that returns controllable exit codes. Cases: (1) compressFile returns success → final output exists at expected path, no `.tmp_handbrake_*` siblings; (2) compressFile returns failure (non-zero exit) → final output does NOT exist, staging dir is removed; (3) seed an orphan `.tmp_handbrake_OLD/` with no marker under a job's compressionOutputPath, run sweep → orphan removed; (4) seed an orphan with foreign-host marker → orphan PRESERVED (cross-machine NAS guard).

## Phase 7 — Bundled defenses (US6/US7/US8, FR-018 — FR-020)

- [ ] **T027** [US6] In `lib/services/slack_service.dart::_send`, move `final url = await _getWebhookUrl();` from BEFORE the try block to INSIDE it. Update the catch block to log via `logService.error('Slack notification failed (settings or send): $e')` so settings-DAO failures are also captured. The pipeline-caller path stays unaffected.
- [ ] **T028** [P] [US6] Create `test/unit/slack_settings_failure_test.dart`. Stub `SettingsDao` to throw on `getSettings()`. Call `SlackService(settingsDao: stub)._send('test')` (or via a public notify method). Assert: no exception propagates; logService captured the failure.
- [ ] **T029** [US7] In `lib/services/transfer_service.dart::computeFileHash`, before constructing the PowerShell script, compute `final pathForPS = path.length > 240 ? r'\\?\' + path : path;` then `final escaped = escapePsLiteral(pathForPS);`. Pass `escaped` into the script template.
- [ ] **T030** [US7] In the recovery-branch hash calls in `lib/services/job_queue_service.dart::_processTransfer` (around line ~540 + ~865), the calls go through `computeFileHash` already, so the FR-019 fix in T029 covers them. Verify by reading the current code; no separate edit if it's a single helper.
- [ ] **T031** [P] [US7] Create `test/unit/long_path_hash_test.dart`. On macOS dev (cross-platform path test), construct a temp file at a path > 260 chars (use deeply-nested temp dirs). Call `computeFileHash`. Assert: the constructed PS script (capture via a script-spy on ProcessRunner if needed) contains `\\?\` prefix; for a normal-length file path, the script does NOT contain `\\?\`. (We can't actually run PowerShell on macOS, so the test asserts the SCRIPT shape, not the resulting hash.)
- [ ] **T032** [US8] In `lib/services/drive_service.dart::_runPowerShell`, add the assertion per plan.md FR-020:
  ```dart
  assert(
    args.length == 2 && args[0] == '-Command',
    'PS argv invariant violated in $tag: args after -NoProfile must be '
    "exactly ['-Command', script]. Got: $args. See 017A length-3 argv invariant.",
  );
  ```
  Place at the top of the helper, before the `Process.run` call.
- [ ] **T033** [US8] Add a CI grep guard to whichever script runs CI checks (likely a `Makefile` target or a section in `CLAUDE.md` documenting manual checks). Line: `! grep -rn "Process\\.run\\('powershell'" lib/services/ | grep -v 'process_runner.dart'`. Document in `CLAUDE.md` → "v9 (019) Load-Bearing Conventions" alongside the existing `! grep -rn '\$args\[' lib/`.
- [ ] **T034** [P] [US8] Create `test/unit/runpowershell_argv_guard_test.dart`. Cases: (1) call `DriveService._runPowerShell(['-Command', 'Get-PSDrive'], tag: 'test')` → succeeds (shape conforms); (2) call with `['-Command', 'script', 'extra']` → AssertionError thrown in debug mode with message naming the helper. The second case requires either reflection or making `_runPowerShell` `@visibleForTesting` public.

## Phase 8 — Codex round 27a (POST-tasks, PRE-implementation)

- [ ] **T035** Fire Codex round 27a per spec.md SC-010 + Q5/B clarification. Hand off:
  - The committed `spec.md` + `plan.md` + `tasks.md` (this file).
  - The audit-findings doc (`specs/v2.5.0-audit-findings.md`).
  - The CLAUDE.md "v8 (018) Load-Bearing Conventions" section as preserved-invariants context.
  - Hostile-review prompt: "Find P1/P2 design errors in this plan + tasks BEFORE any code is written. Specifically attack: (a) the drive-identity null-handling fail-closed rule under transient WMI flakiness (does the legacy-banner path open a backdoor?); (b) the erase-rescan vs enumeration symmetry (any path that enumerates without rescan, or vice versa?); (c) the source-side symlink guard's per-entry type check vs `dir.list(followLinks: false)` redundancy (are both needed?); (d) the force-delete deferred-clear ordering — exactly which atomic boundary should clear sit on?; (e) HandBrake staging atomic-rename across volume boundaries; (f) the sweep matcher addition false-positive risk; (g) the long-path \\?\ prefix interaction with `escapePsLiteral` (does the prefix break under double-escaping?); (h) the length-3 argv assert vs runtime production builds (is debug-only assertion enough, or does production need a runtime check?)."
  - Use `codex exec --model gpt-5.5 --effort high`.
- [ ] **T036** Fold round-27a findings back into spec.md + plan.md + tasks.md. P1: MUST fold. P2: fold if cheap; document if expensive (with rationale). P3: defer to round-27b discussion. Re-commit corrected docs. If material design changes, re-fire round-27a until clean.

## Phase 9 — Implementation

- [ ] **T037** Implement Phases 1-7 per the post-round-27a tasks. Per the 018 checkpoint discipline, COMMIT PER PHASE (not all at once). After each phase: `flutter analyze` clean + `flutter test` green + commit with a descriptive message tracing the phase + tasks.
- [ ] **T038** [verification gate after Phase 9 complete] `flutter analyze --no-pub` MUST report 0 issues. `flutter test` MUST report all baseline (126) + new (~9 new files, ~30 new test cases targeting ~155 total) tests passing.

## Phase 10 — Codex round 27b (POST-implementation)

- [ ] **T039** Fire Codex round 27b per spec.md SC-010. Hand off:
  - The committed branch HEAD (full implementation of Phases 1-7).
  - List of commits since branch base (so the reviewer can scope diffs).
  - Same load-bearing-conventions context as round-27a.
  - Hostile-review prompt: "The 019 implementation lands the 5 convergent + 3 bundled findings from the holistic audit. Round-27a reviewed the design. NOW review the CODE. Specifically attack: (a) any place the runtime behavior differs from the planned behavior; (b) test coverage gaps — does each FR have a test that would fail if the FR's protection were removed?; (c) the schema migration's interaction with the 018 beforeOpen invariants (FK pragma, idx, errorMessage cleanup); (d) the legacy-banner state (in-memory Set) — does it leak across app restarts in a way that re-shows the banner annoyingly OR fail to re-show after a crash mid-banner?; (e) the erase-rescan's interaction with the existing JobFile-completion-eligibility checks (does refusal happen at the RIGHT layer, or could a different code path bypass)? (f) HandBrake staging: what if HandBrake itself writes intermediate files OUTSIDE the staging dir (e.g., temp files in %TEMP%)? Does the staging-dir guarantee actually hold?"
  - Use `codex exec --model gpt-5.5 --effort high`.
- [ ] **T040** Fold round-27b findings back. P1: MUST fold. P2: fold if cheap. P3: log in CLAUDE.md → "Open bugs deferred to v2.5.1". Re-run T038 verification gate after fixes.

## Phase 11 — Docs + merge prep

- [ ] **T041** Update `CLAUDE.md`. Two-part:
  - **Add new section "v9 (019) Load-Bearing Conventions"** with the 8 invariants from plan.md Phase 11 list:
    - `Job.sourceDriveSerial` captured at create, re-checked at transfer-resume + erase-eligibility, fail-closed on null
    - Erase-eligibility rescans card content; refuses on unplanned files
    - Source-side enumeration uses `followLinks: false` + per-entry type check
    - `clearForceDestDeleteApproved` happens AFTER `markFileCompleted(verified: false)`, NOT at top of iteration
    - HandBrake compression uses staging-dir convention symmetric with transfer pipeline
    - Slack `_getWebhookUrl()` runs INSIDE `_send`'s try block
    - SHA-256 hashing prepends `\\?\` for paths > 240 chars
    - `drive_service::_runPowerShell` enforces length-3 argv via assertion
  - **Update "Project scope" section**: bump the v8 → v9 reference; note that v9 added one column with no data backfill.
  - **Update "Current State" table**: 019 → ✅ Complete (after merge).
- [ ] **T042** Update `RELEASE_NOTES_v2.5.0.md`. Add a "Workflow-integrity hardening (019)" subsection summarizing:
  - The holistic audit context (parallel Opus + Codex round 26 with same threat-model prompt)
  - 5 convergent findings (3 P1 + 2 P2) closed
  - 3 bundled cheap defenses
  - 5 single-auditor findings explicitly deferred to v2.5.1 (with one-line rationale each)
  - Codex rounds 27a + 27b verdicts
  - Updated test count (126 → ~155)
  - Schema bump v8 → v9 (one column, no backfill)
- [ ] **T043** Add to CLAUDE.md → "Open bugs deferred to v2.5.1": F-D1 (size-mode TOCTOU), F-D3 (sweep prefix collision), F-D4 (cross-machine NAS write race), F-D5 (DST/clock-jump mtime), F-D8 (eraseDrive Remove-Item -LiteralPath). One line per bullet with the source finding ID.

## Phase 12 — Merge prep handoff

- [ ] **T044** Final analyzer + test gate: `flutter analyze --no-pub` clean; `flutter test` all passing. Commit any final cleanup.
- [ ] **T045** Branch ready for the v2.5.0 merge sequence. Document for the operator:
  - Merge order: `019-workflow-integrity-hardening` → `018-pre-tag-hardening` → `017-ux-restructuring` → `main`
  - Tag: `v2.5.0-pre`
  - GitHub Actions builds Windows .exe
  - Operator runs the 13-step T067 acceptance from RELEASE_NOTES (now augmented with the 5 019 must-fix verification steps).
- [ ] **T046** [user-blocking, NOT autonomous] Operator runs the T067 acceptance + the 019-specific tests on the Windows workstation. After all pass, promote `v2.5.0-pre` → `v2.5.0` (re-tag, re-push).

## Dependencies

- **Phase 1** blocks Phase 2 (need column before capture/check) and Phase 4 indirectly (test infrastructure).
- **Phase 2** can proceed in parallel with Phases 3 + 4 + 5 + 7 once Phase 1 lands. They touch different files.
- **Phase 6** (HandBrake staging) is independent of all earlier phases — touches `compression_service.dart` + `startup_sweep.dart`. Can run in parallel.
- **Phase 8** (Codex round 27a) blocks Phase 9 — design errors caught before implementation.
- **Phase 10** (Codex round 27b) blocks Phase 11+12 — code errors caught before merge.

## Risk gates

- **T038** (post-implementation analyze + test gate): all-green before round 27b.
- **T040** (round 27b): zero open P1s before merge.
- **T046** (operator acceptance): Windows tests pass before promote.

Failing any gate means iterate, not skip.

## Test-file dependency map

| User Story | Test file | Implementation tasks |
|---|---|---|
| US1 | migration_v8_to_v9_test.dart | T001-T004 |
| US1 | drive_identity_check_test.dart | T005-T010 |
| US2 | erase_rescan_test.dart | T011-T014 |
| US3 | source_symlink_guard_test.dart | T015-T018 |
| US4 | force_delete_deferred_clear_test.dart | T019-T022 |
| US5 | handbrake_staging_test.dart | T023-T026 |
| US6 | slack_settings_failure_test.dart | T027-T028 |
| US7 | long_path_hash_test.dart | T029-T031 |
| US8 | runpowershell_argv_guard_test.dart | T032-T034 |

9 new test files; ~30 new test cases (depending on subcase fan-out). Target post-019 count: ~155 (126 baseline + ~29).
