# Implementation Plan: Workflow-Integrity Hardening (v2.5.0)

**Branch**: `019-workflow-integrity-hardening` | **Date**: 2026-05-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/019-workflow-integrity-hardening/spec.md`
**Findings doc**: [v2.5.0-audit-findings.md](../v2.5.0-audit-findings.md)

## Summary

Close the 5 convergent audit findings (3 P1 + 2 P2) plus 3 cheap-to-bundle single-auditor defenses surfaced by the holistic threat-model audit (Opus + Codex `gpt-5.5 effort=high` parallel run on the v2.5.0 candidate). All ship as one bundle so v2.5.0 tags only after this lands AND Windows operator acceptance passes. No further executor changes after this feature.

The 5 convergent findings represent **workflow-level invariants** that span create→enumerate→transfer→verify→erase — no single prior feature owned the chain, so 25 rounds of incremental Codex review (each scoped to a feature delta) missed them. This feature owns the chain.

Approach groups by failure class:

1. **Source-identity binding across the chain** (FR-001 — FR-004, US1): `Job.sourceDriveSerial` captured at create-time via WMI; re-checked at transfer-resume AND erase-eligibility. Schema v8 → v9 migration. Fail-closed on null result; legacy v8 jobs (null serial) get a one-time per-job banner and bypass the check (preserves in-flight work).

2. **Erase-time card-content reconciliation** (FR-005 — FR-007, US2): `eraseEligibilityReason` re-enumerates source video files (same allowlist as job-creation enumeration) and refuses if any present file isn't in the planned set. Files in the planned set but missing from the card are NOT a refusal (operator-driven deletion is permitted; their destinations are already verified per existing logic).

3. **Source-side reparse-point hardening** (FR-008 — FR-009, US3): mirror the 017B dest-side `followLinks: false` work to the SOURCE side. Two enumeration sites: `drive_service.dart::listVideoFiles` and `job_queue_service.dart::createBatchTransferJobs`. Per-entry type check via `FileSystemEntity.type(path, followLinks: false)`; skip + warn on `link`.

4. **Force-delete state-machine fix** (FR-010 — FR-012, US4): defer `clearForceDestDeleteApproved` from "top of per-file iteration" to "after `markFileCompleted(verified: false)` lands". Cancel-mid-operation preserves the operator's intent. Accept-mismatch / Accept-unverified paths must also clear the column as part of their existing transaction (otherwise stale approvals would mis-fire on later re-runs).

5. **HandBrake staging + sweep extension** (FR-013 — FR-017, US5): adopt the robocopy staging-dir convention for compression. Sibling-directory pattern per Q4: `<dirname>/.tmp_handbrake_<tag>/<basename>`, with `.live` marker. Atomic rename on success; staging deletion on failure. Cold-start sweep extends to walk compression-output directories and remove orphaned `.tmp_handbrake_*` whose marker is absent / foreign-host (using the established 018 round-25 host-as-load-bearing logic).

6. **Bundled cheap defenses** (FR-018 — FR-020, US6/US7/US8): three single-auditor LIKELY findings folded in:
   - Slack `_send` moves `_getWebhookUrl()` inside the existing try block (FR-018, US6).
   - SHA-256 hash call prepends `\\?\` to paths > 240 chars (FR-019, US7).
   - `drive_service::_runPowerShell` enforces length-3 argv invariant (FR-020, US8) + CI grep guard.

Schema bump: v8 → v9 (one new column on `jobs`). Single migration step in the existing Drift `onUpgrade` callback. No backfill `UPDATE` (legacy rows stay null and are detected via the null-serial banner path).

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (desktop, Windows target)
**Primary Dependencies**: Drift (SQLite ORM), `sqflite_common_ffi`, `path`, `dio` (Slack), `window_manager`, `tray_manager`. **No new dependencies.**
**Storage**: SQLite via Drift, schema **v8 → v9** (one new column: `Jobs.sourceDriveSerial TEXT NULL`). Existing v8 invariants from 017A/017B/018 preserved unchanged.
**Testing**: `flutter test` (unit), `flutter analyze` (lint), CI grep guards `! grep -rn '\$args\[' lib/` (preserved from 017A) AND new `! grep -rn "Process\\.run\\('powershell'" lib/services/` per FR-020. 126 existing tests (post-018) must keep passing; target ~24 new tests across US1-US8.
**Target Platform**: Windows 11 with PowerShell 5.1; macOS for development only.
**Project Type**: Single Flutter desktop app (compiles to one Windows `.exe`).
**Performance Goals**:
- Drive-identity re-check at transfer-resume MUST complete < 500 ms (NFR-001).
- Erase-eligibility rescan SHOULD complete < 2 s for a typical batch (~30 files) (NFR-002).
- Source-side symlink guard MUST NOT regress no-symlinks-case enumeration perf (NFR-003).
- HandBrake staging adds at most one rename per successful compression (NFR-004) — negligible vs encode time.
**Constraints**: Constitution Principles I, III, V (strengthened); IV (vigilance — minimal complexity matters). All v2.4.0 + v8 (017A/017B/018) load-bearing conventions documented in CLAUDE.md preserved unchanged. No new runtimes. Schema bump is one column add, no data backfill. No public API changes.
**Scale/Scope**: Single Windows workstation; existing low-volume database (tens to low hundreds of jobs); 5 convergent + 3 bundled findings; ~5 file edits in `lib/`, 1 new file (`compression_staging.dart` helper or extension to existing services), 8 new test files.

## Constitution Check

- **Principle I (Human-in-the-Loop)**: Strengthened by US1 + US2. The typed-confirmation gate alone was insufficient when the system has lied about WHAT is about to be erased (F-1: wrong card identity) or whether everything has been preserved (F-2: post-enumeration additions). Both failures circumvented operator intent without a deliberate "yes erase THIS card with THIS state" action. Drive-identity re-check + card-rescan close the gaps.
- **Principle III (Resilient Pipeline)**: Strengthened by US4 + US5. F-4 closed a state-machine race that abandoned operator intent on cancel-mid-operation; F-5 brings compression up to the same staging-dir resilience as transfer (currently asymmetric).
- **Principle IV (Minimal Complexity)**: Care. The drive-identity check adds one column + one WMI call per resume — acceptable. The card-rescan adds one `Directory.list` per erase eligibility — acceptable. HandBrake staging is the largest scope addition; the staging+sweep pattern reuses 018 infrastructure rather than inventing parallel mechanisms.
- **Principle V (Observable Progress)**: Maintained by FR-018. Slack failures must not pollute pipeline error reporting.
- **Principle VI (Update Transparency)**: No change.

## Architecture

### Schema v8 → v9

Single migration step in `lib/database/database.dart::onUpgrade`:

```dart
if (from < 9) {
  await m.addColumn(jobs, jobs.sourceDriveSerial);
  // No backfill UPDATE — legacy rows stay null and are detected via the
  // null-serial banner path at runtime. See FR-002 + the per-job banner
  // wired into the resume-time check in JobQueueService.
}
```

Bump `schemaVersion` from 8 to 9. The Phase 7 invariants from v8 are preserved (the `beforeOpen` cleanup + idx_job_files_job_id index from 018 stay).

### Source-identity capture + check

**Capture at create-time** (in `JobQueueService.createBatchTransferJobs` and the single-job creation path in `create_job_screen.dart`):

```dart
final serial = await _driveService.getDriveIdentity(sourcePath); // existing WMI helper
final job = JobsCompanion.insert(
  ...,
  sourceDriveSerial: Value(serial),
);
```

**Re-check at transfer-resume** (in `JobQueueService::_processJob`, immediately after the `sourceDir.exists()` check):

```dart
if (job.sourceDriveSerial != null) {
  final currentSerial = await _driveService.getDriveIdentity(job.sourcePath);
  if (currentSerial == null) {
    // Fail-closed: refuse, log, surface to UI
    await _safeWrite(() => _jobDao.markJobPaused(job.id, reason: 'Could not verify card identity'));
    _surfaceCardIdentityError(job, expected: job.sourceDriveSerial!, current: null);
    return;
  }
  if (currentSerial != job.sourceDriveSerial) {
    await _safeWrite(() => _jobDao.markJobPaused(job.id, reason: 'Card identity mismatch'));
    _surfaceCardIdentityMismatch(job, expected: job.sourceDriveSerial!, current: currentSerial);
    return;
  }
} else {
  // Legacy v8 job (pre-019): one-time banner per job
  _surfaceLegacyJobBanner(job);
  // Proceed without serial check (preserves in-flight work)
}
```

**Re-check at erase-eligibility** (in `lib/ui/widgets/erase_drive_action.dart`, in `_evaluateEraseEligibility` or equivalent):

```dart
if (job.sourceDriveSerial != null) {
  final currentSerial = await driveService.getDriveIdentity(job.sourcePath);
  if (currentSerial == null) return EraseEligibility.refused('Could not verify card identity');
  if (currentSerial != job.sourceDriveSerial) {
    return EraseEligibility.refused('Card identity mismatch — original: ${job.sourceDriveSerial}, current: $currentSerial');
  }
}
// Else: legacy job — proceed without check (banner has already been shown)
```

### Erase-time card-content reconciliation

In `eraseEligibilityReason` (or wherever the eligibility decision lands), AFTER the existing checks, AFTER the new identity re-check:

```dart
final currentFiles = await driveService.listVideoFiles(job.sourcePath);
final plannedPaths = (await jobFileDao.getFilesForJob(job.id))
    .map((f) => p.canonicalize(f.sourceFilePath).toLowerCase())
    .toSet();
