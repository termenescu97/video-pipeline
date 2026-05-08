import 'dart:io';

/// 017 (FR-001 enforcement): the only valid argv shape for `powershell -Command`.
/// Length MUST be 3: `['-NoProfile', '-Command', <script>]`. Any 4th element
/// is silently dropped by PowerShell because `-Command` does not populate
/// `$args` from trailing argv. Embed values via single-quoted `-LiteralPath`
/// + `escapePsLiteral` instead.
List<String> argsForPowerShellInlineScript(String script) {
  return ['-NoProfile', '-Command', script];
}

/// Shared utility for starting a subprocess and streaming its output line-by-line.
class ProcessRunner {
  Process? _process;

  /// Inline-script PowerShell invocation with the length-3 argv invariant
  /// (FR-001 enforcement). Use [escapePsLiteral] to embed paths inside
  /// single-quoted `-LiteralPath` literals in the [script]. The [tag] is
  /// surfaced in any error logging by callers; this helper does not log.
  ///
  /// Per Codex H1 (v2.4.0 root cause): trailing argv after `-Command` is
  /// silently dropped, so we assert the argv length here at runtime in
  /// addition to the unit test that asserts it on macOS dev machines.
  Future<int> runPowerShellInline({
    required String script,
    required String tag,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    final args = argsForPowerShellInlineScript(script);
    assert(args.length == 3,
        'runPowerShellInline argv length is ${args.length}, must be 3 (FR-001)');
    if (args.length != 3) {
      throw StateError(
          'runPowerShellInline argv length is ${args.length}; expected 3 — '
          'embed values via single-quoted -LiteralPath, not as a 4th argv element. (FR-001 / tag=$tag)');
    }
    return run(
      executable: 'powershell',
      arguments: args,
      onStdoutLine: onStdoutLine,
      onStderrLine: onStderrLine,
    );
  }

  /// Start a process, stream stdout and stderr through a line parser, return exit code.
  Future<int> run({
    required String executable,
    required List<String> arguments,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    _process = await Process.start(executable, arguments);
    final process = _process!;

    // Always drain both streams to prevent OS pipe buffer overflow (~64KB on
    // Windows). When no callback is provided, drain into a sink that discards
    // the data — keeping the stream consumed without invoking a callback.
    final stdoutDone = process.stdout
        .transform(const SystemEncoding().decoder)
        .forEach((data) {
      if (onStdoutLine == null) return;
      for (final line in data.split('\n')) {
        if (line.trim().isNotEmpty) onStdoutLine(line);
      }
    });

    final stderrDone = process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach((data) {
      if (onStderrLine == null) return;
      for (final line in data.split('\n')) {
        if (line.trim().isNotEmpty) onStderrLine(line);
      }
    });

    await Future.wait([stdoutDone, stderrDone]);
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
