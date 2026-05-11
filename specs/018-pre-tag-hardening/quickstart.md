# Quickstart: Pre-Tag Hardening (v2.5.0)

**Phase 1 output for plan.md.** How a developer (or future maintainer) gets this feature running locally + manually verifies each fix.

---

## Prerequisites

- macOS or Windows 11 with Flutter 3.x SDK installed
- The 018-pre-tag-hardening branch checked out
- `~/Music/copiatorul3000/` is the working directory
- (For full E2E acceptance) Windows 11 workstation with PowerShell 5.1, an SD card mounted, HandBrakeCLI on PATH, robocopy (built-in)

## Build + run locally

```bash
cd ~/Music/copiatorul3000
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # only if Drift schema changed (it didn't in this feature)
flutter analyze --no-pub                                   # MUST be clean
flutter test                                               # MUST be 88 passing (78 existing + 10 new)
flutter run -d macos                                       # for UI iteration on macOS
flutter build windows --release                            # for Windows .exe (requires Windows host or CI)
```

---

## Manual verification — one recipe per FR

### FR-001 / FR-002 — Atomic per-file retry

**Setup**: open a Drift database in test mode with one job containing one file in `status=completed, verifyStatus=mismatch`.

**Synthetic interruption**: in a debug build, set a breakpoint inside `applyPerFileRetry` AFTER the file-row reset but BEFORE the parent-job requeue. Trigger the operator's Retry action. When the breakpoint hits, force-quit the process (do not let the breakpoint resume).

