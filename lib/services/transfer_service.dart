import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/constants.dart';
import '../utils/robocopy_parser.dart';

/// Callback for reporting transfer progress.
typedef TransferProgressCallback = void Function(FileProgressEvent event);

/// Orchestrates file transfer via robocopy subprocess.
/// Uses /Z flag for resumable transfers.
class TransferService {
  TransferProgressCallback? onProgress;
  Process? _currentProcess;
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

    final process = await Process.start(
      'robocopy',
      [sourceDir, destDir, fileName, ...robocopyFlags],
    );
    _currentProcess = process;

    process.stdout.transform(const SystemEncoding().decoder).listen((data) {
      for (final line in data.split('\n')) {
        final event = RobocopyParser.parseLine(line);
        if (event != null) {
          onProgress?.call(event);
        }
      }
    });

    final exitCode = await process.exitCode;
    _currentProcess = null;
    _fileStartTime = null;
    final result = RobocopyParser.parseExitCode(exitCode);
    return result.success;
  }

  /// Kill the currently running subprocess.
  void cancel() {
    _currentProcess?.kill();
    _currentProcess = null;
    _fileStartTime = null;
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
