# Video Pipeline — Code & UX Review Report

**Date**: 2026-05-06
**Version Reviewed**: v1.1.0
**Reviewers**: Senior Architect Agent, UI/UX Specialist Agent

---

## Executive Summary

The app scaffolding and architecture are sound — Flutter/Dart single codebase, Drift for persistence, reactive UI via StreamBuilder, clean service layer. However, a critical bug means the pipeline currently does nothing (jobs are created with zero files), and several UX gaps make the app feel like a developer prototype rather than a tool for non-technical video editors.

**Issues found**: 7 critical, 16 important, 13 nice-to-have

---

## Critical Issues

### C1. Jobs Created With Zero Files — Pipeline Is a No-Op

**Source**: Architecture Review
**Files**: `lib/ui/screens/create_job_screen.dart`, `lib/services/job_queue_service.dart`

`_createJob()` inserts a job row but never enumerates video files from the source path or populates the `JobFiles` table. The queue service then processes an empty file list and immediately marks the job as "completed" having done nothing. The entire transfer and compression pipeline is inoperative.

**Impact**: The app does not work. Every job completes instantly without copying or compressing anything.

**Recommendation**: After inserting the job, enumerate video files from the source path using `DriveService.listVideoFiles()`, insert them into `JobFiles` via `JobFileDao.insertFiles()`, and update the job's `totalFiles` and `totalBytes` counts.

---

### C2. Multiple JobQueueService Instances — Race Condition

**Source**: Architecture Review
**Files**: `lib/ui/screens/home_screen.dart`

Every time `HomeScreen` is created (including after navigation), a new `JobQueueService` is instantiated with its own `_isProcessing` state. If the user navigates away and back, two instances could process the same job concurrently, causing duplicate transfers of 50-100 GB files.

**Impact**: Data corruption, wasted disk space, duplicate multi-hour operations.

**Recommendation**: Make `JobQueueService` a singleton — either via a global instance, a service locator like `get_it`, or `Provider`/`InheritedWidget`. The same applies to `TransferService`, `CompressionService`, `SlackService`, and `DriveService`.

---

### C3. Transfer Verification Never Called

**Source**: Architecture Review
**Files**: `lib/services/transfer_service.dart`, `lib/services/job_queue_service.dart`, `lib/services/slack_service.dart`

`TransferService.verifyTransfer()` exists but is never invoked. In `_processTransfer`, `markFileCompleted` is called with `verified: true` without actually verifying. The Slack notification unconditionally reports "Verification: Passed."

**Impact**: Corrupted transfers of 50-100 GB video files go undetected. The user may erase the SD card based on a false "verified" status, losing their only copy.

**Recommendation**: After each file transfer, call `verifyTransfer()` before marking the file as completed. Pass the actual result to `markFileCompleted`. Consider checksum verification (MD5/SHA256) for higher confidence beyond just file size comparison.

---

### C4. No "Copy All Cards" Batch Action

**Source**: UX Review
**Files**: `lib/ui/screens/home_screen.dart`, `lib/ui/screens/create_job_screen.dart`

The primary use case is: video team comes back from a shoot with multiple SD cards and wants to copy them all. Currently, they must create one job per card manually — select drive, pick destination, repeat. There is no quick action to batch-create jobs for all detected cards.

**Impact**: The most common workflow is unnecessarily tedious. The team came from a process where they "queue them all up in TeraCopy" — our app should be at least as fast.

**Recommendation**: Add a "Copy All Cards" button on the home screen (or a "Quick Copy" wizard) that detects all removable drives, lets the user pick a destination once, and creates one transfer job per card.

---

### C5. No Disk Space Indicator

**Source**: UX Review
**Files**: `lib/ui/screens/create_job_screen.dart`, `lib/ui/screens/home_screen.dart`

Users copy to an external 14TB HDD. There is no indication of available space on the destination drive. They discover "disk full" only when the transfer fails partway through a 100 GB file.

**Impact**: Failed transfers, wasted time, frustration.

**Recommendation**: Show destination drive free space next to the folder picker in the Create Job screen. Warn if the estimated source size exceeds available space. Optionally show a persistent disk space bar on the home screen.

---

### C6. No Retry Button for Failed Jobs

**Source**: UX Review
**Files**: `lib/ui/screens/job_detail_screen.dart`

When a job fails, the detail screen shows the error but offers no way to retry. The user must delete the failed job and create a new one from scratch. Since per-file status is already tracked, resuming from the last incomplete file should be straightforward.

