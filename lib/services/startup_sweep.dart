import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/daos/job_dao.dart';
import '../database/tables.dart';
import 'log_service.dart';

/// 018 T027 (FR-016, US6, P3, SC-010): orphaned-staging-dir sweep.
///
/// On every cold start (called from `main.dart` after
/// `recoverStaleJobs`, before `JobQueueService` construction), walks
/// the destination roots known to the queue and removes any
/// `.tmp_robocopy_*` staging directory whose `.live` marker is absent
/// or stale. This closes the FR-016 leak: a Windows operator's prior
/// crashed run leaves staging dirs full of partially-copied bytes
/// directly in their footage destinations; without a sweep these
/// accumulate across runs and the operator eventually sees them in
/// Explorer, copies them, mistakes them for footage.
///
/// **Liveness check** is two-axis: the marker's PID must be a live
/// process AND its executable path must match THIS process's
/// resolvedExecutable. PID alone is insufficient — Windows recycles
/// PIDs aggressively and a freshly-spawned `notepad.exe` could
/// otherwise convince the sweeper that an unrelated dir is live.
///
/// **Roots collected**: distinct destination paths of jobs in
/// non-terminal status (queued / paused / inProgress) UNION the
/// most-recently-completed job's destination root. The completed-job
/// root catches the operator who finished a run, crashed, then
/// re-launched: the queued set is empty but the dir to sweep was
/// the last completed job's destination.
///
/// **Unmounted roots**: if the destination directory doesn't exist
/// (drive ejected, network share offline), the sweep skips silently.
/// We do NOT log a warning — the operator may have intentionally
/// disconnected the drive, and a noisy log on every launch would
/// drown out signal.
Future<void> sweepOrphanedStagingDirs(
  JobDao jobDao, {
  LogService? logService,
}) async {
  final roots = <String>{};
  // Non-terminal jobs.
  final live = await jobDao.getJobsByStatuses({
    JobStatus.queued,
    JobStatus.paused,
    JobStatus.inProgress,
  });
  for (final j in live) {
    roots.add(j.destinationPath);
  }
  // Most-recently-completed job (single row).
  final lastDone = await jobDao.getMostRecentCompletedJob();
  if (lastDone != null) roots.add(lastDone.destinationPath);

  for (final root in roots) {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) continue;
    final List<FileSystemEntity> children;
    try {
      children = rootDir.listSync(followLinks: false);
    } catch (e) {
      logService?.warning(
        'startup-sweep: list failed for $root: $e',
        phase: LogPhase.recover,
      );
      continue;
    }
    for (final child in children) {
      if (child is! Directory) continue;
      final name = p.basename(child.path);
      if (!name.startsWith('.tmp_robocopy_')) continue;
      if (await _isStagingDirAlive(child)) continue;
      try {
        await child.delete(recursive: true);
        logService?.info(
          'startup-sweep: removed orphan staging dir ${child.path}',
          phase: LogPhase.recover,
        );
      } catch (e) {
        logService?.warning(
          'startup-sweep: delete failed for ${child.path}: $e',
          phase: LogPhase.recover,
        );
      }
    }
  }
}

/// True if the `.live` marker exists AND the recorded PID is alive
/// AND its executable path matches THIS process's resolvedExecutable.
Future<bool> _isStagingDirAlive(Directory stagingDir) async {
  final markerFile = File(p.join(stagingDir.path, '.live'));
  if (!markerFile.existsSync()) return false;
  final String content;
  try {
    content = await markerFile.readAsString();
  } catch (_) {
    return false;
  }
  int? recordedPid;
  String? recordedExe;
  for (final line in content.split('\n')) {
    if (line.startsWith('pid=')) {
      recordedPid = int.tryParse(line.substring(4).trim());
    } else if (line.startsWith('exe=')) {
      recordedExe = line.substring(4).trim();
    }
  }
  if (recordedPid == null || recordedExe == null) return false;
  // Same-process fast path: marker matches us, definitely live.
  if (recordedPid == pid && recordedExe == Platform.resolvedExecutable) {
    return true;
  }
  // Marker references a different process. Check whether that PID
  // is alive AND whether it points at the same executable. We treat
  // an exe mismatch as orphaned even if the PID is alive — Windows
  // recycles PIDs so a coincidental `notepad.exe` at the recorded
  // PID must not block sweep.
  if (!_isPidAlive(recordedPid)) return false;
  final exeOfPid = await _exePathOfPid(recordedPid);
  if (exeOfPid == null) return false;
  return exeOfPid == Platform.resolvedExecutable;
}

bool _isPidAlive(int pid) {
  try {
    if (Platform.isWindows) {
      // tasklist /FI "PID eq N" /NH — exit code 0 always; check
      // output for "INFO: No tasks". Dart's Process.killPid with
      // signal 0 isn't a portable liveness probe on Windows.
      final r = Process.runSync(
        'tasklist',
        ['/FI', 'PID eq $pid', '/NH'],
        runInShell: true,
      );
      final out = (r.stdout as String).toLowerCase();
      return !out.contains('no tasks');
    }
    // POSIX: `kill -0 PID` returns success iff a process with that
    // PID exists and the caller has permission to signal it. Doesn't
    // actually deliver a signal. Same semantic as the C `kill(pid,0)`
    // probe used by Apache, Postgres, every PID-file-aware daemon.
    final r = Process.runSync('kill', ['-0', '$pid']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<String?> _exePathOfPid(int pid) async {
  try {
    if (Platform.isWindows) {
      // wmic process where "ProcessId=N" get ExecutablePath /value
      final r = await Process.run(
        'wmic',
        ['process', 'where', 'ProcessId=$pid', 'get', 'ExecutablePath', '/value'],
        runInShell: true,
      );
      final out = r.stdout as String;
      for (final line in out.split('\n')) {
        final t = line.trim();
        if (t.startsWith('ExecutablePath=') && t.length > 15) {
          return t.substring(15).trim();
        }
      }
      return null;
    }
    // POSIX (macOS/Linux): /proc/PID/exe (Linux) or `lsof` (macOS).
    final procExe = File('/proc/$pid/exe');
    if (procExe.existsSync()) {
      return procExe.resolveSymbolicLinksSync();
    }
    // macOS fallback: ps -o comm=
    final r = await Process.run('ps', ['-o', 'comm=', '-p', '$pid']);
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}
