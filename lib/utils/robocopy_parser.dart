import '../utils/constants.dart';

/// Result of a robocopy operation.
class RobocopyResult {
  final int exitCode;
  final bool success;
  final String? error;

  RobocopyResult({
    required this.exitCode,
    required this.success,
    this.error,
  });
}

/// Parses robocopy stdout output and exit codes.
class RobocopyParser {
  /// Robocopy exit codes are bitmasks:
  /// 0 = No files copied, no errors
  /// 1 = Files copied successfully
  /// 2 = Extra files/dirs detected in destination
  /// 4 = Mismatched files/dirs detected
  /// 8+ = Copy errors occurred (FAILURE)
  static RobocopyResult parseExitCode(int exitCode) {
    if (exitCode < robocopyFailureThreshold) {
      return RobocopyResult(exitCode: exitCode, success: true);
    }
    return RobocopyResult(
      exitCode: exitCode,
      success: false,
      error: _describeExitCode(exitCode),
    );
  }

  static String _describeExitCode(int code) {
    final parts = <String>[];
    if (code & 8 != 0) parts.add('Copy errors occurred');
    if (code & 16 != 0) parts.add('Serious error — no files copied');
    if (parts.isEmpty) parts.add('Unknown error (code $code)');
    return parts.join('; ');
  }

  /// Parse a line of robocopy output to detect file completion.
  /// Robocopy outputs lines like:
  ///   New File     123456789   filename.mov
  ///   100%
  static FileProgressEvent? parseLine(String line) {
    final trimmed = line.trim();

    // Detect percentage line (intra-file progress).
    final percentMatch = RegExp(r'^(\d+(\.\d+)?)%').firstMatch(trimmed);
    if (percentMatch != null) {
      final percent = double.tryParse(percentMatch.group(1)!) ?? 0;
      return FileProgressEvent(type: ProgressType.percentage, percentage: percent);
    }

    // Detect new file starting.
    if (trimmed.contains('New File') || trimmed.contains('Newer')) {
      final parts = trimmed.split(RegExp(r'\s{2,}'));
      if (parts.length >= 3) {
        return FileProgressEvent(
          type: ProgressType.fileStarted,
          fileName: parts.last.trim(),
        );
      }
    }

    return null;
  }
}

enum ProgressType { percentage, fileStarted, fileCompleted }

class FileProgressEvent {
  final ProgressType type;
  final double? percentage;
  final String? fileName;

  FileProgressEvent({
    required this.type,
    this.percentage,
    this.fileName,
  });
}