**Impact**: Dead-end in the workflow. Failures become high-friction events.

**Recommendation**: Add a "Retry" button on the job detail screen for failed jobs. Reset the job status to `queued` and failed files to `pending`, then let the queue pick it up again.

---

### C7. No Time Estimates or Transfer Speed

**Source**: UX Review
**Files**: `lib/ui/widgets/progress_bar.dart`, `lib/ui/screens/job_detail_screen.dart`

The progress bar shows "X / Y files" and a percentage, but no estimated time remaining, elapsed time, or transfer speed. For 50-100 GB files, "how much longer?" is the most important question. HandBrakeCLI already outputs ETA and FPS which we parse but never display.

**Impact**: Users can't plan their time or know if something is stuck.

**Recommendation**: Add ETA, elapsed time, and transfer speed (MB/s) to the progress bar. For compression, display FPS and ETA from HandBrake's output. Pass `currentFileName` to the progress bar widget (the parameter exists but is never populated).

---

## Important Issues

### I1. No Subprocess Cancellation

**Source**: Architecture Review
**Files**: `lib/services/transfer_service.dart`, `lib/services/compression_service.dart`, `lib/services/job_queue_service.dart`

When `stopProcessing()` is called, it sets `_isProcessing = false` and the loop checks this between files. But if a robocopy or HandBrakeCLI process is currently running, it runs to completion — potentially hours for a 100 GB file. There is no way to kill the running subprocess.

**Impact**: "Stop Queue" appears broken — nothing happens until the current multi-hour operation finishes.

**Recommendation**: Store the `Process` reference in each service and expose a `cancel()` method that calls `process.kill()`. Wire `stopProcessing()` to invoke these cancel methods. Mark the interrupted file as `paused` rather than `failed`.

---

### I2. Erase Button Not Gated on Actual Verification

**Source**: Architecture Review
**Files**: `lib/ui/screens/job_detail_screen.dart`

The "Erase SD Card" button appears whenever a transfer job is completed, but there is no check that files were actually verified (and per C3, verification is never performed). Additionally, the confirmation dialog shows only the drive path, not the drive label or serial — if the SD card was removed and a different drive was mounted at the same letter, the wrong drive could be erased.

**Impact**: Data loss risk — the most dangerous operation in the app.

**Recommendation**: (1) Gate the erase button on ALL files having `verified == true` with actual verification performed. (2) Re-verify the drive identity before erasing (check volume label, size). (3) Show drive label and size in the confirmation dialog. (4) Move the erase button to the bottom of the page, after the file list.

---

### I3. Partial Compression Marked as "Completed"

**Source**: Architecture Review
**Files**: `lib/services/job_queue_service.dart`

In `_processCompression`, after the file loop, `markJobCompleted` is called unconditionally. If some files failed (were marked as failed and skipped), the job is still marked as "completed." The Slack notification shows correct counts, but the job status is misleading.

**Impact**: User sees "Completed" for a job where 3 out of 10 files failed compression.

**Recommendation**: After the loop, check if any files failed. If so, mark the job as `failed` with an error message indicating partial failure (e.g., "7/10 files compressed, 3 failed"). Or introduce a `completedWithErrors` status.

---

### I4. Stopped Queue Marks Interrupted Job as "Completed"

**Source**: Architecture Review
**Files**: `lib/services/job_queue_service.dart`

If `_isProcessing` becomes false during the file loop (user pressed Stop), the loop breaks but then falls through to `markJobCompleted`. A partially-transferred job is marked as completed. Resuming later skips this job since it appears done.

**Impact**: Incomplete transfers marked as finished, files left un-transferred.

**Recommendation**: After the loop, check whether it was interrupted by `!_isProcessing`. If so, mark the job as `paused` instead of `completed`, and skip the completion notification.

---

### I5. No HandBrake Retry Logic

**Source**: Architecture Review
**Files**: `lib/services/job_queue_service.dart`

When compression fails on a file, the code marks it as failed and moves on. There is no retry. Robocopy has built-in retries (`/R:3`), but HandBrake does not. Transient failures (disk temporarily full, process killed by OS) are treated as permanent.

**Impact**: A single transient failure during a multi-hour compression batch silently skips a file with no recourse.

**Recommendation**: Add a configurable retry count (e.g., 3 attempts) for HandBrake compression. After exhausting retries, mark as failed.

