import 'dart:io';

/// Shared utility for starting a subprocess and streaming its output line-by-line.
class ProcessRunner {
  Process? _process;

  /// Start a process, stream stdout and stderr through a line parser, return exit code.
  Future<int> run({
    required String executable,
    required List<String> arguments,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    _process = await Process.start(executable, arguments);
    final process = _process!;

    if (onStdoutLine != null) {
      process.stdout.transform(const SystemEncoding().decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) onStdoutLine(line);
        }
      });
    }

    if (onStderrLine != null) {
      process.stderr.transform(const SystemEncoding().decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) onStderrLine(line);
        }
      });
    }

    final exitCode = await process.exitCode;
    _process = null;
    return exitCode;
  }

  /// Kill the running process.
  void kill() {
    _process?.kill();
    _process = null;
  }
}
