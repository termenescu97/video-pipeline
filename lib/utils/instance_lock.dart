import 'dart:io';

import 'package:path/path.dart' as p;

/// PID-based single-instance lock. Prevents multiple app instances from
/// running simultaneously and corrupting the shared SQLite database.
class InstanceLock {
  late final File _lockFile;

  InstanceLock() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    _lockFile = File(p.join(exeDir, 'copiatorul3000.lock'));
  }

  /// Try to acquire the lock. Returns true if successful, false if another
  /// instance is running.
  Future<bool> acquire() async {
    try {
      if (await _lockFile.exists()) {
        final content = await _lockFile.readAsString();
        final pid = int.tryParse(content.trim());
        if (pid != null && await _isProcessRunning(pid)) {
          return false; // Another instance is running.
        }
        // Stale lock — clean up and proceed.
        await _lockFile.delete();
      }

      await _lockFile.writeAsString('$pid');
      return true;
    } catch (_) {
      // If we can't create the lock file (read-only FS), proceed with a warning.
      return true;
    }
  }

  /// Release the lock file.
  Future<void> release() async {
    try {
      if (await _lockFile.exists()) {
        await _lockFile.delete();
      }
    } catch (_) {
      // Best effort — lock file may already be gone.
    }
  }

  Future<bool> _isProcessRunning(int targetPid) async {
    if (!Platform.isWindows) return false;

    try {
      final result = await Process.run('tasklist', [
        '/FI', 'PID eq $targetPid',
        '/NH',
      ]);
      return result.stdout.toString().contains('$targetPid');
    } catch (_) {
      return false;
    }
  }
}
