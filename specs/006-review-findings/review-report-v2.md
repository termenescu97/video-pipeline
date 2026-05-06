# Copiatorul3000 — Review Report v2 (QA + Product)

**Date**: 2026-05-06
**Version Reviewed**: v2.0.0
**Reviewers**: QA Tester Agent, Product Manager Agent

---

## Executive Summary

The app is architecturally solid but has several data-loss risks (duplicate filenames overwrite, verify-then-overwrite race, ungraceful shutdown), missing wiring (progress bar data never populated), and product gaps (no onboarding, no logging, no single-instance lock). The biggest adoption risk is that the progress bar shows less info than TeraCopy — the tool it replaces.

**Issues found**: 6 critical, 14 high/should-have, 10 medium/nice-to-have

---

## Critical (Data Loss / Crash)

### QA-1. Duplicate filenames from recursive listing overwrite at destination
**File**: `job_queue_service.dart`, `create_job_screen.dart`
Recursive file listing uses only `p.basename()` for destination. If `DCIM/100CANON/IMG_0001.MOV` and `DCIM/101CANON/IMG_0001.MOV` both exist, the second overwrites the first.
**Fix**: Preserve subdirectory structure at destination, or detect duplicates and append a suffix.

### QA-2. File marked completed then overwritten as failed
**File**: `job_queue_service.dart:131-143`
After transfer, `markFileCompleted(verified: verified)` is called first, then if `!verified`, `markFileFailed()` overwrites it. If the app crashes between the two writes, the file is stuck as "completed" with bad data.
**Fix**: Check verification result *before* calling either method. Call `markFileCompleted` only if verified, otherwise `markFileFailed` directly.

### QA-3. Process stdout/stderr streams not awaited before exitCode
**File**: `process_runner.dart:17-35`
`.listen()` is fire-and-forget. When `exitCode` completes, buffered stdout/stderr data may not have been fully processed. Final progress lines (including 100%) can be lost.
**Fix**: Use `await process.stdout.transform(...).forEach(...)` instead of `.listen()`, then await exitCode.

### QA-4. `exit(0)` in system tray kills app without cleanup
**File**: `shell_screen.dart:64`
No database flush, no process cancellation, no cleanup. Running robocopy becomes orphaned. In-flight DB write can corrupt.
**Fix**: Trigger graceful shutdown: stop queue, cancel subprocesses, close database, then exit.

### QA-5. `DropdownButtonFormField.initialValue` — compile error
**File**: `create_job_screen.dart:238`
`initialValue` is not a valid parameter. Should be `value`.
**Fix**: Change `initialValue:` to `value:`.

### QA-6. `createBatchTransferJobs` parameter is `List<dynamic>`
**File**: `job_queue_service.dart:239`
Casts `drive.path as String` at runtime. Crashes with `NoSuchMethodError` if types mismatch.
**Fix**: Change parameter type to `List<DetectedDrive>`.

---

## High / Should-Have

### PM-1. Progress bar data never wired from services to UI
**Files**: `transfer_service.dart`, `compression_service.dart`, `job_detail_screen.dart`
`PipelineProgressBar` accepts `currentFileName`, `eta`, `speedBytesPerSec`, `fps` — but `JobDetailScreen` never passes them. Users see percentage and file count only. **This is the #1 adoption risk** — TeraCopy shows speed/ETA out of the box.
**Fix**: Wire `transferService.onProgress` and `compressionService.onProgress` callbacks to update state that feeds into the progress bar.

### PM-2. No persistent local log file
Slack failures are silently swallowed. No local record of operations for debugging or auditing.
**Fix**: Write a `copiatorul3000.log` file with timestamps for every significant event.

### PM-3. No single-instance lock
Two app instances share the same SQLite file, causing lock contention and potential corruption.
**Fix**: Add a lock file check on startup. If another instance is running, show error and exit.

### PM-4. No banner when Slack webhook not configured
Users create jobs and start the queue, wondering why no Slack messages arrive.
**Fix**: Show a persistent banner on the home screen when webhook URL is empty.

### PM-5. No first-run onboarding
User lands on an empty queue with no guidance. No prompt to configure Slack. No explanation of what to do.
**Fix**: Add a 3-step first-run wizard or overlay.

### QA-7. `startProcessing()` race condition
Not atomic — rapid double-calls can start two processing loops on the same job.
**Fix**: Use a `Completer` or set `_isProcessing = true` synchronously before any `await`.

### QA-8. Chained compression job missing `totalFiles`/`totalBytes`
`_createChainedCompressionJob` inserts files but never calls `updateJobTotals`. Progress shows 0/0.
**Fix**: Add `updateJobTotals` call after inserting compression files.

### QA-9. Compression preset validation missing in `_canCreate()`
User can create a compression job with no preset selected. Empty string passed to HandBrakeCLI.
**Fix**: Add `if (_jobType != JobType.transfer && _selectedPreset == null) return false;`

### QA-10. Reorder indices from filtered list don't match DAO's full list
`SliverReorderableList` passes indices from `activeJobs` but `reorderJobs` queries all jobs. Wrong job gets moved.
**Fix**: Pass job IDs to the reorder method instead of indices.

### QA-11. Retry doesn't reset `completedFiles`/`completedBytes` counters
After retry, progress bar starts from the previous value.
**Fix**: Add `completedFiles: const Value(0), completedBytes: const Value(0)` to `resetJobForRetry`.

### QA-12. Context menu "Retry" has no handler
`job_card.dart` context menu handles `'details'` and `'delete'` but not `'retry'`.
**Fix**: Add retry handler via callback or direct DAO call.

