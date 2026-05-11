import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../utils/constants.dart';
import '../utils/process_runner.dart';
import '../utils/ps_escape.dart';
import '../utils/robocopy_parser.dart';
import 'log_service.dart';

/// 019 T029 (FR-019, US7): prepend `\\?\` to paths > 240 chars for use
/// with PowerShell `Get-FileHash -LiteralPath`.
///
/// PowerShell 5.1 (the default on Windows 11 without explicit upgrade)
/// cannot read paths > 260 chars without this prefix — long-path
/// files would otherwise fail `Get-FileHash` forever, leaving the
/// operator stuck in `verifyStatus=unverified` retry loop with no
/// recovery path. The 240 threshold leaves headroom for any prefix-
/// handling quirks (the prefix itself is 4 chars; the buffer covers
/// PowerShell's internal limits).
///
/// **Scope**: PowerShell-specific. Do NOT propagate the prefix into
/// robocopy/HandBrake argv — those have their own long-path handling
/// on Windows 10+ and the `\\?\` prefix changes path semantics they
/// don't accept (no `..` resolution, no relative paths, no `/`).
///
/// **Codex round-27a P2 follow-up**: this Dart-side prefix construction
/// is verified by [test/unit/long_path_hash_test.dart] for the
/// shape-level invariants (prefix added past threshold, omitted
/// below). Whether PS 5.1 actually accepts the prefixed path under
/// `-LiteralPath` semantics requires Windows-side manual verification
/// (operator T067 step in RELEASE_NOTES).
@visibleForTesting
String longPathPrefixed(String path) =>
    path.length > 240 ? r'\\?\' + path : path;

/// Callback for reporting transfer progress.
typedef TransferProgressCallback = void Function(FileProgressEvent event);

/// Orchestrates file transfer via robocopy subprocess.
/// Uses /Z flag for resumable transfers.
class TransferService {
  TransferProgressCallback? onProgress;

  /// Optional logger for subprocess errors that would otherwise be
  /// invisible (final-review fix #7). When wired by main.dart, hash
  /// computation exceptions are persisted to copiatorul3000.log with
  /// their root cause instead of being swallowed.
  LogService? logService;

  final _processRunner = ProcessRunner();
  // Active SHA-256 hash subprocesses. We track every concurrent hash so
  // [cancel] can kill all of them — source/destination hashes commonly
  // run in parallel (different physical drives) and a single shared
  // runner would race the second call over the first's process handle.
  final Set<ProcessRunner> _activeHashRunners = <ProcessRunner>{};
  DateTime? _fileStartTime;
  int _fileTotalBytes = 0;

  /// The start time of the current file transfer (for ETA calculation).
  DateTime? get fileStartTime => _fileStartTime;

  /// Total bytes of the current file being transferred.
  int get fileTotalBytes => _fileTotalBytes;

  /// Transfer a single file from source to destination using robocopy.
  /// Returns true on success, false on failure.
  ///
  /// 017 (Codex round-5 P1 + round-7 P1): when [destinationFile]'s
  /// basename differs from [sourceFile]'s basename (case-collision
  /// normalization, conflict-rename resolution), robocopy can't rename
  /// during copy. Naively running robocopy with the source basename
  /// into the dest dir would target `destDir/sourceBasename` — which
  /// might be the very file that triggered the conflict-rename. The
  /// follow-up File.rename would then move that pre-existing conflict
  /// file to the requested dest, destroying the operator's data.
  ///
  /// Fix: when basenames differ, copy into a staging subdirectory
  /// (`destDir/.tmp_${random}/sourceBasename`) so the operation can't
  /// touch any pre-existing file in destDir. After robocopy success,
  /// File.rename moves the staged file to the final destinationFile
  /// path, then the staging dir is removed.
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    if (!Platform.isWindows) return false;

    final sourceDir = p.dirname(sourceFile);
    final destDir = p.dirname(destinationFile);
    final sourceBasename = p.basename(sourceFile);
    final destBasename = p.basename(destinationFile);
    final needsRename = sourceBasename != destBasename;

    _fileStartTime = DateTime.now();
    _fileTotalBytes = await File(sourceFile).length();

