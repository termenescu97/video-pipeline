# Feature Specification: Executor Correctness (v2.5.0)

**Feature Branch**: `017-executor-correctness`
**Created**: 2026-05-08
**Status**: Draft
**Input**: User description: Fix the executor failures the operator surfaced in the 2026-05-08 Windows test run on v2.4.0 — every SHA-256 hash call failed silently, the progress bar froze at 0 B / 161 GB despite robocopy succeeding on 3 of 27 files, and the log was failure-only with multi-line subprocess parser dumps drowning out signal. This is the data-safety pass; UX restructuring is feature 018.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Real-time progress visibility during a transfer (Priority: P1)

A video editor starts a transfer-and-compress job for an SD card with 27 files (~161 GB). They walk away and glance at the screen periodically. They expect to see progress advance: bytes transferred climbing toward total, file counter incrementing, current phase identifiable.

**Why this priority**: Without real-time progress, the operator cannot trust the system. The 2026-05-08 test showed `0 B / 161 GB` and `0 / 27 files` despite robocopy successfully copying 3 files — eroding all confidence in the app. This is the most visible operator-facing symptom.

**Independent Test**: Start a transfer with verbose logging enabled. Watch the progress bar advance during transfer, see the file counter tick up as each file completes, and observe phase transitions. No need to wait for the entire job to verify the wiring works.

**Acceptance Scenarios**:

1. **Given** a transfer-and-compress job for 27 files (161 GB), **When** transfer phase begins, **Then** the progress bar advances within 5 seconds of the first file completing and the file counter shows "1 / 27".
2. **Given** a verification subsystem failure (whatever cause), **When** files are copied successfully but verification fails, **Then** the file counter still advances and the affected files are marked "copied, unverified" rather than zeroing out progress.
3. **Given** a job in progress, **When** the operator looks at the active job card, **Then** they can identify the current phase (transfer / verify / compress) at a glance.

---

### User Story 2 — Trustworthy verification of every copied file (Priority: P1)

After a copy completes, the editor needs to know whether each file is byte-for-byte identical to the source. SHA-256 is the contract; the system must execute it correctly so the editor can erase the SD card with confidence.

**Why this priority**: The 2026-05-08 test showed every SHA-256 call failing with PowerShell parser errors. SHA-256 is the gate that unlocks the SD-card erase action (Constitution Principle I — Human-in-the-Loop). If verification is broken, the data-safety story collapses.

**Independent Test**: Start a transfer with SHA-256 verification enabled on a corpus including paths with spaces, apostrophes, non-ASCII characters, and a > 260-char path. Wait for completion. Open the per-file detail view. Every file should show a SHA-256 hash and a "verified" badge. No PowerShell parser errors in the log.

**Acceptance Scenarios**:

1. **Given** a transfer with SHA-256 verification enabled, **When** files include paths with spaces, apostrophes, brackets, dollar signs, backticks, or smart quotes, **Then** every file is hashed correctly without subprocess parser errors.
2. **Given** a SHA-256 mismatch on a copied file (real bytes corruption), **When** the operator sees the file marked "mismatch", **Then** the operator can choose Investigate, Retry, or Skip — and a Retry forces re-copy regardless of size match.
3. **Given** a SHA-256 mismatch and the operator clicks Retry, **When** the destination already exists with the same size as the source, **Then** the destination is deleted and the file is re-copied (instead of being silently re-verified to the same bad bytes).

---

### User Story 3 — Reliable recovery after abandoned shutdown (Priority: P1)

A power outage or forced shutdown happens mid-job. On restart, the system recovers gracefully: no double-credited bytes, no stranded almost-done files, and verification resumes without re-copying files that already reached the destination intact.

**Why this priority**: Constitution Principle III mandates resumability. If the operator has to re-copy 161 GB after a power outage, the entire pipeline is unusable for real production work.

