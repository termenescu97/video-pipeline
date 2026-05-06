# Implementation Plan: SHA-256 File Verification

**Branch**: `011-sha256-verification` | **Date**: 2026-05-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/011-sha256-verification/spec.md`

## Summary

Add optional per-job SHA-256 hash verification alongside existing size comparison. After robocopy transfers a file, if SHA-256 mode is selected, compute hashes of source and destination via PowerShell `Get-FileHash`, compare, and store both hashes for audit. Includes verification mode toggle in job creation and batch copy flows, hashing progress in UI, hash display with expandable file rows, and updated Slack/log output. Requires schema v5 migration (1 new Jobs column + 2 new JobFiles columns).

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (3.41.9)
**Primary Dependencies**: Drift (SQLite ORM), PowerShell `Get-FileHash` (system tool)
**Storage**: SQLite via Drift (schema v4 → v5)
**Testing**: Manual testing on Windows 11
**Target Platform**: Windows 11 desktop
**Project Type**: Desktop app
**Performance**: SHA-256 hashing ~100 MB/s on USB 3.0 → ~8 min per 50GB file
**Constraints**: Sequential hashing (no parallel USB reads), Constitution IV compliance

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Human-in-the-Loop | PASS | Operator explicitly opts in to SHA-256 per job — not forced |
| II. Single Codebase | PASS | All Dart, delegates hashing to system tool |
| III. Resilient Pipeline | PASS (enhances) | SHA-256 provides stronger verification than size comparison |
| IV. Minimal Complexity | PASS | Uses `Get-FileHash` (system tool), not a custom hasher. Additive — doesn't change existing flow. |
| V. Observable Progress | PASS | Hashing phase shown in progress bar, results in UI + Slack + log |
| VI. Update Transparency | PASS | No changes |

## Project Structure

### Source Code (files to modify/create)

```text
lib/
├── database/
│   ├── tables.dart              # Add VerificationMode enum, verificationMode to Jobs, hashes to JobFiles
│   ├── database.dart            # Schema v5 migration
│   ├── extensions.dart          # Add VerificationMode extension (label, icon)
│   └── daos/job_file_dao.dart   # Add method to store hashes
├── services/
│   ├── job_queue_service.dart   # SHA-256 verification flow after transfer
│   ├── transfer_service.dart    # Add computeHash() method using Get-FileHash
│   └── log_service.dart         # Already exists — add hash log entries
├── ui/
│   ├── screens/
│   │   ├── create_job_screen.dart # Verification mode toggle
│   │   ├── home_screen.dart       # Batch copy verification toggle
│   │   └── job_detail_screen.dart # Expandable hash display on file rows
│   └── widgets/
│       └── (no new widgets)
└── utils/
    └── (no changes)
```

## Changes by User Story

### US1: Verification mode toggle in job creation

- `tables.dart`: Add `enum VerificationMode { size, sha256 }`, add `verificationMode` textEnum column to Jobs (default: `size`)
- `extensions.dart`: Add `VerificationModeX` extension with `label` getter ("Quick (size)" / "Full (SHA-256)")
- `create_job_screen.dart`: Add `SegmentedButton<VerificationMode>` below the preset selector (visible for transfer and transferAndCompress job types only). Store selection in `_verificationMode` state. Pass to `JobsCompanion.insert()`.

### US2: SHA-256 verification after transfer

- `transfer_service.dart`: Add `Future<String?> computeHash(String filePath)` method. On Windows: run `Get-FileHash -Path "$filePath" -Algorithm SHA256` via PowerShell, parse output. On non-Windows: return null (dev fallback).
- `job_queue_service.dart`: In `_processTransfer()`, after file transfer succeeds, check `job.verificationMode`. If `sha256`: call `computeHash(source)`, update progress notifier ("Hashing source..."), call `computeHash(destination)`, update notifier ("Hashing destination..."), compare hashes. Store both hashes on JobFile. Mark verified/failed based on match.
- `tables.dart`: Add `sourceHash` and `destinationHash` nullable text columns to JobFiles
- `database.dart`: Schema v5 migration adds all 3 columns
- `job_file_dao.dart`: Add `updateFileHashes(int fileId, String sourceHash, String destinationHash)` method

### US3: Hash progress + display + Slack

- `job_queue_service.dart`: Update `progressNotifier` during hashing with `currentFileName: "Verifying: hashing source..."` / `"Verifying: hashing destination..."`
- `job_detail_screen.dart`: In file list, check if `file.sourceHash != null`. If so, show a shield icon. Wrap file rows in `ExpansionTile` that reveals source and destination hashes in monospace text.
- `slack_service.dart`: In `notifyTransferCompleted()`, include verification method. If job has SHA-256 mode: "Verification: SHA-256 — Passed" or "SHA-256 — FAILED (X mismatches)". If size mode: "Verification: Passed" (existing behavior).

### US4: Hash results in log

- `job_queue_service.dart`: After each SHA-256 verification, log via `_logService`: "File {name} — SHA-256 verified: source={hash} dest={hash} MATCH/MISMATCH"

### Batch copy support

- `home_screen.dart`: In `_batchCopyAllCards()`, before the folder picker, show a dialog or inline toggle for verification mode. Pass selected mode to `createBatchTransferJobs()`.
- `job_queue_service.dart`: Update `createBatchTransferJobs()` signature to accept `VerificationMode` parameter, pass to each job insert.

## Complexity Tracking

No constitution violations. No complexity tracking needed.