final unplanned = currentFiles
    .where((f) => !plannedPaths.contains(p.canonicalize(f.path).toLowerCase()))
    .toList();
if (unplanned.isNotEmpty) {
  return EraseEligibility.refused(
    '${unplanned.length} file(s) added to card after job created '
    '(${unplanned.take(5).map((f) => p.basename(f.path)).join(", ")}'
    '${unplanned.length > 5 ? "..." : ""}) — re-create job or remove '
    'files before erase.',
  );
}
```

Path comparison normalizes via `p.canonicalize` + `toLowerCase()` (NTFS case-insensitive). The same allowlist as enumeration is used inside `listVideoFiles` (per Q2/A).

### Source-side symlink guard

In `lib/services/drive_service.dart::listVideoFiles` and `lib/services/job_queue_service.dart::createBatchTransferJobs`'s enumeration:

```dart
await for (final entity in dir.list(recursive: true, followLinks: false)) {
  final type = await FileSystemEntity.type(entity.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    _logService?.warning(
      'Skipped symlink at ${entity.path}',
      phase: LogPhase.preflight,
    );
    continue;
  }
  if (entity is File && _isVideoFile(entity.path)) {
    yield entity;
  }
}
```

`Directory.list(followLinks: false)` is the load-bearing flag; the per-entry type check is defense-in-depth (some Dart versions don't fully respect the flag for directory recursion).

### Force-delete state-machine fix

Move the `clearForceDestDeleteApproved` call from line ~705-709 (top of per-file iteration) to immediately after `markFileCompleted(verified: false)` (line ~843 SHA-256 path; the new T024-restructured size-mode equivalent):

```dart
// SHA-256 path
await _safeWrite(() => _jobFileDao.markFileCompleted(file.id, verified: false));
// 019 FR-010: clear forceDestDeleteApproved here, NOT at top of iteration.
// Cancel/crash mid-robocopy would otherwise lose operator intent.
if (forceDestDelete) {
  await _safeWrite(() => _jobFileDao.clearForceDestDeleteApproved(file.id));
}
```

The local variable `forceDestDelete` (read at top of loop) still drives the delete logic; only the persisted-column clear moves later.

Accept-mismatch / Accept-unverified paths in `JobFileDao` add `forceDestDeleteApproved: const Value(false)` to their existing transactional write (FR-012).

### HandBrake staging

In `lib/services/compression_service.dart::compressFile`, switch to the staging pattern (mirroring `transfer_service.dart::transferFile`'s rename branch):

```dart
final outputDir = p.dirname(outputFile);
final outputBasename = p.basename(outputFile);
final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
final stagingDir = Directory(p.join(outputDir, '.tmp_handbrake_$tag'));
await stagingDir.create(recursive: true);

