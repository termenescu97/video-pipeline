# Tasks: SHA-256 File Verification

**Input**: Design documents from `specs/011-sha256-verification/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No automated tests — manual testing on Windows 11 per project convention.

**Organization**: Tasks grouped by user story. Schema migration is foundational (blocks all user stories).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Foundational — Schema Migration v4→v5

**Purpose**: Add VerificationMode enum, `verificationMode` column to Jobs, `sourceHash`/`destinationHash` columns to JobFiles. Regenerate Drift code.

- [x] T001 Add `enum VerificationMode { size, sha256 }` to `lib/database/tables.dart`
- [x] T002 Add `verificationMode` textEnum column (default `size`) to `Jobs` table in `lib/database/tables.dart`
- [x] T003 Add nullable `sourceHash` and `destinationHash` text columns to `JobFiles` table in `lib/database/tables.dart`
- [x] T004 Bump `schemaVersion` to 5 in `lib/database/database.dart`. Add migration: `if (from < 5)` adding `verificationMode` to jobs and `sourceHash`/`destinationHash` to jobFiles
- [x] T005 Add `VerificationModeX` extension to `lib/database/extensions.dart` with `label` getter ("Quick (size)" / "Full (SHA-256)") and `icon` getter
- [x] T006 Run `dart run build_runner build` to regenerate Drift code for schema v5

**Checkpoint**: Schema v5 compiles. `flutter analyze` passes. New enum and columns available.

---

## Phase 2: User Story 1 — Verification mode toggle in job creation (Priority: P1) 🎯 MVP

**Goal**: Operator can choose between Quick and Full verification when creating a transfer job.

**Independent Test**: Open job creation form for a transfer job. Verify SegmentedButton appears with "Quick (size)" selected by default. Select "Full (SHA-256)." Create job. Verify job record has `verificationMode: sha256`.

### Implementation for User Story 1

- [x] T007 [US1] Add `VerificationMode _verificationMode = VerificationMode.size` state field and a `SegmentedButton<VerificationMode>` to `lib/ui/screens/create_job_screen.dart`, visible only when `_jobType != JobType.compression`. Place it after the preset selector section.
- [x] T008 [US1] Pass `_verificationMode` to `JobsCompanion.insert()` in `_createJobInner()` in `lib/ui/screens/create_job_screen.dart` via the new `verificationMode` field.

**Checkpoint**: Toggle visible for transfer jobs, hidden for compression-only. Selection stored on job record.

---

## Phase 3: User Story 2 — SHA-256 hash computation and verification (Priority: P1)

**Goal**: After robocopy transfers a file, if SHA-256 mode, compute and compare hashes of source and destination.

**Independent Test**: Create a transfer job with SHA-256 mode. Run it. Verify hashes are computed for each file. Verify matching hashes mark file as verified. Verify mismatching hashes mark file as failed.

### Implementation for User Story 2

- [x] T009 [US2] Add `Future<String?> computeFileHash(String filePath)` method to `lib/services/transfer_service.dart`. On Windows: run `powershell -NoProfile -Command "(Get-FileHash -Path '$filePath' -Algorithm SHA256).Hash"`, parse stdout. On non-Windows: return null.
- [x] T010 [US2] Add `Future<void> updateFileHashes(int fileId, {String? sourceHash, String? destinationHash})` method to `lib/database/daos/job_file_dao.dart`.
- [x] T011 [US2] In `lib/services/job_queue_service.dart` `_processTransfer()`, after successful file transfer: check `job.verificationMode`. If `sha256`, call `computeFileHash(source)` and `computeFileHash(destination)`, compare hashes. Store via `updateFileHashes()`. If match: `markFileCompleted(verified: true)`. If mismatch: `markFileFailed('SHA-256 hash mismatch')`. If `size` mode: keep existing size verification flow unchanged.
- [x] T012 [US2] Update `progressNotifier` during hashing in `lib/services/job_queue_service.dart` — set `currentFileName` to "Verifying: hashing source..." then "Verifying: hashing destination..." so the UI shows hashing progress.

**Checkpoint**: SHA-256 verification runs after transfer. Matches pass, mismatches fail. Size verification unchanged.

---

## Phase 4: User Story 3 — Hash progress, display, and Slack (Priority: P2)

**Goal**: Operator sees hashing progress, can view stored hashes per file, and Slack notifications mention verification method.

**Independent Test**: Run SHA-256 job. Verify progress shows "Hashing source/destination." View file list — verify shield icon on verified files, tap to see hashes. Check Slack says "SHA-256 — Passed."

### Implementation for User Story 3

- [x] T013 [US3] In `lib/ui/screens/job_detail_screen.dart`, update the file list builder: if `file.sourceHash != null`, show a shield icon (`Icons.verified_user`) next to the file status icon. Wrap the `ListTile` in an `ExpansionTile` that reveals source and destination hashes in a monospace `Text` widget when expanded.
- [x] T014 [US3] In `lib/services/slack_service.dart` `notifyTransferCompleted()`, check `job.verificationMode`. If `sha256`: append "Verification: SHA-256 — Passed" or "SHA-256 — FAILED ($failedCount mismatches)". If `size`: keep existing "Verification: Passed/FAILED" text.

**Checkpoint**: Hashing visible in progress bar. Hashes viewable per file. Slack shows verification method.

---

## Phase 5: User Story 4 — Hash results in log (Priority: P2)

**Goal**: Log file contains SHA-256 hash details for every verified file.

**Independent Test**: Run SHA-256 job. Open log. Verify entries with both hashes and MATCH/MISMATCH.

### Implementation for User Story 4

- [x] T015 [US4] In `lib/services/job_queue_service.dart`, after SHA-256 verification of each file, log via `_logService`: `"File {fileName} — SHA-256 verified: source={hash} dest={hash} MATCH"` or `"MISMATCH"`. For size-verified files, keep existing log behavior unchanged.

**Checkpoint**: Log contains full hash audit trail for SHA-256 jobs.

---

## Phase 6: Batch Copy Support

**Goal**: Batch "Copy All Cards" supports verification mode toggle.

**Independent Test**: Click "Copy All Cards." Verify verification mode toggle appears. Select SHA-256. Create batch. Verify all jobs have SHA-256 mode.

### Implementation

- [x] T016 Add verification mode `SegmentedButton` to the batch copy flow in `lib/ui/screens/home_screen.dart`. Show the toggle in a dialog before the folder picker in `_batchCopyAllCards()`. Pass selected mode to `createBatchTransferJobs()`.
- [x] T017 Update `createBatchTransferJobs()` signature in `lib/services/job_queue_service.dart` to accept `VerificationMode verificationMode` parameter (default: `VerificationMode.size`). Pass to each `JobsCompanion.insert()`.

**Checkpoint**: Batch jobs created with selected verification mode.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T018 Run `flutter analyze` to verify zero analysis errors across all modified files
- [x] T019 Update feature table and known issues in `CLAUDE.md` to reflect 011 completion

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Foundational)**: Must complete first — schema v5 + codegen
- **Phase 2 (US1)**: Depends on Phase 1 — needs VerificationMode enum and column
- **Phase 3 (US2)**: Depends on Phase 2 — needs toggle to set mode on jobs
- **Phase 4 (US3)**: Depends on Phase 3 — needs hashes stored to display them
- **Phase 5 (US4)**: Depends on Phase 3 — needs hash computation to log results
- **Phase 6 (Batch)**: Depends on Phase 1 — independent of US1-US4
- **Phase 7 (Polish)**: Depends on all phases complete

### Sequential Flow

```
Phase 1 (Schema) → Phase 2 (US1: Toggle) → Phase 3 (US2: Hash engine) → Phase 4 (US3: UI + Slack)
                                                                        → Phase 5 (US4: Logging)
                 → Phase 6 (Batch support)
                                          ──────────────────────────────→ Phase 7 (Polish)
