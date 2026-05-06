# Tasks: Test Card Preparation

**Input**: Design documents from `specs/012-test-card-prep/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No automated tests — manual testing on Windows 11.

**Organization**: Small feature — no foundational phase needed. All tasks are one user story.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: User Story 1 — Prep Test Cards (Priority: P1) 🎯

**Goal**: One-click button in settings that preps all inserted SD cards with test video files.

**Independent Test**: Insert 2+ cards. Click "Prep Test Cards." Select folder with test .mp4 files. Verify each card gets `DCIM/100TEST/` with the files.

### Implementation

- [x] T001 [US1] Add `prepTestCards(String sourceFolder, List<DetectedDrive> drives)` method to `lib/services/drive_service.dart`. For each drive: delete `DCIM/100TEST/` if exists, create it fresh, scan source folder for .mov/.mp4 files, copy each via `File.copy()`. Return `({int cardsPrepped, int filesCopied, List<String> errors})`. Wrap per-card operations in try/catch to continue on failure.
- [x] T002 [US1] Add "Testing" section with "Prep Test Cards" button to `lib/ui/screens/settings_screen.dart`. Add `_prepTestCards()` method: detect drives (show error if none), open folder picker (return if cancelled), scan for video files (show error if none), call `driveService.prepTestCards()`, show results dialog with cards prepped / files copied / errors.

---

## Phase 2: Polish

- [x] T003 Run `flutter analyze` to verify zero errors
- [x] T004 Update feature table in `CLAUDE.md`

---

## Dependencies & Execution Order

- T001 before T002 (service method before UI)
- T003-T004 after T001-T002

## Notes

- No schema changes — purely UI + service method
- No new files — modifications to 2 existing files
- Total: 4 tasks