---

### I6. Slack Notifications Silently Swallowed

**Source**: Architecture Review
**Files**: `lib/services/slack_service.dart`

The `_send` method catches all exceptions and silently discards them. Network blips, rate limiting (HTTP 429), and temporary Slack outages all result in lost notifications with no log or record.

**Impact**: Users may never learn that a transfer completed or failed if notifications are silently dropped.

**Recommendation**: Add retry with exponential backoff (3 attempts, 1s/2s/4s delays). Log failed notifications. Consider a dead-letter queue (database table of unsent notifications that can be retried).

---

### I7. Windows Path Joining Uses Forward Slashes

**Source**: Architecture Review
**Files**: `lib/services/job_queue_service.dart`

Line 213: `'$outputPath/${f.fileName}'` uses string interpolation with a forward slash. On Windows (the target platform), this should use backslashes, and more importantly should use `package:path` for proper path joining.

**Impact**: Path construction may fail on Windows or produce paths rejected by some Windows tools.

**Recommendation**: Replace with `p.join(outputPath, f.fileName)` using `import 'package:path/path.dart' as p;`.

---

### I8. Mobile Push/Pop Navigation Instead of Desktop Master-Detail

**Source**: UX Review
**Files**: `lib/ui/screens/home_screen.dart`, `lib/app.dart`

Every screen (Create Job, Job Detail, Settings) uses `Navigator.push()` with `MaterialPageRoute`, replacing the entire view. Desktop apps typically use a master-detail layout or keep context visible. Users lose sight of the queue when viewing job details.

**Impact**: Workflow efficiency — users can't monitor the queue while viewing a job's progress.

**Recommendation**: Use a two-panel layout: queue list on the left, detail/create panel on the right. This lets users monitor the queue while viewing a job's progress.

---

### I9. Job Card Paths Hard to Scan

**Source**: UX Review
**Files**: `lib/ui/widgets/job_card.dart`

`_jobSubtitle()` returns full Windows paths like `E:\DCIM\100MEDIA → D:\Video Projects\2026-05-05\Raw`. On a desktop list, these long paths make cards visually noisy and hard to distinguish at a glance.

**Impact**: Users scanning a queue with multiple similar jobs can't tell them apart quickly.

**Recommendation**: Show only the last directory name (e.g., "100MEDIA → Raw") with a tooltip showing the full path on hover.

---

### I10. No Job History/Archive

**Source**: UX Review
**Files**: `lib/ui/screens/home_screen.dart`, `lib/database/daos/job_dao.dart`

Once a job is completed and deleted, it vanishes. There is no history of past transfers for reference ("Did I already copy Card 7?").

**Impact**: Users across multiple shoot days lose track of what has been processed.

**Recommendation**: Add a "History" tab or section showing completed/failed jobs with timestamps. Keep them in the database but filter them out of the active queue view.

---

### I11. Failed Errors Shown Raw With No Remediation Guidance

**Source**: UX Review
**Files**: `lib/ui/screens/job_detail_screen.dart`

Raw error messages like "Access denied" or "The process cannot access the file" are displayed directly to non-technical video editors. These mean nothing to them.

**Impact**: Every user who encounters an error is stuck with no guidance.

**Recommendation**: Map common error patterns to human-friendly messages with next steps. E.g., "Access denied" → "The destination folder is protected. Try running the app as Administrator or choose a different folder." Show raw error in an expandable "Technical Details" section.

---

### I12. HandBrake Preset Language Unexplained

**Source**: UX Review
**Files**: `lib/ui/screens/create_job_screen.dart`

The dropdown says "Select a HandBrake preset" with no explanation. If presets are empty, the message is "No presets found. Check HandBrake installation" — which assumes the user knows what HandBrake is.

**Impact**: Non-technical team members who didn't set up the machine are confused.

**Recommendation**: (1) Rename "Compression Preset" to "Quality Setting" or "Output Quality." (2) When no presets found, show a prominent banner: "Compression requires HandBrake. Download it at handbrake.fr" with a link. (3) Disable the Compress/Both job type options entirely when HandBrake is not installed.

---

### I13. No Minimum Window Size or Responsive Layout

**Source**: UX Review
**Files**: `lib/main.dart`, `lib/app.dart`

There is no minimum window size set. If the user resizes very small, the single-column layout with long file paths will overflow or wrap poorly.

