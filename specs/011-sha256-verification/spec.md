# Feature Specification: SHA-256 File Verification

**Feature Branch**: `011-sha256-verification`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Add optional SHA-256 hash-based file verification as a per-job toggle alongside existing size verification"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator chooses verification mode during job creation (Priority: P1)

The operator creates a transfer job for a critical shoot. In the job creation form, they see a verification mode selector with two options: "Quick (size comparison)" and "Full (SHA-256 hash)." They select SHA-256 because this footage is irreplaceable. For routine dailies, they leave it on the default "Quick" mode.

**Why this priority**: This is the entry point for the feature. Without the toggle, there's no way to opt in to hash verification.

**Independent Test**: Open job creation form. Verify a verification mode toggle exists. Select "Full (SHA-256)." Create the job. Verify the job record stores the selected mode.

**Acceptance Scenarios**:

1. **Given** the operator opens the job creation form, **When** they look at the options, **Then** they see a verification mode selector defaulting to "Quick (size comparison)."
2. **Given** the operator selects "Full (SHA-256 hash)," **When** they submit the job, **Then** the job record stores the SHA-256 verification mode.
3. **Given** the operator creates a compression-only job, **When** they look at the form, **Then** no verification mode selector is shown (verification applies to transfers only).

---

### User Story 2 - SHA-256 verification runs after transfer and catches corruption (Priority: P1)

The operator starts a transfer job with SHA-256 verification enabled. After each file is transferred by the copy engine, the system computes the SHA-256 hash of both the source and destination files. If the hashes match, the file is marked as verified. If they don't match, the file is marked as failed with a clear message about hash mismatch.

**Why this priority**: This is the core value of the feature — detecting bit-level corruption that size comparison cannot.

**Independent Test**: Transfer a file with SHA-256 mode. Verify the system computes hashes for both source and destination. Confirm a matching hash marks the file as verified. Simulate a corrupted destination and confirm the mismatch is detected.

**Acceptance Scenarios**:

1. **Given** a transfer job with SHA-256 verification, **When** a file is successfully transferred, **Then** the system computes SHA-256 hashes of both source and destination files and compares them.
2. **Given** both hashes match, **When** the verification result is recorded, **Then** the file is marked as "completed" and "verified" with both hashes stored.
3. **Given** the hashes do not match (corrupted file), **When** the verification result is recorded, **Then** the file is marked as "failed" with the message "SHA-256 hash mismatch" and both hashes stored for inspection.
4. **Given** a transfer job with "Quick" verification mode, **When** a file is transferred, **Then** the existing size comparison verification runs — no hashing occurs.

---

### User Story 3 - Operator sees hash verification progress and results (Priority: P2)

During a SHA-256 verified transfer, the operator watches the detail screen. They can see that hashing is in progress ("Hashing source..." / "Hashing destination...") and after completion, they can view the stored hashes for each file. The Slack notification mentions which verification method was used.

**Why this priority**: Without visibility into the hashing phase, the operator sees a pause after transfer with no explanation — they might think the app is frozen.

**Independent Test**: Run a SHA-256 transfer job. Watch the detail screen. Verify hashing progress is visible. After completion, verify hashes are shown in file details. Check the Slack notification mentions "SHA-256 verified."

**Acceptance Scenarios**:

1. **Given** a file has been transferred and hashing begins, **When** the operator views the detail screen, **Then** the progress bar shows "Verifying: hashing source..." and then "Verifying: hashing destination..."
2. **Given** a SHA-256 verified job completes, **When** the operator views the file list, **Then** each SHA-256 verified file shows a shield icon. Tapping the file expands to reveal the full source and destination hashes.
3. **Given** a SHA-256 verified job sends a Slack notification, **When** the operator reads it, **Then** it says "Verification: SHA-256 — Passed" (or "FAILED" with count of mismatches).
4. **Given** a "Quick" verified job sends a Slack notification, **When** the operator reads it, **Then** it says "Verification: Passed" (same as before, no change).

---

### User Story 4 - Hash results are logged for audit trail (Priority: P2)

The team lead reviews the local log file after an overnight batch run. For SHA-256 verified jobs, each file's hash result is recorded — source hash, destination hash, and match/mismatch status.

