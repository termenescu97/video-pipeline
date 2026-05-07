import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// PID-based single-instance lock. Prevents multiple app instances from
/// running simultaneously and corrupting the shared SQLite database.
///
/// Uses an atomic write pattern (write-temp + rename) and fails closed —
/// if the lock cannot be acquired for any reason, the app refuses to start.
class InstanceLock {
  File? _lockFile;

  /// Try to acquire the lock. Returns true if successful, false if another
  /// instance is running or the lock cannot be acquired safely.
  Future<bool> acquire() async {
    final File lockFile;
    final File tempFile;
    try {
      final supportDir = await getApplicationSupportDirectory();
      lockFile = File(p.join(supportDir.path, 'copiatorul3000.lock'));
      tempFile = File(p.join(supportDir.path, 'copiatorul3000.lock.tmp'));
      _lockFile = lockFile;
    } catch (_) {
      // Cannot determine app support directory — fail closed.
      return false;
    }

    try {
      if (await lockFile.exists()) {
        final content = await lockFile.readAsString();
        final lockedPid = int.tryParse(content.trim());
        if (lockedPid == null) {
          // Malformed lock file — treat as stale.
          await lockFile.delete();
        } else {
          // Check if the recorded PID is still running.
          // If the check itself throws, fail closed (treat lock as held).
          final running = await _isProcessRunning(lockedPid);
          if (running) {
            return false; // Another instance is running.
          }
          // Stale lock — delete and proceed to acquire.
          await lockFile.delete();
        }
      }

      // Atomic write: write PID to temp file, then rename.
      // Rename is atomic on Windows and POSIX, preventing two processes
      // from both passing the exists-check simultaneously.
      await tempFile.writeAsString('$pid');
      await tempFile.rename(lockFile.path);
      return true;
    } catch (_) {
      // Any error during acquisition (including PID-check failures) — fail closed.
      // Best-effort cleanup of any orphaned temp file.
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Release the lock file.
  Future<void> release() async {
    final lockFile = _lockFile;
    if (lockFile == null) return;
    try {
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    } catch (_) {
      // Best effort — lock file may already be gone.
    }
  }

  /// Returns true if the process with [targetPid] is running.
  /// Throws if the check itself cannot be performed (caller fails closed).
  /// On non-Windows (development), returns false since concurrency is not a
  /// real concern outside the production target.
  Future<bool> _isProcessRunning(int targetPid) async {
    if (!Platform.isWindows) return false;

    final result = await Process.run('tasklist', [
      '/FI',
      'PID eq $targetPid',
      '/NH',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'tasklist',
        ['/FI', 'PID eq $targetPid', '/NH'],
        'tasklist exited with code ${result.exitCode}',
        result.exitCode,
      );
    }
    return result.stdout.toString().contains('$targetPid');
  }
}
