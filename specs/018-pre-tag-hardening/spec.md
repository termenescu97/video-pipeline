# Feature Specification: Pre-Tag Hardening for v2.5.0

**Feature Branch**: `018-pre-tag-hardening`
**Created**: 2026-05-09
**Status**: Draft
**Input**: User description: "Pre-tag hardening for v2.5.0 — fix the 10 adversarial-review findings (1 P1, 4 P2, 5 P3) documented in specs/v2.5.0-pre-tag-findings.md. Compiled from parallel Opus + Codex (round 21) reviews of branch 017-ux-restructuring after 20 prior Codex rounds."

## Background

After 20 rounds of `gpt-5.5 effort=high` adversarial review on the 017A + 017B work that constitutes v2.5.0, two parallel reviewers (Codex round 21 + Claude Opus subagent), each given the same hostile-review prompt with no cross-pollination of findings, surfaced 10 additional issues. One is data-safety-critical, four are correctness-class, five are observability/hygiene. None re-open already-fixed bugs.

This feature is the **last gate before tagging v2.5.0**. The operator's "bundle deferred fixes before asking for QA" preference applies: every finding lands here, not split across patch releases. After this feature merges and Windows acceptance passes, the v2.5.0 tag goes out.

The canonical input is `specs/v2.5.0-pre-tag-findings.md` (committed earlier on this branch). It enumerates each finding with file/line refs, problem, risk, fix sketch, and provenance.

## Clarifications

### Session 2026-05-09

- Q: F-2 priority — keep at P1 or revert to review-doc's P2? → A: Keep at P1. The consequence chain (misclick blesses corrupt bytes → unblocks chained compression → encodes corrupt bytes → operator can then erase source SD card under their own authority) is irreversible in a way the other P2s aren't. The typed-gate primitive already exists, so cost-to-ship matches P2 while benefit prevents an authority-laundering chain. Constitution Principle I treats this category as foundational.
- Q: US3 and US5 bundling — keep multi-finding stories or split per finding? → A: Keep bundled. US3 (F-4+F-5) groups by theme "concurrent actions don't break things"; US5 (F-6+F-7+F-8+F-10) groups by theme "the system tells the truth". The 6-story shape stays reviewable; tasks generated downstream will naturally split per finding regardless of story granularity.
- Q: FR-013 strategy — atomic write-pairs, self-healing recompute, or both? → A: Atomic write-pairs at every paired counter site, plus self-healing recompute as defense-in-depth. Eliminates the drift class at the source while keeping a fallback that catches any future call site that forgets the atomic pattern. Mirrors the existing `acceptUnverified` shape — refactor-to-pattern, not new abstraction.
- Q: FR-015 staging-dir sweep scope — which destination roots, what perf budget? → A: Sweep destination roots of jobs in non-terminal status (queued, paused, inProgress) plus the single most-recently-completed job's root. Bounded scope (typically 1–3 roots) keeps startup latency predictable; orphans on drives no longer in active use are unreachable to daily workflow and skipped by the existing unmounted-drive guard. On-demand cleanup via Settings → Diagnostics is deferred to v2.6+.
- Q: FR-009 — does enabling the FK pragma require a pre-flip cleanup of already-dangling references in existing v8 databases? → A: Yes. The bug being fixed produced exactly the dangling references that strict FK enforcement will now reject. Run a one-time `UPDATE jobs SET parent_job_id = NULL WHERE parent_job_id IS NOT NULL AND parent_job_id NOT IN (SELECT id FROM jobs)` cleanup before the pragma flip on every connection open (idempotent — safe to re-run; affects at most a handful of rows per operator). Without cleanup, operators who deleted parents pre-release would see deferred constraint errors that look unrelated to this feature.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator-driven retry survives a crash with no silent intent loss (Priority: P1)

The operator finishes a 27-file SHA-256 transfer, sees one file flagged with a verify-mismatch warning chip in history, and clicks Retry on that one file. Before the queue picks the retried file up, the workstation loses power (or the OS kills the process, or the operator force-quits). On next launch the operator expects to see *either* the retried file already processing/queued *or* the original mismatch warning still showing — never a job that looks completely clean while the corrupt destination quietly remains.