    // Stage into a private subdirectory ONLY when the caller asked
    // for a renamed destination. Common case (basenames match) keeps
    // the original direct robocopy path with zero overhead.
    final String robocopyDestDir;
    Directory? stagingDir;
    if (needsRename) {
      final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      stagingDir = Directory(p.join(destDir, '.tmp_robocopy_$tag'));
      await stagingDir.create(recursive: true);
      // 018 T026 (FR-016, US6): write a `.live` marker so the startup
      // sweeper (T027) can distinguish staging dirs left by THIS
      // running process (must NOT delete) from orphaned staging dirs
      // left by a prior crashed run on this machine (safe to delete).
      // The marker holds the OS PID + the executable path; the sweeper
      // verifies both before treating the dir as live. Inner try/catch
      // on cleanup so a delete failure doesn't mask the original
      // marker-write failure (Codex round-23 P2). The
      // `Error.throwWithStackTrace` preserves the original stack so the
      // log triage points at the marker write, not the rethrow site.
      final markerFile = File(p.join(stagingDir.path, '.live'));
      try {
        // Codex round-25 redesign: `host=` is the load-bearing field
        // for sweep decisions. Cross-machine NAS scenario — machine A
        // creates `.tmp_robocopy_*` on a shared NAS, machine B's cold-
        // start sweep MUST NOT delete it. host-mismatch is a silent
        // skip; pid+exe are kept for log triage on cleanup of OUR-host
        // orphans only. The single-instance lock + sweep-runs-before-
        // any-new-marker invariant means every same-host marker found
        // at cold-start is by definition orphaned (no other live
        // Copiatorul3000 on this machine; sweep finishes before this
        // process writes any markers of its own).
        await markerFile.writeAsString(
          'host=${Platform.localHostname}\n'
          'pid=$pid\n'
          'exe=${Platform.resolvedExecutable}\n',
          flush: true,
        );
      } catch (markerError, markerStack) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (cleanupError) {
          logService?.warning(
            'Marker write failed AND cleanup failed: $cleanupError',
            phase: LogPhase.transfer,
          );
        }
        Error.throwWithStackTrace(markerError, markerStack);
      }
      robocopyDestDir = stagingDir.path;
    } else {
      robocopyDestDir = destDir;
    }

    final exitCode = await _processRunner.run(
      executable: 'robocopy',
      arguments: [sourceDir, robocopyDestDir, sourceBasename, ...robocopyFlags],
      onStdoutLine: (line) {
        final event = RobocopyParser.parseLine(line);
        if (event != null) onProgress?.call(event);
      },
    );

    _fileStartTime = null;
    final result = RobocopyParser.parseExitCode(exitCode);
    if (!result.success) {
      if (stagingDir != null) {
        try {
          await stagingDir.delete(recursive: true);
        } on FileSystemException catch (e) {
          logService?.warning(
              'Staging dir cleanup after failed copy: ${e.message}');
        }
      }
      return false;
    }

    if (needsRename) {
      // Codex round-8 P2 #1: resumed renamed transfer. If the prior
      // run successfully renamed the staged file into destinationFile
      // then crashed before markFileCompleted, the next pass'
      // pre-robocopy safety section sees everAttempted=true +
      // isPartial=false (size match) and falls into the "size matches
      // on resumed file — letting robocopy skip + verification
      // confirm idempotently" branch. transferFile still runs;
      // robocopy copies a fresh copy into the staging dir; then this
      // rename fails on Windows because target already exists. Treat
      // size-matching pre-existing target as the prior run's
      // completion and just discard the duplicate staged copy.
      final staged = File(p.join(robocopyDestDir, sourceBasename));
      final target = File(destinationFile);
      try {
        if (await target.exists() &&
            await target.length() == await staged.length()) {
          await staged.delete();
          logService?.info(
            'Resumed renamed transfer: target $destBasename already '
            'matches source size — keeping existing dest, discarding '
            'staged duplicate',
          );
        } else {
          await staged.rename(destinationFile);
        }
      } on FileSystemException catch (e) {
        logService?.error(
          'Post-copy rename failed: $sourceBasename → $destBasename '
          '(${e.message})',
        );
        // Best-effort staging cleanup before returning failure.
        try {
          await stagingDir!.delete(recursive: true);
        } on FileSystemException catch (_) {}
        return false;
      }

      // Codex round-11 P3: staging-dir cleanup is a separate concern
      // from the rename's success. The file is already at
      // destinationFile by now; a failed rmdir leaves a cosmetic
      // empty dir but does NOT mean the transfer failed. Without this
      // split, an antivirus lock or transient permission glitch on
      // the empty dir would mark a successful copy as failed.
      try {
        await stagingDir!.delete(recursive: true);
      } on FileSystemException catch (e) {
        logService?.warning(
          'Staging dir cleanup left an empty dir at ${stagingDir!.path} '
          '(${e.message}) — transfer succeeded; cosmetic leak only',
        );
      }
    }
    return true;
  }

  /// Kill any currently running transfer or hash subprocess.
  void cancel() {
    _processRunner.kill();
    // Snapshot to avoid concurrent-modification while runners self-remove.
    for (final runner in _activeHashRunners.toList()) {
      runner.kill();
    }
    _fileStartTime = null;
  }

  /// Compute SHA-256 hash of a file using PowerShell Get-FileHash.
  ///
  /// Each invocation owns a dedicated [ProcessRunner] so parallel hashing
  /// of source and destination is safe — see [_activeHashRunners]. The
  /// runner is registered while the subprocess is alive so [cancel] can
  /// kill it; deregistered on completion or error.
  ///
  /// Returns the hex hash string, or null on non-Windows / cancellation /
  /// failure.
  Future<String?> computeFileHash(String filePath) async {
    if (!Platform.isWindows) return null;

    // 017 (FR-001): caller-side validation. Empty path is a programmer error
    // upstream; reject loudly rather than emitting an unparseable PS command.
    if (filePath.isEmpty) {
      logService?.error('computeFileHash called with empty path');
      return null;
    }

    final runner = ProcessRunner();
    _activeHashRunners.add(runner);
    final captured = StringBuffer();
    final stderr = StringBuffer();
    try {
      // 017 (R-A1): single-quoted -LiteralPath inside the -Command script
      // string. PS single-quoted literals don't expand $var or backticks;
      // doubling the only literal-special char (') closes injection. Length-3
      // argv invariant enforced by runPowerShellInline.
      //
      // 019 T029 (FR-019, US7): paths > 240 chars get the `\\?\` long-path
      // prefix. See [longPathPrefixed] for full rationale.
      final pathForPS = longPathPrefixed(filePath);
      final exitCode = await runner.runPowerShellInline(
        tag: 'computeFileHash',
        script:
            "(Get-FileHash -LiteralPath '${escapePsLiteral(pathForPS)}' -Algorithm SHA256).Hash",
        onStdoutLine: (line) {
          final t = line.trim();
          if (t.isNotEmpty) captured.writeln(t);
        },
        onStderrLine: (line) {
          final t = line.trim();
          if (t.isNotEmpty) stderr.writeln(t);
        },
      );
      if (exitCode != 0) {
        // 017 (FR-012): pass raw stderr via subprocessStderr; LogService
        // handles single-line truncation to 200 grapheme clusters.
        // Distinguishes "permission denied" from "PS missing" without
        // dumping a 6-line parser error.
        logService?.error(
          'computeFileHash exit=$exitCode for "$filePath"',
          phase: LogPhase.verify,
          subprocessStderr: stderr.isEmpty ? null : stderr.toString(),
        );
        return null;
      }
      final hash = captured.toString().trim();
      // SHA-256 hex is 64 chars; reject anything else as malformed.
      if (hash.length != 64) {
        logService?.error(
          'computeFileHash returned malformed output for "$filePath" '
          '(length=${hash.length}, expected 64)',
          phase: LogPhase.verify,
        );
        return null;
      }
      return hash;
    } catch (e, st) {
      // Final-review fix #7: catch the exception detail (was `catch (_)`
      // which lost the root cause). Stack frames passed via subprocessStderr
      // so LogService truncates to one line — full stack would still be
      // a multi-line dump otherwise.
      final stackPreview = st.toString().split('\n').take(3).join(' | ');
      logService?.error(
        'computeFileHash threw for "$filePath": $e',
        phase: LogPhase.verify,
        subprocessStderr: stackPreview,
      );
      return null;
    } finally {
      _activeHashRunners.remove(runner);
    }
  }

  /// Verify a transferred file by comparing file sizes.
  Future<bool> verifyTransfer({
    required String sourceFile,
    required String destinationFile,
  }) async {
    final source = File(sourceFile);
    final dest = File(destinationFile);

    if (!await source.exists() || !await dest.exists()) return false;

    final sourceSize = await source.length();
    final destSize = await dest.length();
    return sourceSize == destSize;
  }
}
