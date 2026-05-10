# Feature Specification: Workflow-Integrity Hardening for v2.5.0

**Feature Branch**: `019-workflow-integrity-hardening`
**Created**: 2026-05-10
**Status**: Draft
**Input**: User description: "Holistic audit of the v2.5.0 candidate (run on `018-pre-tag-hardening` HEAD) by two independent auditors (Opus subagent + Codex `gpt-5.5 effort=high` subagent) surfaced 5 convergent findings (3 P1 + 2 P2) plus 8 divergent findings (3 P1/P2 + 5 P2/P3). The convergent set are workflow-level invariants that span create→enumerate→transfer→verify→erase — no single prior feature owned the chain, so 25 rounds of incremental Codex review (scoped to feature deltas) missed them. This feature closes the must-fix subset before tagging v2.5.0."

## Background

After 25 rounds of `gpt-5.5 effort=high` adversarial review on the 017A + 017B + 018 work that constitutes v2.5.0, two parallel holistic-framing auditors (Opus subagent with extended thinking + Codex round-26-equivalent), each given the same threat-model prompt with no cross-pollination, surfaced 13 findings. **5 are convergent** (both auditors flagged): 3 P1 data-loss vectors and 2 P2 correctness regressions. The other 8 are single-auditor; bundled selectively per the operator's "bundle deferred fixes before asking for QA" preference.

The canonical input is `specs/v2.5.0-audit-findings.md` (committed at the start of this branch). It enumerates each finding with file/line refs, failure mode, trigger, why prior rounds missed it, and convergence/severity classification.

This feature is the **last gate before tagging v2.5.0**. After it merges and Windows acceptance passes, the v2.5.0 tag goes out.

## Clarifications

### Session 2026-05-10

- **Q1 — F-1 schema impact**: Where does `Job.sourceDriveSerial` live? → **A: New schema migration v8 → v9** with explicit `addColumn` + backfill rule. Legacy v8 jobs (created before this column existed) carry `null` and are treated as "could not verify" — the system surfaces a one-time banner per such job ("this job pre-dates drive-identity tracking — re-create to enable card-swap detection") and allows proceed without serial check. Documents the limitation honestly without bricking existing in-flight jobs. Fail-closed behavior applies only to jobs that DO have a `sourceDriveSerial` value.

- **Q2 — F-2 rescan extension allowlist**: Which extensions count as "video files" for the post-enumeration card rescan? → **A: Reuse the existing allowlist from `lib/utils/constants.dart`** (the same one enumeration uses at job-create time). Symmetric criteria avoid surprise mismatches; if the team's allowlist needs tuning, it gets tuned in one place. Camera sidecar files (`.THM`, `.CTG`, etc.) excluded from both sides equally.

- **Q3 — F-4 deferred-clear timing**: Within the success path, when exactly is `clearForceDestDeleteApproved` called? → **A: Immediately after `markFileCompleted(verified: false)`** — the moment robocopy returns success. The operator's force-delete approval was about THIS robocopy invocation, NOT about the verify axis. If verify fails after that, the verify-mismatch banner re-arms a fresh approval. Keeps the state machine conceptually clean.

- **Q4 — F-5 HandBrake staging shape**: Sibling file or sibling directory for the staging path? → **B: Sibling directory** — `<dirname>/.tmp_handbrake_<tag>/<basename>`. Mirrors the robocopy staging-dir convention exactly; `.live` marker lives at `<dirname>/.tmp_handbrake_<tag>/.live`. The 018 startup sweep code path can be extended with a single matcher addition rather than learning a parallel sibling-file convention. Convention symmetry beats marginal disk-write savings.

- **Q5 — Codex round-27 cadence**: One adversarial review at the end, or two across the lifecycle? → **B: Two rounds** — round 27a at plan/tasks completion (catches design-decision errors before code is written), round 27b post-implementation (catches code-level errors). Matches the 018 cadence (rounds 22 + 23 + 24 + 25 across the lifecycle); 018's round-22 plan review caught a P1 (typed-gate phrase enforcement) that would have been embedded in committed code if reviewed only post-implementation. The drive-identity + rescan + force-delete-deferred-clear policy decisions in 019 have similar risk profiles for plan-phase issues.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Drive-letter remap detected and refused (Priority: P1)

