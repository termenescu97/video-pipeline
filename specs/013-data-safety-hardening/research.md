# Research: Data Safety & Reliability Hardening

**Feature**: 013-data-safety-hardening  
**Date**: 2026-05-07

## R1: Per-Card Subfolder Naming in Batch Copy

**Decision**: Use `label_driveletter` format (e.g., `EOS_DIGITAL_E/`) for per-card destination subfolders in batch copy.

**Rationale**: Drive labels alone can collide (two Canon cameras = two `EOS_DIGITAL`). Drive letters alone are opaque. Combining both is always unique and human-readable. The label comes from `getDriveIdentity()` which already queries WMI `Win32_LogicalDisk.VolumeName`. Special characters in labels are sanitized (replaced with `_`); empty labels use `Drive` as placeholder.

**Alternatives considered**:
- Label-only with drive letter fallback on collision: extra logic, still fragile
- Drive letter only: unique but meaningless to operators
- Timestamp-based subfolders: unique but disconnected from physical card identity

**Implementation**: In `createBatchTransferJobs()`, before building file entries, call `getDriveIdentity(drivePath)` to get the label. Construct subfolder name as `${sanitizedLabel}_${driveLetter}`. Insert this between the base destination and the relative file path.

## R2: Destination Conflict Detection Strategy

**Decision**: Pre-flight check at job creation time. Scan all planned destination paths for existing files. If conflicts found, show a modal dialog with options: Skip existing, Rename (auto-suffix), Choose new folder, or Overwrite (requires typing "OVERWRITE"). For batch copy, perform one global preflight across ALL cards before creating ANY jobs. If skip-all results in zero files for a card, that card is skipped entirely (no phantom job created).

**Rationale**: Checking at creation time (not transfer time) prevents queuing invalid jobs. The conflict dialog follows the constitution's human-in-the-loop principle. Robocopy's default behavior would silently update files based on timestamp/size comparisons, which is unsafe for production footage.

**Alternatives considered**:
- Check at transfer time per-file: too late, job already queued, harder to cancel
- Robocopy `/XC /XN /XO` flags: insufficient control, no user confirmation
- Always require empty destination: too restrictive for legitimate re-runs