**Why this priority**: This is the single P1 finding from the combined review. A silent loss of operator intent on a data-safety action is exactly the failure class the v2.5.0 release was meant to eliminate. Today the retry can leave the file in a state that no recovery path picks up, and the operator has no observable signal that anything is wrong.

**Independent Test**: Synthetically interrupt the retry action between its two persisted writes (e.g., via a test build that throws partway through the action). On next launch, verify the file is either back in its original mismatch state or actively being retried — never in a no-warning, no-retry "ghost pending" state. Closes finding F-1.

**Acceptance Scenarios**:

1. **Given** a job with one verify-mismatched file row in history, **When** the operator clicks Retry on that row and the process is killed mid-action, **Then** on next launch the row is observably either (a) flagged with the original mismatch warning, OR (b) flagged as queued/processing for retry — never reset-to-pending with the parent job still marked as cleanly completed.
2. **Given** the same scenario, **When** recovery completes on next launch, **Then** the operator can re-issue the retry action without any intermediate cleanup step (no orphaned rows, no stale flags).

---

### User Story 2 - Trust-lowering operator decisions require a typed confirmation gate (Priority: P1)

When the operator chooses to Accept a mismatched file (cryptographic proof that the destination bytes differ from source), Accept an unverified file (the SHA-256 subsystem could not compute a hash), or Skip a mismatched file from the active-card banner, the act of confirming requires typing a specific phrase — not a single click of a Confirm button. This matches the existing project convention for destructive operator actions (already enforced for SD-card erase, conflict-overwrite, and similar trust-lowering decisions).

**Why this priority**: P1 because (a) Constitution Principle I (Human-in-the-Loop) is foundational, (b) accepting a mismatch can immediately unblock chained compression — meaning a misclick can cause the pipeline to encode known-corrupt bytes into the final output and then erase the source SD card under operator authority, and (c) the typed-gate primitive already exists in the codebase; this is a convention-conformance gap, not a new abstraction.

**Independent Test**: For each of the three actions (Accept mismatch, Accept unverified, Skip mismatch), confirm the dialog requires the operator to type a specific phrase (matching the established pattern from the SD-erase dialog) before the confirm button becomes enabled. A button-only confirmation must be impossible. Closes finding F-2.

**Acceptance Scenarios**:

1. **Given** a verify-mismatched file in the active job's banner, **When** the operator clicks Skip, **Then** the dialog presents a typed-input gate (e.g., type "skip mismatch") and the confirm button stays disabled until the input matches exactly.
2. **Given** a verify-mismatched or verify-unverified file in history, **When** the operator opens the context menu and clicks Accept, **Then** the same typed-gate pattern applies before the verify-axis flip is committed and before any auto-chained compression unblocks.
3. **Given** any of the three dialogs, **When** the operator types a case-different variant of the required phrase, **Then** the dialog surfaces an inline "case-sensitive match required" hint (matching the existing pattern in the project's typed-gate primitive).

---

### User Story 3 - Concurrent operator actions produce predictable single outcomes (Priority: P2)

Two correctness-class race conditions are reachable through normal operator interaction patterns. (a) When the operator accepts mismatched and accepts unverified files in quick succession on the same job, only one chained compression child is ever created — never two competing for the same destination path. (b) When the operator closes the window during active processing and then immediately clicks Accept on a history card before the shutdown finishes draining, only one processing loop is ever active — never two robocopy invocations against the same destination.

**Why this priority**: P2 because both bugs require timing precision that doesn't surface in synthetic tests but will eventually surface on a real workstation given enough months of operation. Both can produce duplicated work and visible UI chaos, but neither produces silent data corruption (the destination conflict would be loudly observable).

**Independent Test**:
- (a) Fire two simultaneous Accept handlers on a job and assert the database contains exactly one chained compression child afterward, regardless of timing.
- (b) Begin a `stopProcessing` then immediately invoke a code path that triggers `startProcessing` and assert only one processing loop ever observes the queue.

Closes findings F-4 and F-5.

**Acceptance Scenarios**:

1. **Given** a transfer-and-compress job with both mismatched and unverified files, **When** the operator clicks "Accept mismatched" and "Accept unverified" before either handler completes, **Then** exactly one chained compression child is created and runs once.
2. **Given** an in-flight processing run, **When** the operator closes the window and a queued action triggers another processing-start call before the original loop's await resolves, **Then** the second start either waits for the prior stop to drain or is rejected — and only one processing loop ever runs against the queue.

---

### User Story 4 - Cross-job references stay coherent through deletes (Priority: P2)

When the operator deletes a parent transfer-and-compress job from history, any chained compression child that references it does not silently retain a dangling reference. Either the foreign-key relationship cascades the reference to null (if the database constraint is correctly enforced), or the child surfaces a "parent deleted" indicator. The current state — where the documented constraint silently fails to fire because the underlying enforcement pragma is off — is not acceptable.

**Why this priority**: P2 because the symptom today is graceful degradation (the chained Slack notification quietly omits the parent verify counts), not visible failure. But the documented invariant is a lie, and any future code that trusts the constraint to keep references either-valid-or-null will break in a way that is hard to debug — which is the exact failure mode the next reviewer will hit.

**Independent Test**: Open a fresh database, assert that the foreign-key enforcement pragma is on. Delete a parent job that has a chained compression child. Assert the child's parent reference is null (not a dangling integer), and the chained Slack notification correctly degrades. Closes finding F-3.

**Acceptance Scenarios**:

1. **Given** a freshly-opened database, **When** any code reads the foreign-key enforcement state, **Then** it is observably enabled.
2. **Given** a transfer-and-compress parent job with a chained compression child, **When** the parent job is deleted from history, **Then** the child's parent reference is observably null (not a dangling integer to a deleted row).
3. **Given** a chained compression child whose parent has been deleted, **When** the child completes, **Then** the chained Slack notification correctly omits the parent verify line without erroring.

---

### User Story 5 - Operator-facing reporting matches reality across all output channels (Priority: P3)

Across the four operator-visible reporting surfaces (Slack messages, on-screen error text, job-level counters, on-screen progress credit), the reported state always matches what actually happened. Specifically:
- A clean size-mode transfer does NOT report "0 verified" alongside "Passed" in the same Slack message.
- A job whose status was lifted from `failed` to `completed` during a v7→v8 schema migration does NOT carry stale failure text from the failed era.
- The job-level unverified-files counter does NOT silently lag the per-row state after an abandoned shutdown.
- Size-mode and SHA-256-mode jobs credit copy-progress to the operator at the same point in their respective sequences (immediately after the copy succeeds).

**Why this priority**: P3 because each of the four bugs is observable to an attentive operator but does not cause data loss. Each fix is small and isolated; bundling them into one user story keeps the review surface coherent ("does the system tell the truth about itself?") rather than scattering across four micro-stories.

**Independent Test**: For each of the four sub-issues, run the triggering scenario and assert the reported state matches the underlying state. Closes findings F-6, F-7, F-8, F-10.

**Acceptance Scenarios**:

1. **Given** a clean size-mode transfer of N files, **When** the post-transfer Slack ping is sent, **Then** the verified-count line and the verdict line agree (no "Verified: 0 · Passed" contradiction).
2. **Given** a v7 database upgraded through the v8 migration, **When** a job has been lifted from `failed` to `completed` because its only failed children were hash-only failures, **Then** the job's error-message field is either cleared or rewritten to reflect the migration outcome (no stale "X failed copy" text on a job marked completed).
3. **Given** an abandoned shutdown that interrupts the recovery branch's two-write sequence, **When** the operator inspects the job after the next launch, **Then** the job-level unverified counter agrees with the per-row state (no "0 unverified" badge above a row carrying the unverified chip).
4. **Given** a size-mode transfer in progress, **When** a file's copy completes, **Then** the on-screen progress bar and counters credit the bytes immediately, without waiting for the size-verify check (matching the existing SHA-256-mode behavior).

---

### User Story 6 - Filesystem hygiene on the destination drive (Priority: P3)

The destination drive does not accumulate orphaned staging directories across app crashes. Today, when the app crashes between staging-rename success and staging-dir cleanup, the empty staging directory is left on disk forever and accumulates over time as the operator's video archive grows.

**Why this priority**: P3 because this is cosmetic litter, not data loss. But the operator opens the destination folder in Windows Explorer regularly, and accumulating temp directories will eventually become visible noise (and may slow antivirus scans of the directory).

**Independent Test**: Place orphaned staging-dir-shaped directories on a known destination root, run the startup sequence, assert the orphans are removed (and that no in-flight staging dirs from a currently-running instance are touched). Closes finding F-9.

**Acceptance Scenarios**:

1. **Given** orphaned staging directories left behind by a prior crash, **When** the app starts, **Then** any empty staging directory matching the established naming pattern is removed.
2. **Given** an in-flight transfer with a live staging directory, **When** a startup sweep would otherwise run, **Then** the live staging directory is not touched (the sweep recognizes it as belonging to a currently-running instance, e.g., via PID marker or matching tag).

---

### Edge Cases

- **Crash during the typed-gate flow itself.** The dialog state is in-memory only; a crash mid-typing simply discards the action. No persisted state changes occur until the operator confirms. No special handling needed.
- **Operator opens the Accept menu twice on different files of the same job.** US3 already covers the same-file race; cross-file races on the same job also produce at most one chained child because the dedup gate is keyed by parent job, not by which file triggered the accept.
- **A v7 database with rows whose error-message text was hand-edited (e.g., by manual SQL).** US5's migration cleanup acts only on rows that match the documented hash-failure error patterns from prior code paths. Manually-edited rows pass through unchanged. Acceptable: if the operator hand-edited the database, the operator owns the consequences.
- **Two simultaneous app instances racing through migration.** Out of scope: the existing OS-level instance lock prevents concurrent instances from both reaching the migration. If the lock is bypassed (e.g., manual file-copy of the database), behavior is undefined — same as today.
- **Foreign-key pragma fails to enable on a corrupted database.** Should surface as a startup error (the database is unusable anyway), not silently continue. Acceptable existing behavior of the database-open path.
- **Staging dir cleanup on a destination drive that was unmounted between crash and next launch.** The startup sweep simply skips drives that aren't mounted. Cleanup happens whenever the drive reappears AND a transfer to that drive begins; or never, if the destination is permanently abandoned. Acceptable: orphans on an unreachable drive aren't the operator's problem.

## Requirements *(mandatory)*

### Functional Requirements

#### Atomicity (US1)

- **FR-001**: When the operator initiates a per-file retry on a verify-mismatched or verify-unverified file, the system MUST persist all state changes (file-row reset, parent-job requeue, counter recompute) atomically. A process interruption between the start of the retry action and its full completion MUST NOT leave the system in a state where the file row is reset but the parent job is not requeued.

- **FR-002**: After a process interruption during a per-file retry, the recovery path on next launch MUST ensure the file is either (a) restored to its pre-retry state with the original verify warning intact, OR (b) actively queued for retry. A "ghost pending" state — file reset, parent completed, no warning visible — MUST be unreachable.

#### Typed Confirmation (US2)

- **FR-003**: The Accept-mismatched action on a file row MUST require a typed-confirmation gate matching the existing project convention for destructive actions (the same primitive used by the SD-erase flow). A single button click MUST NOT be sufficient.

- **FR-004**: The Accept-unverified action on a file row MUST require the same typed-confirmation gate as FR-003.

- **FR-005**: The Skip action on the active-card verify-mismatch banner MUST require the same typed-confirmation gate as FR-003.

- **FR-006**: The typed-confirmation gate for FR-003, FR-004, and FR-005 MUST be case-sensitive and MUST surface an inline hint when the operator types a case-different variant of the required phrase, matching the existing typed-gate UX pattern.

#### Concurrency (US3)

- **FR-007**: The auto-chain compression entry point MUST guarantee at-most-one chained child per parent job, even under concurrent invocations from multiple operator actions (e.g., Accept-mismatched and Accept-unverified clicked in quick succession).

- **FR-008**: A new processing-start invocation that occurs while a processing-stop request is in flight MUST NOT spawn a second concurrent processing loop. It MUST either await the prior stop's completion before starting, or be rejected outright.

#### Database Constraints (US4)

- **FR-009**: The database MUST enable foreign-key constraint enforcement for every connection it opens. Before the enforcement is enabled on each connection, the database MUST run an idempotent cleanup that nulls any pre-existing dangling parent-job references — covering the case where an operator deleted a parent job during the era before this release, when the documented `ON DELETE SET NULL` constraint silently failed to fire. After enforcement is enabled, the constraint MUST observably take effect for all subsequent parent deletions.

- **FR-010**: Deleting a parent transfer-and-compress job MUST result in any chained compression child's parent reference observably becoming null, not a dangling integer. This applies to both new deletions (FR-009 enforcement) and pre-existing dangling references from before this release (FR-009 cleanup).

#### Reporting Truthfulness (US5)

- **FR-011**: For a clean size-mode transfer (all files passing size verification, no SHA-256 failures), the post-transfer Slack notification MUST NOT report "Verified: 0" alongside a "Passed" verdict. The verified-count line and the verdict MUST agree, mirroring the corrected behavior of the chained-compression Slack notification.

- **FR-012**: When the v7→v8 schema migration lifts a job's status from `failed` to `completed` (because its only failed children were hash-only failures), the job's stored error message MUST be either cleared or rewritten to reflect the migration outcome. UI surfaces reading the error message MUST NOT display stale "X failed copy" text on a job marked as completed.

- **FR-013**: The job-level unverified-files counter MUST stay consistent with the per-row state. The implementation MUST combine the per-row state mutation and the counter-update mutation into a single atomic write at every paired call site (eliminating the drift class at the source), AND MUST also provide a self-healing recompute on the operator-facing read paths as defense-in-depth against any future call site that forgets the atomic pattern. After an abandoned shutdown that interrupts a paired write, the next operator interaction MUST observe a counter that matches the per-row reality.

- **FR-014**: For size-mode transfers, the executor MUST mirror the SHA-256-mode write sequence exactly: after the underlying copy succeeds, persist `status=completed` with the legacy `verified` boolean still false (using `markFileCompleted(verified: false)` or its size-mode equivalent), then credit progress bytes, THEN run the size verification, then on size-verify success call `markFileSizeOnlyVerified` (which finalizes the verify axis), or on size-verify failure call `markFileFailed`. The system MUST NOT write a "size-verified" success state before the size check has actually run — doing so could persist a bad file as clean/completed if the process is interrupted between the premature write and the failed size check.

#### Filesystem Hygiene (US6)

- **FR-015**: The system MUST sweep orphaned staging directories at startup, scoped to destination roots of jobs in non-terminal status (queued, paused, inProgress) plus the single most-recently-completed job's destination root. Empty staging directories matching the established naming pattern, with no marker indicating they belong to a currently-running instance, MUST be removed. Live staging directories from a currently-running instance MUST NOT be removed. Destination drives that are not currently mounted MUST be skipped silently (no error, no retry-on-mount).

### Key Entities

This feature does not introduce new persisted entities. It modifies the behavior surrounding existing entities: `Job`, `JobFile`, the `verifyStatus` axis, the foreign-key relationship between parent and child jobs, and the staging-directory naming convention used during renamed-destination transfers.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of synthetic per-file retry interruption tests result in the system reaching one of the two acceptable post-recovery states defined in FR-002. Zero "ghost pending" outcomes across a test matrix that interrupts between every awaited operation in the retry action.

- **SC-002**: 100% of the three trust-lowering operator actions (Accept mismatched, Accept unverified, Skip mismatch) require the operator to type a specific phrase before the confirmation completes. Zero paths reach the destructive write via a button-only confirmation.

- **SC-003**: Across 1000 paired-Accept stress runs (Accept mismatched + Accept unverified fired with no delay between them), exactly one chained compression child is created per parent. Zero duplicates.

- **SC-004**: Across 100 stop-then-start stress runs (window close immediately followed by a queue-triggering action), exactly one processing loop is ever active at any moment. Zero observed concurrent loops.

- **SC-005**: A freshly-opened database observably has foreign-key enforcement enabled. A test database seeded with a dangling parent reference (simulating pre-release operator deletion) is cleaned to null on first connection-open after this release, with no error surfaced to the operator. Deleting a parent job with a chained child results in the child's parent reference being null on subsequent reads.

- **SC-006**: For 100% of clean size-mode transfers in test, the post-transfer Slack notification's verified-count line agrees with its verdict line. No "Verified: 0 · Passed" pairs occur.

- **SC-007**: For a v7 test database containing jobs that the migration lifts from `failed` to `completed`, the job's stored error message field is either NULL or contains a message that does not contradict the new completed status.

- **SC-008**: After a synthetic abandoned shutdown that interrupts the recovery branch's row-update / counter-update pair, the next read of the job's unverified counter agrees with the per-row tally. Maximum drift: zero.

- **SC-009**: With the test `TransferService` configured to make `verifyTransfer` block on a controlled completer, a size-mode transfer credits `Job.completedBytes` and `Job.completedFiles` BEFORE the completer is released. The assertion: read the persisted counters at the moment `verifyTransfer` is blocked, observe credited bytes; release the completer; observe `verifyStatus` finalize. Tautological metrics ("same await count") MUST NOT be substituted — the test must observe persisted state at the blocked-verify moment.

- **SC-010**: After a synthetic crash leaving an orphaned staging directory on a destination root in scope (per FR-015's bounded scope), the next app launch removes the orphan within the same startup sequence that runs job recovery, in under 500 ms of added startup latency for the typical case (1–3 roots in scope). Live staging directories from a currently-running instance are never touched. Orphans on drives outside the bounded scope or on unmounted drives are not removed (acceptable per Edge Case).

- **SC-011** (release-level): Once this feature merges, the Windows acceptance scenario from `RELEASE_NOTES_v2.5.0.md` (T067) passes end-to-end on the operator's workstation with no new defects introduced. Zero regressions on the 78-test suite.

- **SC-012** (review-level): A 21st adversarial Codex review (`gpt-5.5 effort=high`) of the merged feature surfaces no P1 or P2 findings. P3 findings are acceptable if they are net-new (not re-openings of any of the 10 findings closed by this feature).

## Assumptions

- The operator continues to be a single-user video editor on a single Windows 11 workstation. Multi-operator and multi-instance scenarios remain out of scope (consistent with the project's existing instance-lock design).
- The existing destructive-confirmation primitives (`showDestructive` / `showCritical`) are sufficient for the typed-gate requirements (FR-003 through FR-006). No new dialog primitive is needed.
- The existing database transaction primitive is sufficient for the atomicity requirements (FR-001, FR-007). No new locking layer is needed.
- The foreign-key enforcement pragma is supported by the underlying database engine in all environments the app ships to (true: SQLite has supported the pragma since version 3.6.19; the project's database engine is current).
- The orphan staging-directory sweep can rely on the in-process PID being stable across the startup sequence (a reasonable assumption for a desktop app's startup sequence).
- All findings are addressable with localized changes to the files identified in `specs/v2.5.0-pre-tag-findings.md`. No wider architectural refactor is required.
- The v2.5.0 tag will not ship until this feature is merged AND Windows operator acceptance (T067) passes. The "bundle deferred fixes before asking for QA" preference applies.