A video team operator queues a transfer job from SD card A mounted at E:. They pause the queue (deliberately or via a crash). They unplug Card A and insert a different Card B into the same Kingston SD hub slot, which Windows mounts at the same letter E:. They resume the queue.

**Why this priority**: Convergent P1 finding (F-1). The Kingston SD hub workflow makes letter-remap routine when cards swap. The current code only validates `Directory.exists('E:\\')` at resume — it does NOT check whether E: still points to the SAME physical card. Robocopy reads from B's bytes, verify passes against B's bytes, the celebration card unlocks Erase, and the operator wipes Card B. **Card A's footage was never copied; Card B is now permanently destroyed.** Silent failure with irreversible consequence.

**Independent Test**: Persist `Job.sourceDriveSerial` at job creation (captured via the existing `getDriveIdentity` WMI call). At every transfer-resume AND at every erase-eligibility check, re-call `getDriveIdentity` for the current letter and compare. Mismatch → refuse the operation with a clear "this is not the original card" message. Test: pause a job on Card A, swap to Card B at the same letter, resume → executor refuses; test: complete a job on Card A, swap to Card B at same letter, attempt erase → erase dialog refuses with diagnostic.

**Acceptance Scenarios**:

1. **Given** a paused transfer job with `sourceDriveSerial='SN-AAAA'`, **When** the operator resumes after Card B (`SN-BBBB`) has been mounted at the same drive letter, **Then** the executor refuses to proceed and surfaces a banner: "Source card serial mismatch — original: SN-AAAA, current: SN-BBBB. Re-insert the original card to resume."
2. **Given** a completed transfer job with `sourceDriveSerial='SN-AAAA'` and operator clicks Erase SD, **When** the current card at that letter has serial `SN-BBBB`, **Then** the erase dialog blocks the typed-confirmation field with "Card identity mismatch — refuse to erase."
3. **Given** a completed transfer job with `sourceDriveSerial='SN-AAAA'` and operator clicks Erase SD with the SAME card still inserted, **When** the WMI re-check returns `SN-AAAA`, **Then** the typed-confirmation gate proceeds normally (no behavioral regression on the happy path).

---

### User Story 2 — Erase refuses when SD card has files added after enumeration (Priority: P1)

The operator queues a batch transfer at 14:00. The camera (still in record mode, or via a delayed flush) writes one more clip to the SD card at 14:00:30. The batch runs at 14:01, transferring the originally-enumerated set. The operator clicks Erase SD at 14:05.

**Why this priority**: Convergent P1 finding (F-2). Enumeration is a one-shot snapshot at job creation. The current `eraseEligibilityReason()` only checks every PLANNED file is verified — it does NOT compare current SD contents against the planned set. The new clip is destroyed. **Silent loss of footage that was never copied.** Most likely real-world vector: pre-queue a batch, camera flushes, batch runs, operator erases.

**Independent Test**: At the moment of clicking Erase SD (BEFORE the typed gate appears), re-enumerate the source card's video files. Compare against the planned set in the DB. Any video file (matching the same extension allowlist used at enumeration) on the card that is NOT in the planned set → refuse erase with the count + a sample of unplanned filenames. Test: enumerate a card with 5 .MOV files, manually drop a 6th file onto the card, attempt Erase → refused with "1 unplanned file found: extra.MOV".

**Acceptance Scenarios**:

1. **Given** a completed job whose planned set covered 26 files, **When** the SD card now has 27 video files (one was added post-enumeration), **Then** the Erase SD dialog refuses to open and surfaces "1 file added to card after job created (extra.MOV) — re-create job or remove file before erase."
2. **Given** a completed job whose planned set covered 26 files AND the SD card still has exactly those 26 files, **When** the operator clicks Erase SD, **Then** the typed-confirmation gate appears normally.
3. **Given** a completed job whose planned set covered 26 files AND the SD card now has 25 files (one was deleted by the operator after enumeration), **When** the operator clicks Erase SD, **Then** the dialog proceeds (deletion is operator-driven and preserves no irreplaceable bytes — the missing file's destination was already verified).

---

### User Story 3 — Source-side symlinks/junctions refused at enumeration (Priority: P1)

Source enumeration encounters a symlink or junction. Whether placed accidentally (rare, but possible on cards touched by Linux tooling) or maliciously, the current `Directory.list(recursive: true)` follows the link with no cycle detection.

**Why this priority**: Convergent P1 finding (F-3). 017B added DEST-side `FileSystemEntity.type(..., followLinks: false)` checks; the source-side mirror was never added. Enumeration cycle could pin the UI; junction at source pointing into destination tree could cause copy-back-over-source; enumeration could include files outside the physical SD card.

**Independent Test**: Switch the source-side enumeration in `drive_service.dart` and `job_queue_service.dart` to `followLinks: false`. Per-entry, after listing, check `FileSystemEntity.type(path, followLinks: false)` — if `link`, log a warning and skip. Test: create a junction in a temp source dir pointing at another temp dir; enumerate → the junction is skipped, the warning is logged, the linked-to files are NOT in the planned set.

**Acceptance Scenarios**:

1. **Given** a source directory containing a regular file `IMG_1.MOV` and a symlink/junction `link/` pointing at an unrelated tree, **When** enumeration runs, **Then** the planned set contains only `IMG_1.MOV` and the log records "Skipped symlink at <path>".
2. **Given** a source directory with a junction pointing back into itself, **When** enumeration runs, **Then** the operation completes in bounded time (no cycle) and the cyclic junction is logged + skipped.
3. **Given** a source directory containing only regular files (the happy path), **When** enumeration runs, **Then** behavior is identical to v2.4.0 — no false positives, no skipped legitimate files.

---

### User Story 4 — Force-delete approval survives cancel-mid-operation (Priority: P2)

After a verify mismatch, the operator clicks Retry on the JobCardDone banner. The retry path arms `forceDestDeleteApproved=true` for that file. The executor consumes (clears) the approval at the top of the per-file iteration BEFORE the dest delete and robocopy actually run. The operator cancels the queue mid-robocopy (or the app crashes). The persisted state: the file row is back at `pending, forceDestDeleteApproved=false`. On next launch, the executor re-runs the file with NO operator-approved-overwrite memory.

**Why this priority**: Convergent P2 finding (F-4). The CLAUDE.md spec says "Re-mismatch on next pass requires fresh banner Retry click" — current code does not match this guarantee under cancel-mid-operation. Operator's intent silently laundered. Round-2 P2 #2 fix made the approval persist across app restart between Retry click and consumption; it didn't audit consumption ordering for cancel-during-consumption.

**Independent Test**: Defer the `clearForceDestDeleteApproved` call until AFTER robocopy returns success. On cancel/failure mid-operation, the column stays `true` so the next pass re-honors the operator's intent. Test: arm forceDestDelete, simulate cancel between dest delete and robocopy completion (or robocopy returns non-success), assert column still reads `true`; subsequent retry honors the force-delete without requiring a new banner click.

**Acceptance Scenarios**:

1. **Given** a file at `verifyStatus=mismatch` with `forceDestDeleteApproved=true` (just-armed via banner Retry), **When** the executor runs that file but is cancelled after dest delete and before robocopy returns success, **Then** the persisted `forceDestDeleteApproved` is still `true` AND the file is at `pending`.
2. **Given** the same file in step 1's terminal state, **When** the operator resumes the queue, **Then** the executor honors the persisted approval (skips the size-match short-circuit, deletes any partial that may exist, re-copies fresh).
3. **Given** a file at `forceDestDeleteApproved=true` AND robocopy completes successfully AND verify passes, **When** processing finishes, **Then** the column is now `false` (consumed correctly on success).

---

### User Story 5 — HandBrake partial output detected and recovered (Priority: P2)

A compression job is killed mid-encode (operator cancel, app crash, OOM). The destination has a partial `.mp4` file. The operator opens the destination folder, sees the .mp4, opens it expecting real footage, gets a corrupted/truncated file.

**Why this priority**: Convergent P2 finding (F-5). The transfer pipeline has staging dirs + sweep + `wasOverwriteApproved` + `/XN /XC /XO`. Compression has none of that — it writes directly to `output.mp4` and on cancel leaves whatever HandBrake had written. The operator-confusion blast radius is real (looks like a real file).

**Independent Test**: Adopt the transfer-pipeline pattern for compression: write to a sibling staging path (`output.mp4.tmp_handbrake_<tag>`); on success, atomic rename to final; on cancel/failure, delete the staging file. Extend the cold-start sweep to also walk `.tmp_handbrake_*` siblings of expected output paths and delete those whose `.live` marker is missing or stale. Test: cancel a compression mid-encode, verify the final path is absent (not a partial), the staging file is cleaned by the cold-start sweep.

**Acceptance Scenarios**:

1. **Given** a compression job in progress writing to staging path `out.mp4.tmp_handbrake_xyz`, **When** the operator cancels mid-encode, **Then** the final path `out.mp4` does NOT exist AND the staging file is removed (or is removed by the next cold-start sweep).
2. **Given** a compression job that completed successfully, **When** the file is read at the destination, **Then** it is at the expected final path with no `.tmp_handbrake_*` siblings.
3. **Given** a partial `out.mp4.tmp_handbrake_oldtag` left on disk by a prior crashed run AND no longer referenced by any active job, **When** the cold-start sweep runs, **Then** the partial is removed and an INFO line is logged via `LogPhase.recover`.

---

### User Story 6 — Bundle: Slack settings failure does not kill the pipeline (Priority: P3)

Slack notifications are best-effort by design — failures don't stop the pipeline. But `_getWebhookUrl()` runs OUTSIDE the `try` block in `_send`, so a settings DAO failure (DB locked, schema error, etc.) propagates up into the calling pipeline phase rather than being swallowed.

**Why this priority**: Codex-only finding (F-D2 LIKELY). Bundled because cost is ~3 lines of move-into-try. Defends the "best-effort" contract per Constitution V (observable progress should never block the main pipeline).

**Independent Test**: Move the `_getWebhookUrl()` call inside the existing try block in `_send`. Add a test that throws from the settings DAO and asserts the calling pipeline phase still completes successfully (the failure is logged as a Slack failure, not surfaced as a pipeline failure).

**Acceptance Scenarios**:

1. **Given** the settings DAO throws on `getSettings()`, **When** the executor calls any `notify*` method, **Then** the `notify*` returns without throwing AND a warning is logged to `LogPhase.finalize` (or appropriate phase).
2. **Given** the webhook URL is empty in settings, **When** the executor calls any `notify*` method, **Then** behavior is unchanged from v2.4.0 (silent return, no log noise).

---

### User Story 7 — Bundle: long-path SHA-256 hashing succeeds via `\\?\` prefix (Priority: P3)

PowerShell 5.1 (default on Windows 11 without explicit upgrade) cannot read paths > 260 chars without the `\\?\` prefix. Currently `Get-FileHash -LiteralPath '...'` is called with the raw path; long-path files fail and stay stuck in `verifyStatus=unverified` forever no matter how many times the operator clicks Retry.

**Why this priority**: Opus-only finding (F-D6 LIKELY). Round-22 mentioned the prefix; only the preflight warning shipped. Bundle now (low cost: prepend `\\?\` if path > 240 chars at the SHA-256 call site).

**Independent Test**: In `transfer_service.dart::computeFileHash` (and the recovery branch's hash calls), prepend `\\?\` to the path passed to `-LiteralPath` when the path length exceeds a threshold (say 240 chars to leave headroom). Test: synthesize a temp file at a path > 260 chars on Windows, attempt hash, assert success.

**Acceptance Scenarios**:

1. **Given** a source file at a path 280 chars long, **When** `computeFileHash` is called for it, **Then** the call returns the correct SHA-256 hash (no subsystem failure).
2. **Given** a source file at a normal-length path (e.g., 100 chars), **When** `computeFileHash` is called, **Then** behavior is identical to current — no `\\?\` prefix added (avoids any robocopy/HandBrake-side path-format issues).

---

### User Story 8 — Bundle: `_runPowerShell` enforces length-3 argv invariant (Priority: P3)

The 017A length-3 argv assertion lives in `process_runner.dart::runPowerShellInline`. `drive_service.dart::_runPowerShell` is a separate code path that calls `Process.run('powershell', [...])` directly with no assertion. A future refactor that adds a 4th argv element to any of `getRemovableDrives`, `getDiskFreeSpace`, `getDriveIdentity`, `eraseDrive` would silently re-open the v2.4.0 root cause for those specific helpers.

**Why this priority**: Opus-only finding (F-D7 — open footgun). Bundle now (cost: assert in `_runPowerShell` + CI grep guard).

**Independent Test**: Add `assert(args.length == 2 && args[0] == '-Command', ...)` inside `_runPowerShell` (the args after `-NoProfile` must be `['-Command', script]`). Test: a synthetic call with a 4th argv element throws an AssertionError in debug builds.

**Acceptance Scenarios**:

1. **Given** a call to `_runPowerShell(args=['-Command', 'Get-PSDrive'])`, **When** the helper executes, **Then** the assertion passes and the subprocess runs.
2. **Given** a call to `_runPowerShell(args=['-Command', 'script', 'extra-positional'])`, **When** the helper executes in debug mode, **Then** an AssertionError is thrown with a message naming the helper that's broken.

---

### Edge Cases

- **F-1 specific**: What if WMI temporarily fails to return a serial (transient PowerShell flake)? The serial check returns null/empty. We must NOT fail-open (treat null as "match") — fail-closed by refusing the operation and surfacing "could not verify card identity, retry."
- **F-2 specific**: How are camera-temp files handled (e.g., `.THM`, `.CTG`, sidecar metadata)? The video-extension allowlist at enumeration excludes these. The "added file" check should use the same allowlist — added `.THM` files do NOT trigger refusal.
- **F-2 specific**: What if the operator INTENTIONALLY adds a file (e.g., a clapboard log) to the card after the transfer to keep with the originals? Erase still refuses. The operator's recourse: re-create the job to capture the new files first, OR manually delete the addition. Documented in the refusal message.
- **F-3 specific**: What about case-only-different filenames (NTFS case-insensitive)? Already handled by the existing `_normalizeCaseCollisionsAcrossPlans` from 017B. The symlink guard is independent.
- **F-4 specific**: What if the operator clicks Retry, then before robocopy completes, manually accepts the verify-mismatch warning via JobCardDone? The forceDestDeleteApproved is preserved (per the new ordering); the accept handler should also clear it. Audit the accept paths to ensure they `clearForceDestDeleteApproved` as part of the accept transaction.
- **F-5 specific**: Compression preserves audio/timing — partial outputs may have a valid header but truncated stream. HandBrake doesn't write a recovery atom. Detection must be based on "the file exists at the staging path" not "the file is parseable" (we don't decode).
- **F-D2 specific**: Slack failures must STILL log to the local log file. Don't silence into oblivion.
- **F-D6 specific**: The `\\?\` prefix changes path semantics (no `..` resolution, no relative paths, no `/` accepted). Apply ONLY to the PowerShell hash call; do NOT propagate into robocopy/HandBrake argv (those have their own long-path handling on Windows 10+).

## Requirements *(mandatory)*

### Functional Requirements

#### Drive identity (F-1, US1)

- **FR-001**: A `Job.sourceDriveSerial` (TEXT, nullable) column MUST be added to the `jobs` table at job-create time, populated via the existing `DriveService.getDriveIdentity()` WMI call.
- **FR-002**: At every transfer-resume, the executor MUST re-call `getDriveIdentity()` for the current `Job.sourcePath` drive letter and refuse to proceed if the result differs from `Job.sourceDriveSerial`. Refusal surfaces a banner with both serials.
- **FR-003**: At erase-eligibility evaluation in `eraseEligibilityReason()`, the same re-check MUST run; mismatch produces a refusal that prevents the typed-confirmation dialog from opening.
- **FR-004**: On `getDriveIdentity()` returning null/empty (transient WMI failure), the system MUST fail-closed: refuse the operation, log the failure, surface "could not verify card identity, retry."

#### Erase rescan (F-2, US2)

- **FR-005**: At erase-eligibility evaluation, the system MUST re-enumerate video files on the source SD card (using the same extension allowlist used at job-creation enumeration) and compare against the planned set in the DB.
- **FR-006**: Any file present on the card AND not in the planned set MUST cause refusal. The refusal message includes the count and a sample (up to 5) of unplanned filenames.
- **FR-007**: Files in the planned set BUT missing from the card MUST NOT cause refusal (operator-driven deletion is permitted; the missing files' destinations are already verified per the existing `eraseEligibilityReason` logic).

#### Source-side symlink guard (F-3, US3)

- **FR-008**: Source-side enumeration in `drive_service.dart` and `job_queue_service.dart` MUST pass `followLinks: false` to all `Directory.list` calls.
- **FR-009**: Per-entry, the system MUST check `FileSystemEntity.type(path, followLinks: false)` and skip entries whose type is `link` (or anything other than `file` for the leaves). Skips MUST be logged at WARNING with `LogPhase.preflight`.

#### Force-delete consumption ordering (F-4, US4)

- **FR-010**: `clearForceDestDeleteApproved` MUST be deferred until AFTER robocopy returns success for the file (i.e., AFTER `markFileCompleted(verified: false)` is written). The current top-of-loop clear MUST be removed.
- **FR-011**: On cancel/crash/error mid-operation, the persisted `forceDestDeleteApproved` MUST remain `true` so the next pass re-honors the operator's intent.
- **FR-012**: The Accept-mismatch / Accept-unverified paths in `JobFileDao` MUST also clear `forceDestDeleteApproved` as part of their existing transaction (otherwise an accepted file's stale approval would mis-fire if the operator later re-runs).

#### HandBrake staging (F-5, US5)

- **FR-013**: `compression_service.dart::compressFile` MUST write to a staging path `<output>.tmp_handbrake_<tag>` (or a sibling subdirectory `<dirname>/.tmp_handbrake_<tag>/<basename>`).
- **FR-014**: On HandBrake exit-success, the system MUST atomically rename the staging file to the final output path.
- **FR-015**: On cancel/failure, the staging file MUST be deleted before returning failure to the executor.
- **FR-016**: The cold-start sweep in `lib/services/startup_sweep.dart` MUST be extended to also walk expected compression-output directories and remove `.tmp_handbrake_*` files/dirs whose `.live` marker is absent or stale (using the same host-as-load-bearing logic from 018 round-25).
- **FR-017**: The staging file write MUST follow the same `.live` marker convention as transfer staging (`host=`, `pid=`, `exe=`).

#### Bundled defenses (F-D2, F-D6, F-D7)

- **FR-018**: `slack_service.dart::_send` MUST move `_getWebhookUrl()` inside the existing try/catch so a settings DAO failure logs as a Slack failure rather than propagating up.
- **FR-019**: `transfer_service.dart::computeFileHash` (and the recovery-branch equivalents) MUST prepend `\\?\` to paths exceeding 240 characters before passing to PowerShell `Get-FileHash -LiteralPath`.
- **FR-020**: `drive_service.dart::_runPowerShell` MUST assert the length-3 argv invariant (`args == ['-Command', script]` after the leading `-NoProfile`). A CI grep guard MUST verify no PS helper passes more than that shape.

### Non-Functional Requirements

- **NFR-001**: Drive-identity re-check at transfer-resume MUST complete in under 500ms per resume (the WMI call dominates; cache the result for the duration of a single executor pass).
- **NFR-002**: Erase-eligibility rescan of the SD card SHOULD complete in under 2 seconds for a typical batch (~30 files). For larger sets, the operator sees a brief "Rescanning card..." indicator.
- **NFR-003**: Source-side symlink guard MUST NOT regress enumeration performance for the common no-symlinks case (the `FileSystemEntity.type` check is a single syscall per entry; acceptable overhead).
- **NFR-004**: HandBrake staging directory adds at most one rename per successful compression. Acceptable compared to the encoding cost.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001 (F-1)**: 100% of pause→resume operations across a different physical card refuse to transfer or erase. Tested via swap simulation in unit tests + manual swap on Windows acceptance.
- **SC-002 (F-2)**: 100% of erase attempts on cards with unplanned video files refuse. Tested via temp-card seeding in unit tests + manual file-add on Windows acceptance.
- **SC-003 (F-3)**: 100% of source enumerations skip symlinks; cyclic junctions complete in bounded time. Tested via temp-dir junction setup in unit tests.
- **SC-004 (F-4)**: After cancel-mid-robocopy on a force-delete-approved file, the persisted column reads `true`; the resumed pass observably honors it. Test via failure injection in the executor.
- **SC-005 (F-5)**: After cancel-mid-encode of a compression job, the final output path is absent; staging file is removed by sweep. Test via TransferService stub (controlled HandBrake CLI exit) + sweep invocation.
- **SC-006 (F-D2)**: Settings DAO failure in `_send` does not propagate to the executor caller. Test via DAO mock that throws.
- **SC-007 (F-D6)**: Path > 260 chars hashes correctly via `\\?\` prefix. Test via temp file at synthesized long path.
- **SC-008 (F-D7)**: A 4-argv call to `_runPowerShell` throws AssertionError in debug builds. Test via direct call.
- **SC-009 (gate)**: `flutter analyze` clean. `flutter test` passes 100% (target: 126 baseline + ~24 new from US1-US8 = ~150 tests).
- **SC-010 (gate)**: TWO Codex `gpt-5.5 effort=high` adversarial-review rounds over the 019 lifecycle (per Q5 clarification). Round 27a fires after `/speckit-plan` + `/speckit-tasks` are committed, before any implementation begins — catches design-decision errors. Round 27b fires after the full 019 implementation lands, before merge — catches code-level errors. Each round's P1 findings MUST be folded back; P2 findings folded if cheap; P3 findings documented for v2.5.1. The merge gate requires zero open P1s from either round.

## Constitution Alignment

- **Principle I (Human-in-the-loop)**: Strengthened. F-1 and F-2 close two paths where automation could destroy operator data without a deliberate operator action targeting THAT data specifically. The typed-confirmation gate alone is insufficient when the system has lied about the identity (F-1) or completeness (F-2) of what's about to be erased.
- **Principle III (Resilient pipeline)**: Strengthened. F-4 closes a state-machine race that abandoned operator intent under cancel; F-5 brings compression up to the same staging-dir resilience as transfer.
- **Principle V (Observable progress)**: Maintained. F-D2 ensures Slack failures don't pollute pipeline error reporting.
- **Principle IV (Minimal complexity)**: Care. F-1's drive-identity check adds one column + one WMI call per resume — acceptable. F-2's rescan adds one `Directory.list` per erase eligibility — acceptable. F-5's HandBrake staging is the largest scope addition; the staging+sweep pattern reuses the established 018 infrastructure rather than inventing parallel mechanisms.

## Out of Scope (deferred to v2.5.1)

The 5 single-auditor findings the audit-findings doc tags as deferred:
- F-D1 (size-mode TOCTOU on renamed-staged transfer with same-size pre-existing target) — SHA-256 mode catches it; team can default to SHA-256.
- F-D3 (sweep prefix collision) — operator-created `.tmp_robocopy_*` dir is implausible.
- F-D4 (cross-machine NAS write race) — team's current workflow doesn't appear to hit; round-25 closed the sweep half.
- F-D5 (DST/clock-jump mtime cutoff inversion) — once a year, narrow window, SHA-256 mode catches.
- F-D8 (eraseDrive Remove-Item without -LiteralPath) — camera-formatted filenames don't have wildcards.

These are logged in CLAUDE.md → "Open bugs deferred to v2.5.1" once 019 ships.
