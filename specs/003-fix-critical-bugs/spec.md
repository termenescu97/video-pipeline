# Feature Specification: Critical Bug Fixes

**Feature Branch**: `003-fix-critical-bugs`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Critical bug fixes identified during architecture and UX review of v1.1.0"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Files Are Actually Transferred When a Job Runs (Priority: P1)

A user creates a transfer job from an SD card to the external HDD. When the queue starts processing, the system scans the source drive for video files, records each file in its internal tracking, and begins copying them one by one. Each file's progress is tracked individually. When done, all files exist on the destination with correct sizes.

**Why this priority**: Without this fix, the entire pipeline is non-functional. Jobs complete instantly without copying anything.

**Independent Test**: Create a transfer job for a drive containing video files. Start the queue. Verify that files appear on the destination and the job shows accurate file counts and sizes.

**Acceptance Scenarios**:

1. **Given** a user creates a transfer job from a source containing 5 video files, **When** the job is created, **Then** the system records all 5 files with their names and sizes in the job's file list
2. **Given** a transfer job starts processing, **When** each file is copied, **Then** the job's completed file count increments and progress updates in real-time
3. **Given** a transfer job completes, **When** the user checks the destination, **Then** all video files (.MOV, .MP4) from the source are present with matching sizes
4. **Given** a source contains non-video files (e.g., .txt, .jpg), **When** the job is created, **Then** only video files are included in the file list

---

### User Story 2 - Queue Processes Reliably Without Duplication (Priority: P1)

A user starts the queue, navigates to settings, then navigates back to the home screen. The queue continues processing the same jobs without restarting, duplicating, or losing track of progress. Only one processing loop ever runs at a time, regardless of navigation.

**Why this priority**: Without this fix, navigating the app can spawn duplicate processing loops, causing concurrent transfers of the same 50-100 GB files.

**Independent Test**: Start the queue with 2 jobs. Navigate to settings and back. Verify only one job is being processed, not duplicated. Check that progress is consistent.

**Acceptance Scenarios**:

1. **Given** the queue is processing, **When** the user navigates away and returns to the home screen, **Then** the queue state (running/stopped) is preserved and reflected accurately
2. **Given** the queue is processing, **When** a second "start" request is made, **Then** it is ignored (no duplicate processing)
3. **Given** the queue is stopped, **When** the user navigates away and returns, **Then** the stopped state is preserved

---

### User Story 3 - Transferred Files Are Actually Verified (Priority: P1)

After each file is copied from the SD card to the destination, the system verifies the copy by comparing file sizes. The file is only marked as "verified" if the sizes match. If verification fails, the file is marked as failed with a clear error. The Slack notification reports the actual verification result, not a hardcoded "Passed."

**Why this priority**: Without actual verification, corrupted transfers go undetected. The user may erase their SD card based on false "verified" status, losing their only copy of the footage.

**Independent Test**: Transfer a file. Verify that the file's "verified" flag reflects an actual size comparison. Intentionally corrupt a copy and verify that verification catches it.

**Acceptance Scenarios**:

1. **Given** a file transfer completes, **When** the source and destination file sizes match, **Then** the file is marked as verified
2. **Given** a file transfer completes, **When** the sizes do not match, **Then** the file is marked as failed with error "Verification failed: size mismatch"
3. **Given** a transfer job completes with all files verified, **When** a Slack notification is sent, **Then** it reports "Verification: Passed" based on actual checks
4. **Given** a transfer job completes with one file that failed verification, **When** a Slack notification is sent, **Then** it reports the verification failure

---

### User Story 4 - Job Status Accurately Reflects Outcome (Priority: P2)

When a compression job finishes but some files failed, the job is marked with a status that reflects the partial failure — not "completed." When a user stops the queue mid-job, the interrupted job is marked as paused, not completed. In both cases, the user can later resume or retry.

**Why this priority**: False "completed" status hides failures and prevents recovery. Users trust the status to decide whether their files are safe.

**Independent Test**: (a) Run a compression job where one file fails. Verify the job status reflects partial failure. (b) Start a transfer job and stop the queue mid-file. Verify the job is marked as paused, not completed.

**Acceptance Scenarios**:

1. **Given** a compression job processes 10 files and 3 fail, **When** the job finishes, **Then** the job status indicates partial failure with a message like "7/10 files compressed, 3 failed"
2. **Given** the user stops the queue during a transfer job, **When** processing pauses, **Then** the job is marked as "paused" (not "completed")
3. **Given** a paused job exists, **When** the user restarts the queue, **Then** the paused job resumes from where it left off
4. **Given** a job with partial failures exists, **When** the user views job details, **Then** they can see which specific files failed and why

---

### User Story 5 - File Paths Work Correctly on Windows (Priority: P2)

When compression jobs create output file paths (particularly in auto-chain scenarios), the paths use proper Windows conventions. Files are saved to the correct location without errors caused by malformed paths.

**Why this priority**: Incorrect path separators cause files to be saved in wrong locations or not at all on the target Windows platform.

**Independent Test**: Create a transfer-and-compress job. Verify the compression output files land in the expected directory with correct file names.

**Acceptance Scenarios**:

1. **Given** a transfer-and-compress job completes the transfer phase, **When** the compression job is auto-created, **Then** the output file paths use proper path construction
2. **Given** a compression output path is `D:\Videos\Compressed`, **When** a file named `clip01.mov` is compressed, **Then** the output is `D:\Videos\Compressed\clip01.mov` (not `D:\Videos\Compressed/clip01.mov`)

---

### Edge Cases

- What happens if the source drive contains zero video files when a job is created?
- What happens if a file is deleted from the source between job creation and processing?
- What happens if verification fails on every file in a transfer job?
- What happens if the queue is stopped and the app is closed — does the paused state persist across restarts?
- What happens if a chained compression job is created but the transfer had some failed files?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST scan the source path for video files (.MOV, .MP4) at job creation time and record each file in the job's file tracking
- **FR-002**: System MUST populate the job's total file count and total byte count based on the enumerated files
- **FR-003**: System MUST reject job creation (with user feedback) if no video files are found in the source path
- **FR-004**: System MUST ensure only one queue processing loop runs at any time, regardless of UI navigation
- **FR-005**: System MUST preserve queue state (running/stopped) across screen transitions
- **FR-006**: System MUST verify each transferred file by comparing source and destination file sizes after copy
- **FR-007**: System MUST only mark a file as "verified" if actual verification was performed and passed
- **FR-008**: System MUST report actual verification results in Slack notifications (not hardcoded)
- **FR-009**: System MUST mark a job as failed (with descriptive error) when compression completes with some files failing
- **FR-010**: System MUST mark a job as "paused" (not "completed") when the user stops the queue mid-processing
- **FR-011**: System MUST resume paused jobs from the next unprocessed file when the queue restarts
- **FR-012**: System MUST use proper platform-aware path construction for all file path operations

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of transfer jobs result in actual files being copied to the destination (zero no-op jobs)
- **SC-002**: Zero duplicate processing events — only one job processes at a time under all navigation scenarios
- **SC-003**: 100% of transferred files have a verification result based on actual size comparison
- **SC-004**: Job status accurately reflects outcome in 100% of cases (no false "completed" for partial failures or interrupted jobs)
- **SC-005**: All file paths are valid on Windows — zero path-related errors in transfer or compression

## Assumptions

- These fixes apply to the existing codebase and do not change the app's architecture or UI layout
- File size comparison is sufficient for transfer verification (checksum verification is a future enhancement)
- The "paused" status uses the existing `JobStatus.paused` enum value already defined in the data model
- Auto-chained compression jobs should only include files that were successfully transferred and verified