### QA-13. `watchSettings()` / `getSettings()` crash if settings row missing
Uses `watchSingle()` / `getSingle()` which throw if 0 rows.
**Fix**: Use `watchSingleOrNull()` / `getSingleOrNull()` with fallback.

### QA-14. No filesystem error handling in `listVideoFiles`
`dir.list(recursive: true)` throws on access-denied directories or card removal mid-scan.
**Fix**: Wrap in try/catch or use `.handleError()` on the stream.

---

## Medium / Nice-to-Have

### PM-6. No "last used destination" memory
Most common destination should auto-fill. Favorites require manual saving.
**Fix**: Remember last-used destination, pre-fill on next session.

### PM-7. No operator name tracking
Team lead can't tell who copied what.
**Fix**: Add configurable "Operator Name" in settings, stamp on jobs and Slack messages.

### PM-8. No exportable report (CSV)
No way to pull a report of "all transfers this week."
**Fix**: Add "Export History" button that generates CSV.

### PM-9. No timestamps on history cards
Job cards in history don't show when they ran.
**Fix**: Show relative timestamps ("2 hours ago") on history cards.

### PM-10. Selective file copy
Currently copies ALL video files. Can't exclude B-roll or select specific clips.
**Fix**: Add file selection UI in job creation.

### QA-15. `githubRepo` is a placeholder
`'YOUR_ORG/video-pipeline'` — update check silently 404s.
**Fix**: Replace with `'termenescu97/video-pipeline'`.

### QA-16. Duplicate filenames in `_saveAsFavorite` path split
Uses `path.split(r'\').last` — fails on non-Windows paths during development.
**Fix**: Use `p.basename(path)`.

### QA-17. `eraseDrive` regex rejects lowercase drive letters
`^[A-Z]:\\$` — user input could be lowercase.
**Fix**: Change to `^[A-Za-z]:\\$` or normalize with `.toUpperCase()`.

### QA-18. Windows 260-char path limit not checked
Long destination + filename can exceed MAX_PATH, causing silent robocopy failure.
**Fix**: Check total path length and warn, or use `\\?\` prefix.

### QA-19. `formatBytes` returns "0 B" for negative values
`getDiskFreeSpace` returns -1 on failure, displayed as "0 B".
**Fix**: Return "N/A" for negative values.

---

---

## v3.0 Roadmap Suggestions

### Tier 1 — Transform from utility to indispensable tool

| Feature | Description | Impact |
|---------|-------------|--------|
| **NAS upload automation** | Add an "Upload to NAS" job type or auto-chain step. The team's workflow doesn't end at compression — it ends when files are on the NAS and accessible to editors. Closing this last mile makes the app the single source of truth for the entire post-shoot pipeline. | Eliminates the last manual step |
| **Auto-detect new SD cards** | Background watcher that detects new removable drives and shows a system tray notification: "New card detected: CANON_A7 (64GB). Copy now?" One click from notification to queued job. | Removes the need to manually open app and refresh |
| **Dashboard with stats** | "This week: 1.2 TB copied, 847 GB compressed, 14 cards processed, average 23 min per card." Gives the team lead visibility without digging through Slack history. | Accountability and planning |
| **SHA-256 checksum verification** | Move beyond file-size comparison. For a team whose livelihood depends on this footage, hash-based verification provides the confidence to erase cards without anxiety. | Trust and data safety |

### Tier 2 — Delight and efficiency

| Feature | Description | Impact |
|---------|-------------|--------|
| **Job templates** | Save and reuse configurations. "Friday shoot preset: all cards to D:\Footage\[date], compress with H.265 Medium, output to D:\Compressed\[date]." One click to replicate yesterday's setup. | Eliminates repetitive configuration |
| **Scheduled jobs** | "Every day at 6 PM, check for new cards and start copying." Useful if the team has a consistent end-of-day routine. | Fully hands-off daily workflow |
| **Multi-machine sync** | Share job history, favorites, and settings across workstations via a shared database on the NAS. | Scales to multi-workstation teams |
| **Selective file copy** | Let users preview and select which files to copy from a card, rather than all-or-nothing. Useful when B-roll is mixed with A-camera on the same card. | Flexibility for mixed-content cards |
| **Editing tool integration** | Auto-create a project folder structure (Footage/Audio/Proxy) and optionally generate proxy files for editors to start working while full-res compression runs. | Bridges the gap between ingest and editing |

### Tier 3 — Long-term differentiation

| Feature | Description | Impact |
|---------|-------------|--------|
| **Cloud backup integration** | Optional upload to Google Drive, Dropbox, or Backblaze B2 as a third copy (3-2-1 backup rule). | Disaster recovery |
| **Metadata extraction and tagging** | Read EXIF/video metadata (camera model, date, duration, resolution) and display it in the file list. Enable searching history by camera, date, or resolution. | Searchable archive |
| **Team activity feed** | A shared view (web dashboard or Slack channel bot) showing real-time status across all workstations. "Station 1: copying Card 3/4. Station 2: compressing batch from yesterday." | Multi-station visibility |

---

## Summary

| Priority | Count | Key Themes |
|----------|-------|------------|
| **Critical** | 6 | Duplicate file overwrite, verify race, stream await, ungraceful exit, compile error, type safety |
| **High** | 14 | Progress not wired, no logging, no instance lock, no onboarding, race conditions, missing validation |
| **Medium** | 10 | No last-used destination, no operator tracking, no CSV export, path validation gaps |
| **Roadmap** | 12 | NAS upload, auto-detect cards, dashboard, checksums, templates, multi-machine, cloud backup |
| **Total** | **42** | |