// .live marker — same convention as 018 (host as load-bearing field)
final markerFile = File(p.join(stagingDir.path, '.live'));
try {
  await markerFile.writeAsString(
    'host=${Platform.localHostname}\n'
    'pid=$pid\n'
    'exe=${Platform.resolvedExecutable}\n',
    flush: true,
  );
} catch (markerError, markerStack) {
  try {
    await stagingDir.delete(recursive: true);
  } catch (_) { /* logged */ }
  Error.throwWithStackTrace(markerError, markerStack);
}

final stagingOutput = p.join(stagingDir.path, outputBasename);
final exitCode = await _processRunner.run(
  executable: 'HandBrakeCLI',
  arguments: ['-i', inputFile, '-o', stagingOutput, '--preset', presetName],
);

if (exitCode == 0) {
  await File(stagingOutput).rename(outputFile);
  // Best-effort staging dir cleanup (split per 018 round-11 P3 pattern).
  try { await stagingDir.delete(recursive: true); }
  catch (_) { logService?.warning('Compression staging cleanup left empty dir at ${stagingDir.path}'); }
  return true;
}

// Failure path: clean staging file, leave dir for sweep
try { await stagingDir.delete(recursive: true); } catch (_) {}
return false;
```

The cold-start sweep extends to also walk compression-output directories. Currently the sweep collects "destination roots from non-terminal jobs UNION recent terminal jobs". For 019, also collect `compressionOutputPath` from those jobs (where non-null). The sweep matcher accepts both `.tmp_robocopy_*` and `.tmp_handbrake_*` prefixes (single matcher addition).

### Bundled defenses

**FR-018 (Slack)**: Move `_getWebhookUrl()` from before the try block in `_send` (line 28) to inside it. Catch propagates as Slack-failure log, not as upstream pipeline error.

**FR-019 (long-path SHA-256)**: In `transfer_service.dart::computeFileHash`, before constructing the script:

```dart
final escaped = escapePsLiteral(path);
final pathForPS = path.length > 240 ? r'\\?\' + path : path;
final pathForPSEscaped = escapePsLiteral(pathForPS);
final script = "(Get-FileHash -LiteralPath '$pathForPSEscaped' -Algorithm SHA256).Hash";
```

The `\\?\` prefix is PowerShell-specific; do NOT propagate into robocopy/HandBrake argv (they have their own long-path handling on Windows 10+).

**FR-020 (length-3 argv guard)**: In `drive_service.dart::_runPowerShell`:

```dart
Future<ProcessResult> _runPowerShell(List<String> args, {required String tag}) async {
  assert(
    args.length == 2 && args[0] == '-Command',
    'PS argv invariant violated in $tag: args after -NoProfile must be '
    "exactly ['-Command', script]. Got: $args. See 017A length-3 argv invariant.",
  );
  // ... existing call to Process.run('powershell', ['-NoProfile', ...args], ...)
}
```

Plus a CI grep guard (added to the existing `! grep -rn '\$args\[' lib/` line, in whatever script runs CI):

```bash
! grep -rn "Process\\.run\\('powershell'" lib/services/ | grep -v 'process_runner.dart'
```

This ensures any new PS call site routes through `runPowerShellInline` (which already has the length-3 assert) or `_runPowerShell` (now also asserting).

## Phases

### Phase 1 — Schema v8 → v9 + capture
Files: `lib/database/database.dart` (schemaVersion bump + migration step), `lib/database/tables.dart` (new column), `lib/database/database.g.dart` (regenerate via build_runner), `lib/services/job_queue_service.dart::createBatchTransferJobs` (capture serial at job creation), `lib/ui/screens/create_job_screen.dart` (single-job creation path captures serial). Test: `migration_v8_to_v9_test.dart` — assert column added, existing rows backfilled to null.

### Phase 2 — Drive-identity re-check (US1, FR-002 — FR-004)
Files: `lib/services/job_queue_service.dart::_processJob` (re-check at transfer-resume), `lib/ui/widgets/erase_drive_action.dart` (re-check at erase-eligibility), new UI surface for the mismatch banner. Test: `drive_identity_check_test.dart` — synthetic mismatch + null-result + happy-path cases.

### Phase 3 — Erase-time card-content reconciliation (US2, FR-005 — FR-007)
Files: `lib/ui/widgets/erase_drive_action.dart` (rescan + diff), `lib/services/drive_service.dart::listVideoFiles` (already exists; verify allowlist consistency). Test: `erase_rescan_test.dart` — added file refused, missing file allowed, identical-set proceeds.

### Phase 4 — Source-side symlink guard (US3, FR-008 — FR-009)
Files: `lib/services/drive_service.dart::listVideoFiles` (followLinks: false + per-entry type check), `lib/services/job_queue_service.dart::createBatchTransferJobs` (same). Test: `source_symlink_guard_test.dart` — symlinked entry skipped + cyclic junction completes in bounded time + no-symlinks happy path.

### Phase 5 — Force-delete deferred clear (US4, FR-010 — FR-012)
Files: `lib/services/job_queue_service.dart::_processTransfer` (move clear from top-of-loop to post-markFileCompleted), `lib/database/daos/job_file_dao.dart::acceptMismatch` + `acceptUnverified` (add `forceDestDeleteApproved: Value(false)` to their transactional writes). Test: `force_delete_deferred_clear_test.dart` — cancel-mid-operation preserves column; success path clears column; accept paths clear column.

### Phase 6 — HandBrake staging + sweep extension (US5, FR-013 — FR-017)
Files: `lib/services/compression_service.dart::compressFile` (staging dir + .live marker + atomic rename), `lib/services/startup_sweep.dart` (extend roots collection to compressionOutputPath; extend matcher to `.tmp_handbrake_*`). Test: `handbrake_staging_test.dart` — cancel-mid-encode leaves no final file; sweep removes orphaned staging.

### Phase 7 — Bundled defenses (US6/US7/US8, FR-018 — FR-020)
Files: `lib/services/slack_service.dart::_send` (FR-018), `lib/services/transfer_service.dart::computeFileHash` (FR-019), `lib/services/drive_service.dart::_runPowerShell` (FR-020) + CI script update. Test: `slack_settings_failure_test.dart`, `long_path_hash_test.dart`, `runpowershell_argv_guard_test.dart`.

### Phase 8 — Codex round 27a (post-tasks, pre-implementation)
Per Q5/B clarification: fire `codex exec --model gpt-5.5 --effort high` adversarial review on plan.md + tasks.md BEFORE any implementation begins. Catches design-decision errors (e.g., wrong allowlist, wrong placement of clear, wrong staging shape). Fold P1 findings back into plan/tasks; commit corrections; re-fire if material changes.

### Phase 9 — Implementation
Implement Phases 1-7 per the post-round-27a tasks. Per the 018 checkpoint discipline, implement+commit+verify per phase, not all at once.

### Phase 10 — Codex round 27b (post-implementation)
Fire round 27b on the merged 019 implementation. Fold P1+P2 findings back; commit fixes; re-run analyzer + tests. P3 findings: defer to v2.5.1 (logged in CLAUDE.md → "Open bugs").

### Phase 11 — Docs + merge prep
Update CLAUDE.md "v9 (019) Load-Bearing Conventions" section with new invariants:
- `Job.sourceDriveSerial` captured at create, re-checked at transfer-resume + erase-eligibility, fail-closed on null.
- Erase-eligibility rescans card content; refuses on unplanned files.
- Source-side enumeration uses `followLinks: false` + per-entry type check.
- `clearForceDestDeleteApproved` happens AFTER `markFileCompleted(verified: false)`, NOT at top of iteration.
- HandBrake compression uses staging-dir convention symmetric with transfer pipeline.
- Slack `_getWebhookUrl()` runs INSIDE `_send`'s try block.
- SHA-256 hashing prepends `\\?\` for paths > 240 chars.
- `drive_service::_runPowerShell` enforces length-3 argv via assertion.

Update RELEASE_NOTES_v2.5.0.md with a "Workflow-integrity hardening (019)" subsection summarizing the 5 convergent + 3 bundled findings + Codex round-27a/b verdicts.

### Phase 12 — Merge prep handoff
Branch ready for the v2.5.0 merge sequence (T034 from 018: `019` → `018` → `017-ux-restructuring` → `main`). T035 (Windows operator acceptance) follows.

## Critical files to modify

### Database
- `lib/database/database.dart` — schemaVersion bump 8→9, new migration step
- `lib/database/tables.dart` — `Jobs.sourceDriveSerial TEXT NULL`
- `lib/database/database.g.dart` — regenerated via `dart run build_runner build`

### Services
- `lib/services/drive_service.dart` — listVideoFiles followLinks: false + type check (Phase 4); `_runPowerShell` argv assert (Phase 7)
- `lib/services/job_queue_service.dart` — capture serial at create (Phase 1); re-check at resume (Phase 2); deferred clearForceDestDeleteApproved (Phase 5); enumeration symlink guard (Phase 4)
- `lib/services/transfer_service.dart` — `\\?\` prefix in computeFileHash (Phase 7)
- `lib/services/compression_service.dart` — staging dir + .live marker + atomic rename (Phase 6)
- `lib/services/startup_sweep.dart` — extend roots collection + matcher for `.tmp_handbrake_*` (Phase 6)
- `lib/services/slack_service.dart` — move _getWebhookUrl into try (Phase 7)

### DAOs
- `lib/database/daos/job_file_dao.dart` — acceptMismatch + acceptUnverified clear forceDestDeleteApproved (Phase 5)
- `lib/database/daos/job_dao.dart` — markJobPaused with reason support (Phase 2 — likely already exists)

### UI
- `lib/ui/widgets/erase_drive_action.dart` — identity re-check + content rescan refusal paths (Phases 2 + 3)
- `lib/ui/screens/create_job_screen.dart` — single-job creation captures serial (Phase 1)
- A new banner widget (or reuse existing) for the legacy-job + identity-mismatch + identity-null cases

### Tests (8 new)
- `test/unit/migration_v8_to_v9_test.dart` (Phase 1)
- `test/unit/drive_identity_check_test.dart` (Phase 2)
- `test/unit/erase_rescan_test.dart` (Phase 3)
- `test/unit/source_symlink_guard_test.dart` (Phase 4)
- `test/unit/force_delete_deferred_clear_test.dart` (Phase 5)
- `test/unit/handbrake_staging_test.dart` (Phase 6)
- `test/unit/slack_settings_failure_test.dart` (Phase 7)
- `test/unit/long_path_hash_test.dart` (Phase 7)
- `test/unit/runpowershell_argv_guard_test.dart` (Phase 7)

(That's 9, not 8 — `runpowershell_argv_guard_test.dart` is light; could fold into another test file if scope creep concerns surface.)

### Docs
- `CLAUDE.md` — new "v9 (019) Load-Bearing Conventions" section
- `RELEASE_NOTES_v2.5.0.md` — "Workflow-integrity hardening (019)" subsection

### CI
- Whichever script runs CI grep guards — add the new `! grep -rn "Process\\.run\\('powershell'" lib/services/` line

## Risks

- **Schema bump risk**: This is the second schema bump in v2.5.0 (017A bumped 7→8). Operator's MVP-context allows .db deletion as recovery; production-deployment concerns are out of scope per spec. Risk: low.
- **WMI re-call latency**: `getDriveIdentity` adds a PowerShell subprocess call per transfer-resume + per erase-eligibility check. NFR-001 budgets 500 ms; cache the result for the duration of an executor pass. If the WMI call is consistently slow on the operator's machine, surface a "verifying card identity..." indicator.
- **Erase rescan latency on slow cards**: SD card I/O on the Kingston hub is fast for typical batch sizes; very large batches (300+ files) could hit NFR-002's 2 s budget. Mitigation: brief "Rescanning card..." indicator + the rescan-result is the LAST check before the typed-confirmation dialog, so latency feels intentional rather than hung.
- **Source-side symlink guard false positives**: Camera workflows sometimes use SD card "shortcuts" or `lnk` files for navigation; these aren't filesystem-level symlinks but Windows shortcut files. The `FileSystemEntity.type` check distinguishes — only TRUE symlinks/junctions get skipped. `.lnk` files would be treated as regular files (and excluded by the video-extension allowlist anyway).
- **Force-delete deferred-clear regression risk**: This is a state-machine reordering. Test coverage MUST exercise the cancel-during-each-phase windows (between dest-delete and robocopy-start; between robocopy-start and robocopy-completion; between robocopy-completion and markFileCompleted). Codex round 27a will scrutinize this specifically.
- **HandBrake staging + atomic rename across volumes**: `File.rename` on Windows is NOT atomic across volumes. The staging dir lives in the same directory as the final output, so source and destination of the rename are on the same volume. Verify with a test that uses a temp path on a different mount point — should fail with a clear error rather than silently fall back to copy+delete.
- **Sweep extension complexity**: 018 round-25 simplified the sweep to host-only check. Extending to compression staging follows the same pattern — single matcher addition. But: the marker for compression staging lives at `<dir>/.tmp_handbrake_<tag>/.live`; the sweep code currently looks for `<root>/.tmp_robocopy_*/`. The matcher needs to handle both prefixes. Codex round 27a will verify this doesn't introduce a new false-positive deletion path (e.g., an operator-created `.tmp_handbrake_archive` folder).

## Out of scope

Per spec.md:
- F-D1 (size-mode TOCTOU on renamed-staged transfer with same-size pre-existing target)
- F-D3 (sweep prefix collision with operator-created dirs)
- F-D4 (cross-machine NAS write race for live transfers)
- F-D5 (DST/clock-jump mtime cutoff inversion)
- F-D8 (eraseDrive Remove-Item without -LiteralPath)

These are deferred to v2.5.1, logged in CLAUDE.md → "Open bugs deferred to v2.5.1" once 019 ships.