**Impact**: Users who don't run the app maximized see broken layouts.

**Recommendation**: Set minimum window size (e.g., 800x600) using `window_manager` or the Windows runner configuration.

---

### I14. No Error Handling in _createJob()

**Source**: UX Review
**Files**: `lib/ui/screens/create_job_screen.dart`

`_createJob()` calls `_jobDao.insertJob()` without a try-catch. If the database insert fails (disk full, permission error), the user sees nothing — the screen just stays open.

**Impact**: Silent failure with no feedback.

**Recommendation**: Wrap in try-catch and show an error snackbar on failure.

---

### I15. Queue Start/Stop Has No Confirmation Feedback

**Source**: UX Review
**Files**: `lib/ui/screens/home_screen.dart`

`_toggleProcessing()` toggles state silently. There is no snackbar or indicator beyond the button label changing. If processing fails to start, the user gets no feedback.

**Impact**: Users pressing Start and wondering if it worked.

**Recommendation**: Show a snackbar ("Queue started — processing 3 jobs") and handle the edge case where `startProcessing()` throws.

---

### I16. SD Card Removal Not Specifically Detected

**Source**: UX Review
**Files**: `lib/services/job_queue_service.dart`, `lib/services/transfer_service.dart`

The spec lists "SD card removed mid-transfer" as an edge case, but the UI has no specific handling. The error surfaces as a generic file I/O error.

**Impact**: Users who accidentally bump the card hub get a cryptic error.

**Recommendation**: Detect removable drive disconnection specifically and show a targeted message: "SD card disconnected. Please re-insert the card and tap Retry to resume."

---

## Nice-to-Have Issues

### N1. File Size Formatting Duplicated in 3 Places

**Source**: Architecture Review
**Files**: `lib/services/drive_service.dart`, `lib/services/slack_service.dart`, `lib/ui/screens/job_detail_screen.dart`

`(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)` appears in 3 files with slight variations.

**Recommendation**: Create `String formatBytes(int bytes, {int decimals = 1})` helper in `lib/utils/format_utils.dart`.

---

### N2. Job Type Labels Duplicated in 2 Places

**Source**: Architecture Review
**Files**: `lib/ui/screens/job_detail_screen.dart`, `lib/ui/widgets/job_card.dart`

Both have identical `switch` on `JobType` to produce label strings.

**Recommendation**: Add extension method: `extension JobTypeX on JobType { String get label => ... }`.

---

### N3. Job Status Labels/Colors Duplicated in 2 Places

**Source**: Architecture Review
**Files**: `lib/ui/screens/job_detail_screen.dart`, `lib/ui/widgets/job_card.dart`

Both define status-to-color and status-to-label mappings independently.

**Recommendation**: Add extension on `JobStatus` with `label` and `color` getters.

---

### N4. Process Stdout Streaming Pattern Duplicated

**Source**: Architecture Review
**Files**: `lib/services/transfer_service.dart`, `lib/services/compression_service.dart`

Both services have identical boilerplate: start process, listen to stdout with `SystemEncoding().decoder`, split by newline, parse each line, call callback, await exit code.

**Recommendation**: Create a `ProcessRunner` utility class that handles the boilerplate. Both services would provide only the command, arguments, and parser function.

---

### N5. Settings Saved on Every Keystroke

**Source**: Architecture Review
**Files**: `lib/ui/screens/settings_screen.dart`

The `onChanged` callback on the webhook URL `TextField` calls `setSlackWebhookUrl()` on every character typed, triggering a database write per keystroke.

**Recommendation**: Debounce the save (500ms delay after last keystroke), or save only on blur/submit.

---

### N6. Inefficient Single-Job Watching

**Source**: Architecture Review
**Files**: `lib/ui/screens/job_detail_screen.dart`

`watchAllJobs().map((jobs) => jobs.where((j) => j.id == widget.jobId).firstOrNull)` fetches and deserializes every job in the database to find one by ID. This is O(n) on every database change.

**Recommendation**: Add `watchJob(int jobId)` to `JobDao`: `(select(jobs)..where((t) => t.id.equals(jobId))).watchSingleOrNull()`.

---

### N7. PowerShell Command Injection Risk in eraseDrive

**Source**: Architecture Review
**Files**: `lib/services/drive_service.dart`

`drivePath` is interpolated directly into a PowerShell command string. If it contains special characters, this could execute arbitrary commands.

