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

  /// Transfer a single file from source to destination using robocopy.
  /// Returns true on success, false on failure.
  ///
  /// Robocopy works on directories, so we pass the source directory and
  /// file filter to copy specific files.
  Future<bool> transferFile({
    required String sourceFile,
    required String destinationFile,
  }) async {
    if (!Platform.isWindows) return false;

    final sourceDir = p.dirname(sourceFile);
    final destDir = p.dirname(destinationFile);
    final fileName = p.basename(sourceFile);

    final process = await Process.start(
      'robocopy',
      [
        sourceDir,
        destDir,
        fileName,
        ...robocopyFlags,
      ],
    );

    // Stream stdout for progress parsing.
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen((data) {
      for (final line in data.split('\n')) {
        final event = RobocopyParser.parseLine(line);
        if (event != null) {
          onProgress?.call(event);
        }
      }
    });

    final exitCode = await process.exitCode;
    final result = RobocopyParser.parseExitCode(exitCode);
    return result.success;
  }

  /// Transfer all video files from a source directory to a destination directory.
  /// Returns the number of successfully transferred files.
  Future<int> transferDirectory({
    required String sourceDir,
    required String destDir,
  }) async {
    if (!Platform.isWindows) return 0;

    // Build file filter for video extensions.
    final fileFilters = videoExtensions.map((ext) => '*$ext').toList();

    final process = await Process.start(
      'robocopy',
      [
        sourceDir,
        destDir,
        ...fileFilters,
        '/S', // Include subdirectories (non-empty).
        ...robocopyFlags,
      ],
    );

    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen((data) {
      for (final line in data.split('\n')) {
        final event = RobocopyParser.parseLine(line);
        if (event != null) {
          onProgress?.call(event);
        }
      }
    });

    final exitCode = await process.exitCode;
    final result = RobocopyParser.parseExitCode(exitCode);
    return result.success ? 1 : 0;
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
