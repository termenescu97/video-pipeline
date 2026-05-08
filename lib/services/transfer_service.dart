import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/constants.dart';
import '../utils/process_runner.dart';
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
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    if (!Platform.isWindows) return false;

    final sourceDir = p.dirname(sourceFile);
    final destDir = p.dirname(destinationFile);
    final fileName = p.basename(sourceFile);

    _fileStartTime = DateTime.now();
    _fileTotalBytes = await File(sourceFile).length();

    final exitCode = await _processRunner.run(
      executable: 'robocopy',
      arguments: [sourceDir, destDir, fileName, ...robocopyFlags],
      onStdoutLine: (line) {
        final event = RobocopyParser.parseLine(line);
        if (event != null) onProgress?.call(event);
      },
    );

    _fileStartTime = null;
    final result = RobocopyParser.parseExitCode(exitCode);
    return result.success;
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

    final runner = ProcessRunner();
    _activeHashRunners.add(runner);
    final captured = StringBuffer();
    final stderr = StringBuffer();
    try {
      final exitCode = await runner.run(
        executable: 'powershell',
        arguments: [
          '-NoProfile',
          '-Command',
          r'(Get-FileHash -LiteralPath $args[0] -Algorithm SHA256).Hash',
          filePath,
        ],
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
        // Final-review fix #7: surface the failure cause to the log
        // so post-mortem can distinguish "permission denied" from
        // "PowerShell missing" from "OOM".
        logService?.error(
          'computeFileHash exit=$exitCode for "$filePath"'
          '${stderr.isEmpty ? '' : ' — stderr: ${stderr.toString().trim()}'}',
        );
        return null;
      }
      final hash = captured.toString().trim();
      // SHA-256 hex is 64 chars; reject anything else as malformed.
      if (hash.length != 64) {
        logService?.error(
          'computeFileHash returned malformed output for "$filePath" '
          '(length=${hash.length}, expected 64)',
        );
        return null;
      }
      return hash;
    } catch (e, st) {
      // Final-review fix #7: catch the exception detail (was `catch (_)`
      // which lost the root cause). Log first three frames of stack so
      // operator can hand the log to support without re-running.
      logService?.error(
        'computeFileHash threw for "$filePath": $e\n'
        '${st.toString().split('\n').take(3).join('\n')}',
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