```

### Parallel Opportunities

- T001-T003 can run in parallel (different sections of tables.dart, but same file — do sequentially)
- Phase 4 (US3) and Phase 5 (US4) can run in parallel after Phase 3
- Phase 6 can run in parallel with Phases 2-5 (only needs Phase 1)

---

## Implementation Strategy

### MVP First (User Stories 1-2 Only)

1. Complete Phase 1 (schema migration)
2. Complete Phase 2 (verification toggle)
3. Complete Phase 3 (hash computation + comparison)
4. **STOP and VALIDATE**: Create a transfer job with SHA-256 mode, verify hashes computed and compared
5. Proceed to UI polish (Phase 4-5), batch (Phase 6), polish (Phase 7)

### Recommended Sequential Order (Solo Developer)

1. **Phase 1**: Schema v5 + codegen
2. **Phase 2**: Toggle in create_job_screen
3. **Phase 3**: Hash engine in transfer_service + verification in job_queue_service
4. **Phase 4**: UI display + Slack notifications
5. **Phase 5**: Log entries
6. **Phase 6**: Batch support
7. **Phase 7**: Analyze + docs

---

## Notes

- No new files — all modifications to existing code
- Schema migration v4→v5 required (3 new columns + 1 enum)
- `Get-FileHash` output format: single line with hash string, parseable via stdout
- Total: 19 tasks across 7 phases
- Existing size verification is completely untouched — SHA-256 is additive
