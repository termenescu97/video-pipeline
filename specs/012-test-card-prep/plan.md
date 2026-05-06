# Implementation Plan: Test Card Preparation

**Branch**: `012-test-card-prep` | **Date**: 2026-05-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/012-test-card-prep/spec.md`

## Summary

Add a "Prep Test Cards" button to the settings screen that detects all inserted SD cards, prompts for a source folder of test videos, creates `DCIM/100TEST/` on each card, and copies the test files. Simple utility — no schema changes, no new services, just a method on settings_screen + DriveService helper.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (3.41.9)
**Storage**: No database changes
**Target Platform**: Windows 11 (Windows-only feature)
**Scale/Scope**: 2 files modified, ~60 lines of new code

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | PASS | Operator initiates prep, picks source folder |
| II. Single Codebase | PASS | All Dart |
| III. Resilient Pipeline | PASS | Enables testing of the pipeline |
| IV. Minimal Complexity | PASS | Uses File.copy(), no subprocess needed |
| V. Observable Progress | PASS | Shows summary results |
| VI. Update Transparency | PASS | No changes |

## Changes

### settings_screen.dart
- Add "Prep Test Cards" button in a new "Testing" section at the bottom
- `_prepTestCards()` method:
  1. Call `driveService.getRemovableDrives()` — show error if empty
  2. Open folder picker for source files
  3. Scan source folder for .mov/.mp4 files — show error if empty
  4. For each drive: create `DCIM/100TEST/`, copy all test files via `File.copy()`
  5. Show results dialog with per-card summary

### drive_service.dart
- Add `Future<({int cardsPrepped, int filesCopied, List<String> errors})> prepTestCards(String sourceFolder, List<DetectedDrive> drives)` method
- Handles: folder creation, file copy, error collection per card
- If `DCIM/100TEST/` exists, delete and recreate

## Complexity Tracking

No constitution violations. No complexity tracking needed.
