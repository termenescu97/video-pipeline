import 'dart:io';

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;

/// 017 (R-A6): canonical phase identifier for structured log entries.
/// Format: `[job=N file=K/total phase=X] message`. Bracket fields are
/// added independently per non-null parameter (8-case table in
/// `specs/017-executor-correctness/research.md`).
enum LogPhase {
  enqueue,
  preflight,
  transfer,
  verify,
  compress,
  finalize,
  recover,
  shutdown,
}

/// Simple file-based logger. Writes timestamped entries to copiatorul3000.log
/// next to the executable.
///
/// 017 (R-A6): named-param API adds optional `jobId, fileIndex, totalFiles,
/// phase` for structured triage. `error` additionally accepts
/// `subprocessStderr` for one-line, surrogate-pair-safe truncation
/// performed inside the LogService — callers never manually truncate.
/// Backward-compat: one-arg calls (`info('App started')`) continue to
/// produce a bare line with no context bracket.
class LogService {
  late final File _logFile;
  IOSink? _sink;

  static const _maxSizeBytes = 10 * 1024 * 1024; // 10 MB
  static const _truncateToBytes = 5 * 1024 * 1024; // Keep last 5 MB

  /// 017 (FR-012): max characters of subprocess stderr surfaced inline
  /// in error log lines, truncated by grapheme clusters (not raw UTF-16
  /// code units) to avoid splitting surrogate pairs.
  static const _maxStderrChars = 200;

  /// Resolved log file path. Surfaced to the Settings → Diagnostics
  /// panel so operators can copy it / open it in Explorer (T078).
  /// Reading before [init] returns the empty string.
  String get logPath {
    try {
      return _logFile.path;
    } catch (_) {
      return '';
    }
  }

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

  /// Build the structured-context bracket per the 8-case table in R-A6.
  /// Returns the empty string when no context fields are set.
  /// Field order is fixed: `job`, `file`, `phase`.
  static String _formatContext({
    int? jobId,
    int? fileIndex,
    int? totalFiles,
    LogPhase? phase,
  }) {
    final parts = <String>[];
    if (jobId != null) parts.add('job=$jobId');
    // Both fileIndex and totalFiles must be set for the file=K/total bracket
    // to render. Either alone is treated as missing both (R-A6 table).
    if (fileIndex != null && totalFiles != null) {
      parts.add('file=$fileIndex/$totalFiles');
    }
    if (phase != null) parts.add('phase=${phase.name}');
    if (parts.isEmpty) return '';
    return ' [${parts.join(' ')}]';
  }

  /// 017 (FR-012): truncate stderr to a single line of at most 200
  /// grapheme clusters. Empty stderr produces an empty string (caller
  /// skips the colon when wrapping into the formatted line).
  static String _truncateStderr(String stderr) {
    if (stderr.isEmpty) return '';
    // CRLF: split('\n').first leaves trailing \r; trim() removes it.
    final firstLine = stderr.split('\n').first.trim();
    if (firstLine.isEmpty) return '';
    // Take by grapheme clusters (the .characters extension); avoids
    // splitting a UTF-16 surrogate pair when stderr contains emoji or
    // non-BMP code points.
    final chars = firstLine.characters;
    if (chars.length <= _maxStderrChars) return firstLine;
    return '${chars.take(_maxStderrChars).toString()}…';
  }

  /// 017 (R-A6): pure line formatter, exposed for golden tests. Composes
  /// `[timestamp] [LEVEL][ctx] message[: stderr-tail]` per the format
  /// table. Caller supplies the timestamp so tests can pin a fixed value.
  static String formatEntry({
    required String timestamp,
    required String level,
    required String message,
    int? jobId,
    int? fileIndex,
    int? totalFiles,
    LogPhase? phase,
    String? subprocessStderr,
  }) {
    final ctx = _formatContext(
      jobId: jobId,
      fileIndex: fileIndex,
      totalFiles: totalFiles,
      phase: phase,
    );
    final tail = (subprocessStderr == null || subprocessStderr.isEmpty)
        ? ''
        : ': ${_truncateStderr(subprocessStderr)}';
    return '[$timestamp] [$level]$ctx $message$tail';
  }

  void _writeLine(String level, String message,
      {int? jobId,
      int? fileIndex,
      int? totalFiles,
      LogPhase? phase,
      String? subprocessStderr}) {
    final timestamp =
        DateTime.now().toIso8601String().replaceFirst('T', ' ').split('.').first;
    final line = formatEntry(
      timestamp: timestamp,
      level: level,
      message: message,
      jobId: jobId,
      fileIndex: fileIndex,
      totalFiles: totalFiles,
      phase: phase,
      subprocessStderr: subprocessStderr,
    );
    try {
      _sink?.writeln(line);
    } catch (_) {
      // Degrade gracefully if log file is locked.
    }
  }

  void info(
    String message, {
    int? jobId,
    int? fileIndex,
    int? totalFiles,
    LogPhase? phase,
  }) =>
      _writeLine('INFO', message,
          jobId: jobId,
          fileIndex: fileIndex,
          totalFiles: totalFiles,
          phase: phase);

  void warning(
    String message, {
    int? jobId,
    int? fileIndex,
    int? totalFiles,
    LogPhase? phase,
  }) =>
      _writeLine('WARN', message,
          jobId: jobId,
          fileIndex: fileIndex,
          totalFiles: totalFiles,
          phase: phase);

  void error(
    String message, {
    int? jobId,
    int? fileIndex,
    int? totalFiles,
    LogPhase? phase,
    String? subprocessStderr,
  }) =>
      _writeLine('ERROR', message,
          jobId: jobId,
          fileIndex: fileIndex,
          totalFiles: totalFiles,
          phase: phase,
          subprocessStderr: subprocessStderr);

  /// Flush and close the log file.
  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
