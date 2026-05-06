import 'dart:io';

import 'package:path/path.dart' as p;

/// Simple file-based logger. Writes timestamped entries to copiatorul3000.log
/// next to the executable.
class LogService {
  late final File _logFile;
  IOSink? _sink;

  static const _maxSizeBytes = 10 * 1024 * 1024; // 10 MB
  static const _truncateToBytes = 5 * 1024 * 1024; // Keep last 5 MB

  /// Initialize the logger. Call once at app startup.
  Future<void> init() async {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    _logFile = File(p.join(exeDir, 'copiatorul3000.log'));

    // Truncate if over max size.
    if (await _logFile.exists()) {
      final size = await _logFile.length();
      if (size > _maxSizeBytes) {
        final content = await _logFile.readAsString();
        final truncated = content.substring(content.length - _truncateToBytes);
        await _logFile.writeAsString(truncated);
      }
    }

    _sink = _logFile.openWrite(mode: FileMode.append);
  }

  void _write(String level, String message) {
    final timestamp = DateTime.now().toIso8601String().replaceFirst('T', ' ').split('.').first;
    try {
      _sink?.writeln('[$timestamp] [$level] $message');
    } catch (_) {
      // Degrade gracefully if log file is locked.
    }
  }

  void info(String message) => _write('INFO', message);
  void warning(String message) => _write('WARN', message);
  void error(String message) => _write('ERROR', message);

  /// Flush and close the log file.
  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
