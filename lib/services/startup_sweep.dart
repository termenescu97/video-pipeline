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
/// `.tmp_robocopy_*` staging directory whose `.live` marker was
/// written on THIS host by a prior crashed run. Closes the FR-016
/// leak: a Windows operator's prior crashed run leaves staging dirs
/// full of partially-copied bytes directly in their footage
/// destinations; without a sweep these accumulate across runs and
/// the operator eventually sees them in Explorer, sometimes copies
/// them, sometimes mistakes them for footage.
///
/// **Design (post Codex round-25 simplification)**: the only check
/// that matters is `marker.host == Platform.localHostname`. The
/// previous design also probed PID liveness + executable path
/// matching, which created four classes of bug (cross-machine NAS
/// false-positive deletions, PID recycling false-positives, unused
/// recordedExe in the live-PID branch, macOS `ps -o comm=` returning
/// short names). All four collapse once we accept a load-bearing
/// invariant we already enforce upstream:
///
///   - The OS-level `InstanceLock` (`lib/utils/instance_lock.dart`)
///     guarantees AT MOST ONE Copiatorul3000 process running on this
///     machine at a time.
///   - This sweep runs ONCE at cold start, BEFORE
///     `JobQueueService` is constructed and BEFORE any new staging
///     dir can be created by this process.
///   - Therefore every staging dir whose marker says
///     `host=this-machine` was written by a CRASHED prior process —
///     definitionally orphaned — and is safe to delete.
///   - Foreign-host markers are silently preserved; we never reach
///     conclusions about another machine's processes.
///
/// **Roots collected**: distinct destinationPath of jobs in
/// non-terminal status (queued / paused / inProgress) UNION the last
/// 10 completed-or-failed jobs' destinationPaths. The completed/failed
/// set catches the operator who finished a run, crashed, then
/// re-launched — and includes both successful and failed terminations
/// (Codex round-25 P2 — including only the most-recent ANY-status row
/// could mask the most-recent SUCCESSFUL destination if a later failed
/// job displaced it).
///
/// **Unmounted roots** (drive ejected, network share offline) skip
/// silently — operator may have intentionally disconnected; a noisy
/// launch-time error every cold start would drown out signal.
///
/// **NAS-flake guard**: each root's `Directory.list()` is bounded by
/// a 2-second timeout. A pathologically slow network share doesn't
/// hang app startup; orphans on that root will be swept on the next
/// cold start once the share is responsive (Codex round-25 P1).
Future<void> sweepOrphanedStagingDirs(
  JobDao jobDao, {
  LogService? logService,
}) async {
  final roots = <String>{};
  final live = await jobDao.getJobsByStatuses({
    JobStatus.queued,
    JobStatus.paused,
    JobStatus.inProgress,
  });
  for (final j in live) {
    roots.add(j.destinationPath);
    // 019 T024 (FR-016, US5): also collect compressionOutputPath so
    // orphaned `.tmp_handbrake_copiatorul3000_*` dirs at the
    // compression destination get swept on next launch.
    if (j.compressionOutputPath != null && j.compressionOutputPath!.isNotEmpty) {
      roots.add(j.compressionOutputPath!);
    }
  }
  final recent = await jobDao.getRecentTerminalJobs(limit: 10);
  for (final j in recent) {
    roots.add(j.destinationPath);
    if (j.compressionOutputPath != null && j.compressionOutputPath!.isNotEmpty) {
      roots.add(j.compressionOutputPath!);
    }
  }

  final thisHost = Platform.localHostname;

  for (final root in roots) {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) continue;
    // 019 (Codex round-27b P2 #4): HandBrake compression preserves
    // the source folder hierarchy, so its staging dirs live at
    // `<root>/<relative-source-subpath>/.tmp_handbrake_copiatorul3000_*/`,
    // NOT at `<root>/.tmp_handbrake_*`. A non-recursive walk misses
    // them entirely. Robocopy staging dirs ARE at the root, but a
    // recursive walk catches them too (cheap, since once we identify
    // a staging dir we don't recurse INTO it).
    await _sweepRecursive(
      rootDir,
      thisHost: thisHost,
      logService: logService,
    );
  }
}

Future<void> _sweepRecursive(
  Directory dir, {
  required String thisHost,
  required LogService? logService,
}) async {
  final List<FileSystemEntity> children;
  try {
    children = await dir
        .list(followLinks: false)
        .toList()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    logService?.warning(
      'startup-sweep: list failed/timed-out for ${dir.path}: $e',
      phase: LogPhase.recover,
    );
    return;
  }
  for (final child in children) {
    if (child is! Directory) continue;
    final name = p.basename(child.path);
    // 019 T025 + round-27b P2 #4: matched staging dirs are deleted
    // (host check), then we DO NOT recurse into them. Unmatched dirs
    // get recursive descent so HandBrake's nested staging dirs are
    // discoverable.
    final isStaging = name.startsWith('.tmp_robocopy_') ||
        name.startsWith('.tmp_handbrake_copiatorul3000_');
    if (!isStaging) {
      await _sweepRecursive(
        child,
        thisHost: thisHost,
        logService: logService,
      );
      continue;
    }
    final markerOwner = await _readMarkerOwner(child);
    if (markerOwner != null && markerOwner.host != thisHost) {
      // Foreign machine's marker on a shared NAS root. Not our
      // problem; skip silently.
      continue;
    }
    try {
      await child.delete(recursive: true);
      logService?.info(
        'startup-sweep: removed orphan staging dir ${child.path} '
        '(marker: ${markerOwner ?? "absent"})',
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

/// Internal: parse the .live marker for diagnostic + host fields.
/// Null when the marker is absent, unreadable, or missing host=.
Future<_MarkerOwner?> _readMarkerOwner(Directory stagingDir) async {
  final markerFile = File(p.join(stagingDir.path, '.live'));
  if (!markerFile.existsSync()) return null;
  final String content;
  try {
    content = await markerFile.readAsString();
  } catch (_) {
    return null;
  }
  String? host;
  int? pid;
  String? exe;
  for (final line in content.split('\n')) {
    if (line.startsWith('host=')) {
      host = line.substring(5).trim();
    } else if (line.startsWith('pid=')) {
      pid = int.tryParse(line.substring(4).trim());
    } else if (line.startsWith('exe=')) {
      exe = line.substring(4).trim();
    }
  }
  if (host == null || host.isEmpty) return null;
  return _MarkerOwner(host: host, pid: pid, exe: exe);
}

class _MarkerOwner {
  final String host;
  final int? pid;
  final String? exe;
  _MarkerOwner({required this.host, this.pid, this.exe});

  @override
  String toString() => 'host=$host pid=$pid exe=$exe';
}