**Expected**: relaunch the app. The file row is observably either:
- Back to `status=completed, verifyStatus=mismatch` (transaction rolled back atomically — the expected behavior with Drift's transaction primitive), OR
- `status=pending, verifyStatus=pending` AND parent `Job.status=queued` (transaction completed before kill).

**Failure mode being verified absent**: file at `status=pending` while parent at `status=completed` (the "ghost pending" state). MUST NOT be reachable.

### FR-003 / FR-004 / FR-005 / FR-006 — Typed-confirmation gate

**Setup**: any job in history with at least one mismatched and one unverified file row.

**Steps**:
1. Open the job's context menu in JobCardDone.
2. Click "Accept mismatched". Verify the dialog presents a text input field requiring the phrase `accept mismatch`. Confirm button stays disabled until the input matches exactly.
3. Type `Accept Mismatch` (capitalized). Verify an inline hint appears: "Case-sensitive match required."
4. Type `accept mismatch`. Verify the confirm button enables. Click cancel — no state change should occur.
5. Repeat for "Accept unverified" with phrase `accept unverified`.
6. For active-card Skip: trigger a SHA-256-mode transfer with a synthetic mismatch, observe the active-card mismatch banner, click Skip. Same dialog pattern with phrase `skip mismatch`.

### FR-007 — Chain-compression dedup TOCTOU

**Setup**: any transferAndCompress job with both mismatched and unverified files.

**Steps**:
1. Open JobCardDone context menu.
2. Quickly click "Accept mismatched" → confirm typed gate → confirm.
3. Before the snackbar/UI updates, open the menu again, click "Accept unverified" → confirm typed gate → confirm.
4. Inspect the database (`SELECT id, type, parent_job_id FROM jobs WHERE parent_job_id = <parent_id>`).

**Expected**: exactly one row. Not two.

### FR-008 — Start/stop processing race

**Setup**: any queued job.

**Steps**:
1. Click Start (queue begins processing).
2. While the first file is mid-transfer, close the application window (triggers `_gracefulShutdown` → `stopProcessing`).
3. Within ~1 second of clicking close, observe whether any code path that would have triggered `startProcessing` (e.g., a debounced retry, an Accept handler from a hover-active context menu) does so.
4. Inspect logs for "JobQueueService: starting processing" lines.

**Expected**: at most one "starting processing" log line per queue session. The second `startProcessing` either awaits the in-flight stop or is rejected.

### FR-009 / FR-010 — FK pragma + retroactive cleanup

**Setup**: a v8 database with a deliberately-seeded dangling parent reference. Quick script:

```dart
// in a test or one-off:
await db.customStatement('INSERT INTO jobs (id, type, source_path, destination_path, status, parent_job_id, ...) VALUES (999, ...)');
await db.customStatement('DELETE FROM jobs WHERE id = (SELECT parent_job_id FROM jobs WHERE id = 999)');
// jobs.id=999 now has a dangling parent_job_id
```

**Steps**:
1. Close the app (releases the Drift connection).
2. Reopen the app.
3. Inspect the database: `SELECT id, parent_job_id FROM jobs WHERE id = 999;` — `parent_job_id` should be NULL.
4. Inspect pragma state: `PRAGMA foreign_keys;` should return `1`.
5. Try to insert a new dangling reference: `INSERT INTO jobs (..., parent_job_id, ...) VALUES (..., 99999, ...);` — should fail with FK violation.

### FR-011 — Slack truth on size-mode transfer

**Setup**: any size-mode (default) transfer job. Configure the Slack webhook to a test channel.

**Steps**:
1. Run the transfer to completion (all files passing size check).
2. Inspect the Slack notification.

**Expected**: the verified-count line and the verdict line agree. Specifically, NO message of the form "Verified: 0 · ... Verification: Size — Passed". The new wording should match the chained-compression Slack message's pattern (e.g., "$N size-verified · Passed").

### FR-012 — Migration errorMessage cleanup

**Setup**: a v7 database (or a v8 database where Phase 7 lifted at least one job). To prep:

```sql
-- Pre-v8:
INSERT INTO jobs (id, status, error_message, ...) VALUES (1, 'failed', '5/10 files transferred, 5 failed copy', ...);
INSERT INTO job_files (job_id, status, error_message) VALUES (1, 'failed', 'SHA-256 hash mismatch'), ...;
-- (5 rows of hash-mismatch failures, no copy errors)
```

**Steps**:
1. Run the v8 migration (open the app, let migration complete).
2. Inspect: `SELECT id, status, error_message FROM jobs WHERE id = 1;`

**Expected**: `status='completed' AND error_message IS NULL` (or a migration-provenance string per the implementation choice). NOT `status='completed' AND error_message='5/10 files transferred, 5 failed copy'`.

### FR-013 — Counter consistency

**Setup**: any job mid-execution in SHA-256 mode with a deliberately-failing hash subprocess (rename `powershell.exe` for the duration, or mock at the test level).

**Steps**:
1. Begin processing.
2. While `_processTransfer` is mid-recovery-branch (line 459 — first file's hash is failing), force-quit the process between `markFileUnverified` and `incrementUnverified`. (Easiest in a test environment with controlled mocks; in a manual setting, this is hard to reproduce exactly — rely on the unit test for verification.)
3. Relaunch the app.
4. Inspect: `SELECT job_id, COUNT(*) FROM job_files WHERE verify_status = 'unverified' GROUP BY job_id;` vs `SELECT id, unverified_files FROM jobs;`.

**Expected**: counts agree. If they disagree, the self-healing recompute on the next operator interaction (e.g., opening the JobCardDone) MUST correct the drift before any operator action sees the wrong number.

### FR-014 — Size-mode progress crediting parity

**Setup**: any size-mode transfer of a file large enough that the size-verify call takes more than ~50 ms.

**Steps**:
1. Begin processing.
2. Watch the on-screen progress bar AND counters during the transfer.
3. Note the relative timing of the bar/counter advancement vs the file-completion log line.

**Expected**: bar and counter advance at the moment the underlying robocopy completes, NOT after the size-verify check returns. This matches SHA-256-mode behavior (where `markFileCompleted(verified=false)` runs immediately post-robocopy and credits bytes).

### FR-015 — Staging-dir orphan sweep

**Setup**: a destination drive with one of the operator's typical paths (e.g., `E:\Studio Termene\...`).

**Steps**:
1. Manually create an empty directory matching the pattern: `E:\Studio Termene\...\.tmp_robocopy_FAKEPID_FAKETAG\` (no `.live` marker file).
2. Open the app.
3. Inspect the directory after startup completes.

**Expected**: the orphan directory is removed. Total startup latency added by the sweep: < 500 ms in the typical 1–3-roots case.

**Negative test**: create a staging dir with a `.live` marker containing the current process's PID + executable path. Open the app. The dir MUST NOT be removed (it would represent a "live" instance per the marker semantics).

---

## Running the new tests

The 10 new tests are in `test/unit/`. Run them all:

```bash
flutter test test/unit/retry_atomicity_test.dart \
            test/unit/typed_gate_coverage_test.dart \
            test/unit/chain_dedup_test.dart \
            test/unit/start_stop_race_test.dart \
            test/unit/fk_pragma_and_cleanup_test.dart \
            test/unit/slack_size_mode_truth_test.dart \
            test/unit/migration_errormessage_test.dart \
            test/unit/counter_consistency_test.dart \
            test/unit/size_mode_progress_order_test.dart \
            test/unit/staging_dir_sweep_test.dart
```

Or just the full suite (existing 78 + new 10):

```bash
flutter test
```

Expected: 88 passing.

---

## Acceptance — Codex round 22

After all tasks complete, all tests pass, and `flutter analyze --no-pub` is clean:

```bash
codex review --base main -c model="gpt-5.5" -c model_reasoning_effort="high"
```

Expected: NO new P1 or P2 findings. P3 findings are acceptable IF they are net-new (not re-openings of any of the 10 findings closed by this feature). If round 22 surfaces a new P1/P2: fix-and-rerun before tagging.

---

## Acceptance — Windows operator (T067)

Per `RELEASE_NOTES_v2.5.0.md` T067 checklist. Operator runs each scenario on the workstation. After all 13 steps pass:

```bash
git tag v2.5.0
git push origin v2.5.0
# GitHub Actions builds the Windows .exe → publishes the GitHub Release
# Operator gets the in-app update prompt on next launch
```

---

## Troubleshooting

**`flutter test` shows "Recovery test fails" after FR-013 changes**: the existing recovery test may need updating to match the new atomic write pattern. Read `test/unit/recovery_test.dart` and adapt. Don't `_safeWrite`-bypass.

**FR-009 cleanup statement runs slow**: check `EXPLAIN QUERY PLAN` for the `UPDATE jobs SET parent_job_id = NULL WHERE parent_job_id IS NOT NULL AND parent_job_id NOT IN (SELECT id FROM jobs)`. SQLite should use the implicit ROWID index. If it doesn't, you may need an explicit index on `parent_job_id` (defer to v2.6 if observed in production).

**Typed-gate dialog renders but the typed input doesn't enable the button**: case-sensitivity check is exact-match. Verify the phrase passed to `showDestructive(typedConfirmation: ...)` exactly matches what's documented in this quickstart.

**`PRAGMA foreign_keys` returns 0 after FR-009 lands**: the pragma is per-connection. If a code path opens a fresh connection that bypasses the `beforeOpen` callback, fix THAT path; don't disable the FR-009 enforcement.
