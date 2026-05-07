import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Single-instance lock backed by an OS-level advisory file lock.
///
/// Why an OS lock (not a check-then-write PID file): two processes that
/// both observe a missing or stale lock file can race through any
/// "exists" check and both believe they acquired the lock. The OS lock,
/// held only as long as the [RandomAccessFile] handle is open, gives
/// us atomic acquisition and automatic release on process exit (even on
/// crash) — neither of which is achievable with check-then-write logic
/// in user space.
///
/// The lock file still records the holder's PID for diagnostics, but the
/// PID is no longer load-bearing: stale PIDs can never block startup
/// because the OS releases the lock when the holding process dies.
class InstanceLock {
  RandomAccessFile? _handle;
  File? _lockFile;

  /// Try to acquire the lock. Returns true on success, false on failure
  /// (another instance holds it, or the lock cannot be acquired safely).
  /// Fails closed — any unexpected error returns false.
  Future<bool> acquire() async {
    final File lockFile;
    try {
      final supportDir = await getApplicationSupportDirectory();
      // Ensure the directory exists; on a fresh install on Windows the
      // app-support folder may not have been created yet.
      if (!await supportDir.exists()) {
        await supportDir.create(recursive: true);
      }
      lockFile = File(p.join(supportDir.path, 'copiatorul3000.lock'));
      _lockFile = lockFile;
    } catch (_) {
      return false;
    }

    RandomAccessFile? handle;
    try {
      // Open in write mode (creates if missing, does not truncate by
      // itself — we truncate only after we hold the lock).
      handle = await lockFile.open(mode: FileMode.write);
      // Non-blocking exclusive lock. Throws / returns synchronously if
      // another process holds the lock.
      await handle.lock(FileLock.exclusive);

      // We now exclusively own the file. Write our PID for diagnostics.
      await handle.setPosition(0);
      await handle.truncate(0);
      await handle.writeString('$pid\n');
      await handle.flush();

      _handle = handle;
      return true;
    } catch (_) {
      // Lock contention or any I/O failure — close anything we opened
      // and fail closed.
      try {
        await handle?.close();
      } catch (_) {}
      return false;
    }
  }

  /// Diagnostic snapshot for the Settings → Diagnostics panel (T074).
  ///
  /// Reports whether THIS process currently holds the lock, the resolved
  /// lock-file path (when available), and the PID written to the file
  /// (best-effort: read fails silently if the file is missing or another
  /// process is mid-write). The PID is the holder's claim; absent an
  /// explicit "lock held by us" flag the operator can compare against
  /// `Process.pid` themselves.
  Future<InstanceLockDiagnostic> diagnostic() async {
    final held = _handle != null;
    final path = _lockFile?.path;
    int? recordedPid;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) {
          final content = (await f.readAsString()).trim();
          recordedPid = int.tryParse(content);
        }
      } catch (_) {
        // Best-effort read; ignore I/O failures.
      }
    }
    return InstanceLockDiagnostic(
      heldByThisProcess: held,
      lockFilePath: path,
      recordedPid: recordedPid,
      currentPid: pid,
    );
  }

  /// Release the lock. Safe to call even if [acquire] never succeeded.
  Future<void> release() async {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;

    try {
      await handle.unlock();
    } catch (_) {}
    try {
      await handle.close();
    } catch (_) {}

    // Best-effort cleanup of the lock file. Only delete it while we
    // still hold the handle — if another process is already holding the
    // lock by the time we reach this line, deleting the file would
    // remove their lock metadata too. Closing first means our handle no
    // longer owns the file; we skip deletion in that case.
    final lockFile = _lockFile;
    if (lockFile == null) return;
    try {
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    } catch (_) {
      // Another process may have re-acquired and re-truncated the file
      // between our close() and delete() — that's fine, leave it alone.
    }
  }
}

/// Snapshot of single-instance-lock state, for the Settings →
/// Diagnostics panel (T074, T078).
class InstanceLockDiagnostic {
  /// True iff this process currently holds the lock.
  final bool heldByThisProcess;

  /// Resolved path to the lock file (null only if [acquire] never ran
  /// or path resolution failed during acquire).
  final String? lockFilePath;

  /// PID written into the lock file by the current holder. Diagnostic
  /// only — not load-bearing for safety (the OS lock is what gates
  /// startup, not this PID).
  final int? recordedPid;

  /// PID of THIS process (always available; useful for comparison).
  final int currentPid;

  const InstanceLockDiagnostic({
    required this.heldByThisProcess,
    required this.lockFilePath,
    required this.recordedPid,
    required this.currentPid,
  });
}