**Why this priority**: The log provides a permanent record of verification results, useful for auditing and troubleshooting even after Slack messages scroll out of view.

**Independent Test**: Run a SHA-256 transfer job. Open the log file. Verify each file has a log entry with both hashes and the match result.

**Acceptance Scenarios**:

1. **Given** a file is SHA-256 verified successfully, **When** the operator checks the log, **Then** there is an entry like: "File IMG_0001.MOV — SHA-256 verified: source=abc123... dest=abc123... MATCH."
2. **Given** a hash mismatch occurs, **When** the operator checks the log, **Then** there is an entry with both hashes and "MISMATCH" clearly marked.

---

### Edge Cases

- What happens when the source file is removed (SD card ejected) before hashing completes? The hash fails and the file is marked as failed with an appropriate error message.
- What happens when hashing is interrupted by the operator stopping the queue? The file stays as "in progress" and can be retried. No partial hash is stored.
- What happens when the destination drive runs out of space during transfer but before hashing? The transfer itself fails (existing behavior) — hashing never starts.
- What happens when SHA-256 mode is selected for a "Copy & Compress" job? Verification applies to the transfer phase only. Compression doesn't use hash verification.
- What happens when the operator retries a SHA-256 job? Previously hashed files that passed are skipped (existing retry behavior). Failed files are re-transferred and re-hashed.

## Clarifications

### Session 2026-05-06

- Q: Should batch "Copy All Cards" support SHA-256 verification? → A: Yes. Add verification mode toggle to the batch flow — same default (Quick), but operator can select SHA-256 before clicking "Copy All Cards."
- Q: How should file hashes be displayed in the UI? → A: Show a shield/checkmark icon on SHA-256 verified files. Tap to expand and reveal both hashes. Keeps the file list clean.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The job creation form MUST offer a verification mode selector with two options: "Quick (size comparison)" as default, and "Full (SHA-256 hash)." The selector is visible only for job types that include transfer.
- **FR-002**: The system MUST store the chosen verification mode on the job record so it persists and is used during processing.
- **FR-003**: When SHA-256 mode is selected, the system MUST compute SHA-256 hashes of both source and destination files after each file transfer, compare them, and mark the file as verified (match) or failed (mismatch).
- **FR-004**: The system MUST store both the source and destination SHA-256 hashes on each file record for audit purposes.
- **FR-005**: The progress display MUST show hashing status during SHA-256 verification so the operator knows the system is working, not frozen.
- **FR-006**: Slack notifications MUST indicate the verification method used and the result (SHA-256 passed/failed vs size-based).
- **FR-007**: The local log file MUST record hash values and match results for every SHA-256 verified file.
- **FR-008**: The existing size-based verification MUST remain unchanged and continue to be the default.

### Key Entities

- **Job**: Extended with `verificationMode` field — stores the operator's choice (size or SHA-256) per job.
- **JobFile**: Extended with `sourceHash` and `destinationHash` fields — stores SHA-256 hashes for audit trail. Null for size-verified files.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Operators can choose between quick and full verification on every transfer job.
- **SC-002**: SHA-256 verification detects 100% of bit-level corruption (any byte difference produces a hash mismatch).
- **SC-003**: Hash verification progress is visible in the UI — no unexplained pauses during processing.
- **SC-004**: Both hashes are stored per file and accessible for audit after job completion.
- **SC-005**: Existing size-based verification behavior is unchanged — zero regressions for operators who don't opt in.
- **SC-006**: Slack notifications clearly distinguish between size-verified and SHA-256-verified jobs.

## Assumptions

- SHA-256 verification applies to transfer jobs and the transfer phase of "Copy & Compress" jobs. Compression-only jobs do not offer hash verification.
- Hashing is performed sequentially (source first, then destination) — not in parallel, to avoid USB controller contention.
- The default verification mode is "Quick (size comparison)" to match existing behavior and avoid surprising operators with slower jobs.
- Hash computation uses a system-level tool for reliability and performance rather than computing in Dart.
- The schema migration adds `verificationMode` to Jobs and `sourceHash`/`destinationHash` to JobFiles (schema v4→v5).
- Batch "Copy All Cards" includes a verification mode toggle (default: Quick). All jobs in the batch use the selected mode.