**Implementation**: In `create_job_screen.dart` and `createBatchTransferJobs()`, after building the file list, check `File(destinationFilePath).existsSync()` for each entry. If any exist, show `ConflictResolutionDialog`. For "Skip", filter out conflicting entries (if all filtered → don't create job). For "Rename", append `_1`, `_2` suffix to conflicting filenames. For "New folder", re-pick destination. For "Overwrite", require typed confirmation. In batch mode, build the complete file list for ALL cards first, run one global preflight, then create jobs only for cards that still have files.

## R3: Crash Recovery for In-Progress Jobs

**Decision**: On startup (in `main.dart`, after DB init but before `runApp`), query all jobs with `status == inProgress` and move them to `paused`. Also move their in-progress files back to `pending`.

**Rationale**: Recovery to `paused` (not `queued`) ensures the operator reviews before resuming, as clarified in spec. Robocopy `/Z` handles partial file resumption natively — no app-side byte tracking needed. The recovery query runs once at startup, is idempotent, and wraps all updates in a single transaction.

**Alternatives considered**:
- Recover to `queued` (auto-resume): risky if source is unavailable or disk full
- Leave as-is and add a "Recover" button: operator may not notice stranded jobs
- Heartbeat-based detection: over-engineered for a single-instance desktop app

**Implementation**: Add `recoverStaleJobs()` to `JobDao` that runs in a transaction: update all inProgress jobs to paused, update all inProgress files to pending. Call from `main.dart` after `database = AppDatabase()` and before `runApp()`.

## R4: Transactional Job Creation

**Decision**: Wrap job insert + file inserts + totals update in a single Drift `transaction()` block.

**Rationale**: Drift supports `transaction(() async { ... })` natively (already used in `reorderJobs`, `resetJobForRetry`, `deleteJob`). The three-step creation (insert job → insert files → update totals) is the exact pattern transactions are designed for.

**Alternatives considered**:
- Post-startup cleanup of orphaned jobs: reactive, not preventive
- Two-phase commit with status flag: unnecessary complexity when Drift transactions work

**Implementation**: Add `createJobWithFiles()` to `JobDao` that accepts the `JobsCompanion`, `List<JobFilesCompanion>`, and totals, executes all three inside `transaction()`. Replace the three separate calls in `create_job_screen.dart` and `createBatchTransferJobs()`.

## R5: Instance Lock Mechanism

**Decision**: Keep the PID-based lock file approach but fix the critical bugs: use `pid` from `dart:io`, fail closed on errors, and use atomic write pattern.

**Rationale**: A Windows named mutex would require `win32` FFI calls that add complexity. The PID lock file is simpler and already works for the single-machine, single-user scenario. The key fixes are: (1) actually write the current PID (`import 'dart:io' show pid`), (2) change `catch (_) { return true; }` to `catch (_) { return false; }` (fail closed), (3) move lock file to app support directory (not next to executable, which may be read-only).

**Alternatives considered**:
- Windows named mutex via `win32`: more robust but adds FFI complexity; overkill for a single-user app
- File lock via `lockFile()` API: Dart doesn't have cross-platform advisory file locking
- Socket-based lock: over-engineered

**Implementation**: Fix `instance_lock.dart`: import `dart:io` pid, write `'$pid'` correctly, change catch to `return false`, move lock path to `getApplicationSupportDirectory()`.

## R6: Cancellable SHA-256 Hashing

**Decision**: Route SHA-256 hashing through `ProcessRunner` instead of raw `Process.run()`, so the existing `kill()` mechanism applies.

**Rationale**: `ProcessRunner` already handles stream consumption, exit code awaiting, and kill signals. Using it for hashing is consistent with how transfer and compression subprocesses work. The only change is that `computeFileHash()` needs to accept a `ProcessRunner` instance and use `Process.start()` instead of `Process.run()`.

**Alternatives considered**:
- Native Dart SHA-256 streaming: would require reading 50GB files in Dart, slow compared to PowerShell's .NET implementation
- Custom cancellation token: adds complexity when ProcessRunner already solves this
- Timeout-based kill: doesn't respect user cancel intent

**Implementation**: Add a `_hashRunner` ProcessRunner to `TransferService`. `computeFileHash()` uses `_hashRunner.run()` with stdout callback to capture the hash output. `cancel()` now also kills `_hashRunner`. In `JobQueueService`, after stopping hash, mark file as `pending` (needs re-verification).

## R7: Graceful Shutdown Sequence

**Decision**: Use `window_manager.setPreventClose(true)` to intercept window close. Make `_gracefulShutdown()` await `stopProcessing()` (convert to Future-returning), then close resources in order.

**Rationale**: `window_manager` already supports `setPreventClose` and `onWindowClose` callbacks. The current shutdown fires `stopProcessing()` without awaiting it, then closes the DB while the queue loop may still be writing. The fix is: (1) make `stopProcessing()` return a `Future` that completes when the loop exits, (2) await it in shutdown, (3) add a 10-second timeout to prevent infinite hang.

**Alternatives considered**:
- `ProcessSignal.sigterm` handler: Windows doesn't support POSIX signals reliably
- Just kill the process: risks DB corruption
- Periodic checkpoint writes: doesn't solve the race, adds complexity

**Implementation**: In `shell_screen.dart`, add `WindowListener` mixin, call `setPreventClose(true)` in init, implement `onWindowClose()` → `_gracefulShutdown()`. Wire tray quit to the same `_gracefulShutdown()`. In `job_queue_service.dart`, make `stopProcessing()` return a `Future<void>` via Completer that resolves when the loop exits AND all pending state writes complete. Shutdown awaits stop (no timeout on state persistence — it MUST complete), with a 30-second outer safety timeout on the entire shutdown sequence.

## R7b: Erase Identity — Serial Number for Physical Device Verification

**Decision**: Extend `getDriveIdentity()` to return the physical disk serial number via WMI association chain (`Win32_LogicalDisk` → `Win32_LogicalDiskToPartition` → `Win32_DiskDriveToDiskPartition` → `Win32_DiskDrive.SerialNumber`). Use serial as the primary identity comparator for erase re-verification.

**Rationale**: The original plan compared only label + totalBytes, which fails when two cards have the same label and capacity (common with identical camera models). Serial number is a factory-unique physical device identifier that survives reformatting and relabeling. It's the strongest available proof that the same physical card is still mounted.

**Alternatives considered**:
- Label + totalBytes only: fails for identical camera models (e.g., two Canon R5s with default "EOS_DIGITAL" label and 128GB cards)
- Volume serial number (Win32_LogicalDisk.VolumeSerialNumber): unique per format, but changes when card is reformatted — not stable enough
- Disk signature (MBR/GPT): accessible but less standard across card readers

**Implementation**: In `getDriveIdentity()`, add a second PowerShell query using `$args[0]` to trace the association chain. Return `({String label, int totalBytes, String? serialNumber})`. In erase re-verification (D1), compare serial first; fall back to label+totalBytes if serial is null (some card readers don't expose it).

## R8: Process Runner Stream Safety

**Decision**: Always drain both stdout and stderr in `ProcessRunner.run()`, regardless of whether callbacks are provided.

**Rationale**: OS pipe buffers are typically 64KB on Windows. A subprocess writing verbose output to an unconsumed stream will block when the buffer fills. The fix is trivial: replace `Future<void>.value()` with a stream drain that discards data when no callback is provided.

**Alternatives considered**:
- Only fix for specific callers: fragile, easy to miss future callers
- Redirect subprocess stderr to /dev/null: not cross-platform

**Implementation**: In `process_runner.dart`, change the ternary on lines 17-23 and 25-31 to always consume streams. When no callback is provided, use `process.stdout.drain()` / `process.stderr.drain()`.

## R9: Version Single-Sourcing

**Decision**: Read version from `pubspec.yaml` at compile time via Dart's `--dart-define` or read `Platform.packageInfo`. Remove `appVersion` from `constants.dart`.

**Rationale**: The `package_info_plus` package can read the version from pubspec.yaml at runtime on desktop. This is simpler than build-time injection and doesn't require CI changes.

**Alternatives considered**:
- `--dart-define=APP_VERSION=x.y.z` in CI: requires CI config changes
- Read pubspec.yaml at runtime: fragile, file may not be bundled
- Git tag injection: requires git at build time

**Implementation**: Add `package_info_plus` dependency. In `update_service.dart`, replace `constants.appVersion` with `PackageInfo.fromPlatform().then((info) => info.version)`. Remove `appVersion` from `constants.dart`. Update `pubspec.yaml` version to `2.3.0` for this release.