**Recommendation**: Validate that `drivePath` matches a drive letter pattern (`RegExp(r'^[A-Z]:\\$')`) before executing.

---

### N8. Global Mutable Database Variable

**Source**: Architecture Review
**Files**: `lib/main.dart`

`late final AppDatabase database` is a top-level global. Makes testing difficult and creates implicit coupling.

**Recommendation**: Use a service locator or dependency injection. At minimum, wrap in a singleton class.

---

### N9. No Error Handling in _checkForUpdates

**Source**: Architecture Review
**Files**: `lib/app.dart`

If `settingsDao.getSettings()` throws (e.g., database not yet initialized), the app crashes on startup.

**Recommendation**: Wrap the entire `_checkForUpdates` method body in a try-catch.

---

### N10. "Job Queue" Terminology Is Developer Jargon

**Source**: UX Review

Video editors think in terms of "cards to copy" or "footage to process," not "jobs" and "queues."

**Recommendation**: Rename "Job" to "Task" throughout, and "Queue" to "Task List." "Start Queue" → "Start Processing." "Add to Queue" → "Add Task."

---

### N11. No Keyboard Shortcuts

**Source**: UX Review

Desktop app with zero keyboard shortcuts. Expected: Ctrl+N (new job), Ctrl+Enter (start queue), Delete (remove job), Ctrl+, (settings).

**Recommendation**: Add keyboard shortcuts using Flutter's `Shortcuts` and `Actions` widgets.

---

### N12. No Right-Click Context Menus on Job Cards

**Source**: UX Review

Desktop users expect right-click menus. Right-clicking a job should offer: View Details, Delete, Retry (if failed), Move Up/Down.

**Recommendation**: Add `GestureDetector` with `onSecondaryTapDown` to `JobCard` with a popup menu.

---

### N13. FAB Is a Mobile Pattern

**Source**: UX Review
**Files**: `lib/ui/screens/home_screen.dart`

`FloatingActionButton.extended` is a mobile pattern. On desktop, a toolbar button is more conventional. The empty state already has its own "Create Job" button, creating redundancy.

**Recommendation**: Move "New Job" into the app bar as a button. Remove the FAB.

---

### N14. No Drag-to-Reorder Queue

**Source**: UX Review

Jobs process in order but cannot be reordered. If a user adds 5 jobs but card #3 is urgent, they cannot move it up.

**Recommendation**: Add `ReorderableListView` support to the job list.

---

### N15. No System Tray Icon

**Source**: UX Review

When minimized, there is no system tray icon showing progress. Users must keep the window visible or rely on Slack.

**Recommendation**: Add a Windows system tray icon with progress tooltip and notification on completion.

---

### N16. Hard-Coded Colors Throughout

**Source**: UX Review
**Files**: All UI files

Colors like `Colors.red`, `Colors.green`, `Colors.orange` are scattered across every file instead of using theme tokens.

**Recommendation**: Define semantic colors as theme extensions (`statusSuccess`, `statusError`, `statusWarning`, `statusActive`) and reference them everywhere.

---

### N17. "Both" Label Is Vague

**Source**: UX Review
**Files**: `lib/ui/screens/create_job_screen.dart`

The third segmented button option is labeled "Both" — unclear without context.

**Recommendation**: Rename to "Copy & Compress."

---

### N18. Drive Refresh Has No Completion Feedback

**Source**: UX Review
**Files**: `lib/ui/screens/create_job_screen.dart`

When the user presses refresh and no drives are found, there is no transient feedback that the scan completed.

**Recommendation**: Show a snackbar: "Scan complete — no removable drives found" or "Found 3 drives."

---

### N19. First Job Creation Doesn't Hint About Starting Queue

**Source**: UX Review

A first-time user might expect jobs to start automatically after creation. There is no indication that they need to press Start.

**Recommendation**: Update the snackbar to: "Job added to queue. Press Start to begin processing."

---

## Summary Table

| Priority | Count | Key Themes |
|----------|-------|------------|
| **Critical** | 7 | Pipeline doesn't work, race conditions, no verification, missing batch action, no disk space check, no retry, no ETA |
| **Important** | 16 | No subprocess cancel, unsafe erase, partial completion lies, mobile UX on desktop, raw errors, no history |
| **Nice-to-have** | 19 | Code dedup, keyboard shortcuts, right-click menus, system tray, terminology, drag-reorder, theme tokens |
| **Total** | **42** | |
