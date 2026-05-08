import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/constants.dart';
import '../utils/process_runner.dart';
import '../utils/ps_escape.dart';
import '../utils/robocopy_parser.dart';
import 'log_service.dart';

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
  /// 017 (Codex round-5 P1): when [destinationFile]'s basename differs
  /// from [sourceFile]'s basename, robocopy is run with the source
  /// basename (robocopy can't rename during copy) and a post-copy
  /// File.rename moves the result to the requested name. This is the
  /// load-bearing path for the case-only NTFS collision normalization
  /// (Codex H3); without it, a planned dest like `IMG_001_1.MOV` would
  /// land at `IMG_001.MOV` and re-collide with the first occurrence.
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    if (!Platform.isWindows) return false;

    final sourceDir = p.dirname(sourceFile);
    final destDir = p.dirname(destinationFile);
    final sourceBasename = p.basename(sourceFile);
    final destBasename = p.basename(destinationFile);

    _fileStartTime = DateTime.now();
    _fileTotalBytes = await File(sourceFile).length();

    final exitCode = await _processRunner.run(
      executable: 'robocopy',
      arguments: [sourceDir, destDir, sourceBasename, ...robocopyFlags],
      onStdoutLine: (line) {
        final event = RobocopyParser.parseLine(line);
        if (event != null) onProgress?.call(event);
      },
    );

    _fileStartTime = null;
    final result = RobocopyParser.parseExitCode(exitCode);
    if (!result.success) return false;

    // Post-copy rename when caller asked for a different basename
    // (case-collision normalization, conflict-rename resolution). Done
    // AFTER robocopy success so a failed copy doesn't leave the system
    // in a half-renamed state.
    if (sourceBasename != destBasename) {
      try {
        final copied = File(p.join(destDir, sourceBasename));
        await copied.rename(destinationFile);
      } on FileSystemException catch (e) {
        logService?.error(
          'Post-copy rename failed: $sourceBasename → $destBasename '
          '(${e.message})',
        );
        return false;
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
      final exitCode = await runner.runPowerShellInline(
        tag: 'computeFileHash',
        script:
            "(Get-FileHash -LiteralPath '${escapePsLiteral(filePath)}' -Algorithm SHA256).Hash",
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