**Independent Test**: Start a job, force-kill the app between the file-copy and file-verify steps for a single file (Task Manager force-end during the verify-phase log line). Relaunch. The job resumes with that file in verify-only state — no re-copy, no double-counted bytes.

**Acceptance Scenarios**:

1. **Given** a job where a file has been copied but not yet verified, **When** the app is killed and relaunched, **Then** the file enters the verify-only phase on next run; bytes are NOT re-credited.
2. **Given** a job rescued from abandoned shutdown, **When** the system computes overall job progress, **Then** the file counters are re-derived from per-file state (not trusted from the abandoned shutdown's last partial write).

---

### User Story 4 — Honest, structured logs for triage (Priority: P2)

After a problem, the editor or technical lead opens the log file to triage. Today's logs are failure-only with 6-line subprocess parser dumps. They want to see what happened during a successful run (to confirm health) and concise error lines (to spot real problems).

**Why this priority**: Constitution Principle V — Observable Progress. The current log fails this principle: successful operations are invisible, errors are buried in noise. Without it, the operator can't form a mental model of system health.

**Independent Test**: Run a successful 27-file job with logging enabled. Open the log. Verify each phase transition is logged at INFO level, each per-file success is logged at INFO level, and any errors are concise (one line each, not multi-line dumps).

**Acceptance Scenarios**:

1. **Given** a successful 27-file transfer, **When** the log is opened, **Then** there are INFO-level entries for enqueue, preflight start/end, transfer phase start/end, per-file copy success, verify phase start/end, and per-file verify success.
2. **Given** an error during execution, **When** the log is opened, **Then** the error line includes job ID, file index (e.g. `file=03/27`), current phase, and at most 200 characters of subprocess stderr — and it occupies one log line, not a multi-line parser dump.

---

### User Story 5 — Preflight catches NTFS case-only collisions (Priority: P2)

A source tree from a case-sensitive filesystem (Linux backup, macOS-formatted volume) contains `IMG_001.MOV` and `img_001.mov` in different sub-folders. On NTFS those two filenames collapse to the same destination file. The system detects this collision before starting the copy.

**Why this priority**: Silent overwrite is a data-loss event. The operator wouldn't notice one of the two files is missing until they try to use it. This violates Constitution Principle I in spirit (silent loss of source data).

**Independent Test**: Stage a source with two files differing only in case across two sub-folders. Start a transfer. Preflight detects the collision and offers a rename.

**Acceptance Scenarios**:

1. **Given** two source files with paths that differ only in case, **When** preflight runs, **Then** the collision is detected and the operator is offered a rename option that preserves both files.
2. **Given** the rename option is accepted, **When** the transfer runs, **Then** both files end at distinct destination paths with no data loss.

---

### Edge Cases

- **Hash subsystem entirely broken** (PowerShell missing or hijacked): affected files mark as "unverified" warning; copy progress still advances; job NOT declared failed.
- **Path with apostrophe in filename** (`Tibi's reels.mp4`): hash succeeds; no escape error.
- **Path > 260 characters** (Windows MAX_PATH limit): preflight warns operator (already exists from feature 010); hash either succeeds or marks unverified gracefully — never throws raw subprocess error to the operator.
- **UNC source path** (`\\nas01\share\...`): free-space check either routes to a UNC-aware helper or skips with a clear "free space check skipped" warning; copy proceeds.
- **Drive-letter remap on reinsert** (job started with `E:\`, SD card removed and reinserted as `F:\`): paused-job retry detects "source no longer available" and prompts re-detection via Sources panel.
- **Same-size corrupt destination after verify mismatch + operator Retry**: destination is deleted before robocopy re-copies (no infinite loop).
- **Abandoned shutdown between copy success and verify**: recovery enters verify-only phase for that file; counters re-derived from per-file state.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST execute SHA-256 verification reliably on Windows paths containing spaces, apostrophes, brackets, asterisks, dollar signs, backticks, smart quotes, and non-ASCII characters.
- **FR-002**: System MUST credit successfully copied bytes to overall progress immediately after a file reaches the destination, regardless of subsequent verification outcome.
- **FR-003**: System MUST distinguish three verification outcomes per file: **verified** (cryptographically matched), **mismatch** (cryptographic check ran but bytes differ), and **unverified** (verification subsystem itself failed). Each outcome MUST surface in the per-file detail view.
- **FR-004**: System MUST NOT mark a file as fully failed when only verification fails — copy success is independent of verification outcome.
- **FR-005**: When a file shows verification mismatch and the operator chooses Retry, System MUST delete the destination file before re-copying, regardless of whether the destination size matches the source.
- **FR-006**: When the system recovers from abandoned shutdown, files in a "copied but not yet verified" state MUST be routed to verify-only on next run (not re-copied).
- **FR-007**: When the system recovers from abandoned shutdown, job-level counters (copied, verified, unverified, failed) MUST be re-derived from per-file state — not trusted from the prior shutdown's last write.
- **FR-008**: System MUST detect collisions between two planned destination paths that differ only in character case before starting the transfer. Scoped to ASCII / Latin-script filenames in the operator's video corpus; non-ASCII Unicode case-folding is best-effort via `toLowerCase()` and does not need to match Windows' ICU case-folding tables in this release.
- **FR-009**: When a case-only collision is detected, System MUST offer the operator a non-destructive rename option that preserves both source files at distinct destination paths.
- **FR-010**: System MUST log INFO-level entries for job enqueue, preflight start/end (with verdict summary), transfer phase start/end (with totals), per-file copy success, verify phase start/end (with totals), per-file verify success, compression phase, finalization, recovery events, and shutdown phase transitions.
- **FR-011**: Every log entry MUST include structured context fields: timestamp, severity level, and (when applicable) job ID, file index out of total, and current phase.
- **FR-012**: Error log entries MUST be concise — at most one line for the message and at most 200 characters of subprocess stderr — without multi-line subprocess parser dumps.
- **FR-013**: The free-space check MUST validate path shape upfront (reject empty paths, detect UNC) and either route UNC paths to a UNC-aware helper or skip with a clear "free space check skipped" warning that does NOT block job creation.
- **FR-014**: Schema migration to v8 MUST preserve the data-safety semantics from v2.4.0 (features 015 + 016): `startedAt` preserved across resets; `wasOverwriteApproved` set only at preflight, survives retry, never cleared; `createdAt` mtime cutoff baseline never modified on retry/resume.
- **FR-015**: Schema migration backfill MUST distinguish cryptographically-verified historical rows from size-only-verified historical rows (size-only verification does not establish cryptographic trust and must NOT backfill to "verified").
- **FR-016**: Slack transfer-completed notifications MUST surface the per-job counts of verified, unverified, and mismatch files. When unverified or mismatch counts are non-zero, the notification MUST display a warning prefix (not a green checkmark verdict). This satisfies Constitution Principle V — operators who walk away from the workstation MUST receive actionable detail about non-clean completions.
- **FR-017**: `verifyStatus` semantics apply ONLY to transfer-phase verification. Compression-only jobs (`Job.type = compression`) leave `verifyStatus = pending` for their files and the UI MUST hide verify-related counters for these jobs. Transfer-and-compress jobs persist their transfer-phase `verifyStatus` across compression — the compressed output is intentionally different from the source and MUST NOT be hashed against it.
- **FR-018**: Counter re-derivation during recovery (FR-007) MUST run **once per rescued job** after all stale-row mutations complete, regardless of which stale states were detected. The **rescued-job set** is the union of: (a) jobs with `Job.status = inProgress`, AND (b) jobs that have at least one `JobFile` row in either `status = inProgress` OR (`status = completed` AND `verifyStatus = pending`). Recovery first mutates stale rows (resetting `inProgress` to `pending`, scheduling verify-only for `completed + pending`), then for each rescued job re-derives `Job.completedFiles`, `Job.completedBytes`, `Job.unverifiedFiles` from the per-row state. This prevents counter drift when recovery touches only a subset of stale row types in a given job.
- **FR-019**: Slack compression-completed notifications for `transferAndCompress` jobs MUST also surface the transfer-phase verify counts (verified / unverified / mismatch), persisted from the v8 schema across the compression phase. For `compression`-only jobs, the verify counts are zero and not surfaced. This closes the cross-phase notification gap — a compression-complete Slack ping after a non-clean transfer must NOT look clean.

### Key Entities

- **Job**: Represents a single transfer-and-compress operation initiated by the operator. Tracks aggregate counters (total / copied / verified / unverified / failed file and byte counts) and phase progression.
- **JobFile**: Represents a single source-destination file pair within a Job. Carries copy state (`pending` / `inProgress` / `completed` / `failed` / `skipped` — `completed` means "bytes on disk after robocopy success", independent of verification), verification state (`pending` / `verified` / `mismatch` / `unverified`), and failure kind (`none` / `copyError` / `verifyMismatch` / `verifyUnreliable`) for retry routing. The two state axes are independent — a file can be `status=completed && verifyStatus=mismatch` (bytes on disk, but corrupted) or `status=completed && verifyStatus=pending` (recovery scenario, bytes on disk awaiting verify).
- **AppSettings**: Represents persistent operator preferences. This feature's schema migration adds the collapsed/expanded state of the Sources panel (consumed by feature 018 — UX restructuring — which piggybacks on this migration to avoid a second schema bump).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100 % of SHA-256 hash operations on Windows succeed on the operator's standard test corpus (27 files, 161 GB, paths with spaces and special characters), measured by zero subprocess parser errors in the log.
- **SC-002**: During an active transfer, the progress bar advances visibly (bytes change at least every 5 seconds while at least one file is in flight) and the file counter increments within 5 seconds of each file completing — verifiable by the operator observing the screen.
- **SC-003**: After a forced shutdown mid-job and relaunch, zero files have double-credited bytes and zero copied-but-unverified files are silently dropped — verifiable by comparing pre-shutdown and post-recovery file states.
- **SC-004**: When the operator clicks Retry on a verification-mismatch file, the destination is replaced (not skipped). Zero cases of the system re-verifying the same corrupted bytes after Retry.
- **SC-005**: Operator can determine, by reading the log alone, the full sequence of events for any successful job — phase boundaries, per-file completion, elapsed time — without reaching for the GUI.
- **SC-006**: Zero cases of NTFS case-only collisions silently overwriting a source file's content, on a test corpus including two files differing only in filename case.
- **SC-007**: Schema v7 → v8 migration completes successfully on the operator's existing v2.4.0 database with zero lost rows and accurate backfill of `verifyStatus` and `failureKind` fields.
- **SC-008**: Slack notifications correctly distinguish clean completions ("Verification: SHA-256 — Passed") from completions with unverified or mismatched files (warning prefix + per-state counts), measured by inspecting the actual webhook payloads on both `notifyTransferCompleted` and `notifyCompressionCompleted` for a `transferAndCompress` test run with mixed file outcomes.

## Assumptions

- The target machine is Windows 11 with PowerShell 5.1 (default); paths longer than 260 characters may surface warnings rather than full success — full long-path support is deferred to v3.0.
- UNC source paths will become first-class in v3.0 (NAS upload feature). For v2.5.0, UNC sources are accepted but free-space check is skipped with a clear warning.
- The operator manages a single Windows workstation. Multi-machine sync is out of scope (v3.0).
- Schema v8 backfill assumes all existing v2.4.0 rows are valid; corrupted historical rows are out of scope.
- The constitution's six principles remain authoritative; this feature does not amend them.
- Feature 018 (UX restructuring) ships in the same v2.5.0 release tag and depends on the `AppSettings.sourcesPanelCollapsed` column added by this feature's schema migration.
