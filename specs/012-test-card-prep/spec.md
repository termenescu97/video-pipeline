# Feature Specification: Test Card Preparation

**Feature Branch**: `012-test-card-prep`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Add a Prep Test Cards utility that automates setting up SD cards with small test video files for QA testing"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prep all inserted cards with one click (Priority: P1)

The operator inserts 3 SD cards into the Kingston hub, opens settings, and clicks "Prep Test Cards." They pick a folder containing small test video files. The app detects all 3 cards, creates a `DCIM/100TEST/` folder on each, and copies the test files onto every card. A summary shows "Prepped 3 cards with 2 test files each."

**Why this priority**: This is the entire feature — one-click card prep eliminates minutes of manual file copying across multiple cards.

**Independent Test**: Insert 2+ SD cards. Click "Prep Test Cards." Select a folder with test .mp4 files. Verify each card has a `DCIM/100TEST/` folder with the test files copied onto it.

**Acceptance Scenarios**:

1. **Given** 3 SD cards are inserted and a source folder with 2 test .mp4 files is selected, **When** the operator clicks "Prep Test Cards," **Then** all 3 cards receive a `DCIM/100TEST/` folder containing both test files.
2. **Given** a card already has real footage in `DCIM/100CANON/`, **When** test prep runs, **Then** the existing footage is untouched — only `DCIM/100TEST/` is added alongside it.
3. **Given** no removable drives are detected, **When** the operator clicks "Prep Test Cards," **Then** a message says "No removable drives detected."
4. **Given** the source folder is empty or contains no video files, **When** the operator selects it, **Then** a message says "No video files found in the selected folder."

---

### User Story 2 - Choose which test files to use (Priority: P2)

The operator has downloaded a few short video clips for testing. They pick the folder containing these clips using a standard folder picker. The app finds all .mov and .mp4 files in that folder and copies them to every detected card.

**Why this priority**: Different test scenarios may need different files — the operator should be able to choose rather than relying on a hardcoded location.

**Independent Test**: Place 3 .mp4 files in a folder. Select that folder during prep. Verify all 3 files are copied to each card.

**Acceptance Scenarios**:

1. **Given** the operator selects a folder with 3 .mp4 files, **When** prep runs, **Then** all 3 files are copied to each card's `DCIM/100TEST/` folder.
2. **Given** the operator cancels the folder picker, **When** the dialog closes, **Then** no prep action is taken.
3. **Given** the selected folder contains a mix of .mp4 and non-video files, **When** prep runs, **Then** only .mp4 and .mov files are copied.

---

### User Story 3 - See prep results clearly (Priority: P2)

After prep completes, the operator sees a clear summary of what happened — how many cards were prepped, how many files were copied to each, and any errors (e.g., a card was read-only).

**Why this priority**: Without feedback, the operator doesn't know if prep succeeded or which cards were affected.

**Independent Test**: Prep 3 cards. Verify a dialog shows "Prepped 3 cards with 2 test files each (total: 6 files copied)."

**Acceptance Scenarios**:

1. **Given** prep completes successfully on 3 cards with 2 files each, **When** the result is shown, **Then** the operator sees "Prepped 3 cards with 2 test files each."
2. **Given** one card fails (e.g., write-protected), **When** results are shown, **Then** the failed card is listed with the error reason.

---

### Edge Cases

- What happens when a card already has a `DCIM/100TEST/` folder from a previous prep? Overwrite the existing test files (replace with fresh copies).
- What happens when the test files total more than the card's free space? Show an error for that card and skip it.
- What happens when a card is removed mid-prep? The copy fails for that card; show the error and continue with remaining cards.
- What happens on non-Windows (development on macOS)? The feature is only available on Windows where real SD cards are detected. On macOS, show "Not available on this platform."

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The settings screen MUST provide a "Prep Test Cards" button that initiates the test card preparation workflow.
- **FR-002**: The system MUST detect all currently inserted removable drives using the existing drive detection mechanism.
- **FR-003**: The system MUST prompt the operator to select a source folder containing test video files using the native folder picker.
- **FR-004**: The system MUST create a `DCIM/100TEST/` folder on each detected card and copy all .mov and .mp4 files from the source folder into it.
- **FR-005**: The system MUST NOT delete or modify any existing files on the cards — test files are added alongside existing content.
- **FR-006**: The system MUST show a summary after completion indicating how many cards were prepped, how many files were copied, and any errors encountered.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All inserted cards are prepped with test files in under 30 seconds (for ~200MB of test data across 3-4 cards).
- **SC-002**: Existing card content is never modified or deleted during prep.
- **SC-003**: The operator can go from "insert cards" to "ready to test full pipeline" in under 1 minute.
- **SC-004**: Errors on individual cards are reported without blocking other cards from being prepped.

## Assumptions

- The operator has pre-downloaded test video files (e.g., short clips from YouTube) into a folder on the local machine.
- The `DCIM/100TEST/` folder name is fixed — no need to customize it.
- If `DCIM/100TEST/` already exists on a card, its contents are replaced with the new test files.
- The feature is Windows-only (matching the app's target platform). On macOS development, it's hidden or shows a platform warning.
- The source folder selection does not need to persist across sessions — the operator picks it each time.
