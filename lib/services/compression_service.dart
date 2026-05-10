import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../utils/handbrake_parser.dart';
import '../utils/process_runner.dart';
import 'log_service.dart';

/// Callback for reporting compression progress.
typedef CompressionProgressCallback = void Function(HandbrakeProgress progress);

/// Orchestrates video compression via HandBrakeCLI subprocess.
class CompressionService {
  CompressionProgressCallback? onProgress;

  /// Optional logger for staging cleanup failures.
  LogService? logService;

  final ProcessRunner _processRunner;

  CompressionService({
    @visibleForTesting ProcessRunner? processRunner,
  }) : _processRunner = processRunner ?? ProcessRunner();

  /// Kill the currently running subprocess.
  void cancel() {
    _processRunner.kill();
  }

  /// 019 T023 (FR-013 — FR-017, US5): compress a single file using
  /// HandBrakeCLI with the given preset. Returns true on success.
  ///
  /// Mirrors the robocopy staging-dir convention from 018. Writes into
  /// a sibling staging directory `<dirname>/.tmp_handbrake_copiatorul3000_<tag>/`,
  /// then atomic-renames the staged output to the final path on success.
  /// On cancel/failure the staging dir is deleted, leaving no partial
  /// `.mp4` at the destination. Codex round-27a P2 fix: the rename
  /// itself is wrapped in try/catch — if rename fails (e.g., destination
  /// exists from a race, permission error), the staging file is deleted
  /// before the failure propagates, so we don't leak partial bytes.
  ///
  /// The more-specific `.tmp_handbrake_copiatorul3000_*` prefix
  /// (Codex round-27a P2) drastically reduces sweep false-positive
  /// surface vs. a bare `.tmp_handbrake_*` matcher.
  Future<bool> compressFile({
    required String inputFile,
    required String outputFile,
    required String presetName,
  }) async {
    final outputDir = p.dirname(outputFile);
    final outputBasename = p.basename(outputFile);
    final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final stagingDir = Directory(
      p.join(outputDir, '.tmp_handbrake_copiatorul3000_$tag'),
    );
    await stagingDir.create(recursive: true);

    // .live marker — same convention as 018 T026 (host as load-bearing
    // field for the cold-start sweep). Inner try/catch on cleanup so a
    // delete failure doesn't mask the original marker-write failure.
    final markerFile = File(p.join(stagingDir.path, '.live'));
    try {
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
          'Compression marker write failed AND cleanup failed: $cleanupError',
          phase: LogPhase.compress,
        );
      }
      Error.throwWithStackTrace(markerError, markerStack);
    }

    void parseLine(String line) {
      final progress = HandbrakeParser.parseLine(line);
      if (progress != null) onProgress?.call(progress);
    }

    final stagingOutput = p.join(stagingDir.path, outputBasename);
    final exitCode = await _processRunner.run(
      executable: 'HandBrakeCLI.exe',
      arguments: [
        '-i',
        inputFile,
        '-o',
        stagingOutput,
        '--preset',
        presetName,
      ],
      onStdoutLine: parseLine,
      onStderrLine: parseLine,
    );

    if (exitCode == 0) {
      // Codex round-27a P2 fix: wrap rename in try/catch so a rename
      // failure doesn't leave the staged bytes orphaned at the
      // staging path (the success path's cleanup would still run,
      // but the staged file would have already been moved out — if
      // the move itself throws, the file is still in staging).
      try {
        await File(stagingOutput).rename(outputFile);
      } catch (renameError, renameStack) {
        try {
          await File(stagingOutput).delete();
        } catch (_) { /* best-effort */ }
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) { /* best-effort */ }
        Error.throwWithStackTrace(renameError, renameStack);
      }
      // Best-effort staging dir cleanup, split per 018 round-11 P3.
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {
        logService?.warning(
          'Compression staging cleanup left empty dir at ${stagingDir.path}',
          phase: LogPhase.compress,
        );
      }
      return true;
    }

    // Non-zero exit (failure / cancel): delete the staging dir, return
    // false. Operator never sees a partial .mp4 at the destination.
    try {
      await stagingDir.delete(recursive: true);
    } catch (_) { /* best-effort; sweep handles next launch */ }
    return false;
  }

  /// Read available presets from HandBrake's presets.json file.
  Future<List<String>> getAvailablePresets() async {
    if (!Platform.isWindows) return [];

    final appData = Platform.environment['APPDATA'];
    if (appData == null) return [];

    final presetsFile = File('$appData\\HandBrake\\presets.json');
    if (!await presetsFile.exists()) return [];

    try {
      final content = await presetsFile.readAsString();
      final dynamic data = jsonDecode(content);

      if (data is List) {
        return _extractPresetNames(data);
      }
      if (data is Map && data.containsKey('PresetList')) {
        return _extractPresetNames(data['PresetList'] as List);
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  List<String> _extractPresetNames(List<dynamic> presets) {
    final names = <String>[];
    for (final preset in presets) {
      if (preset is Map) {
        if (preset.containsKey('PresetName')) {
          names.add(preset['PresetName'] as String);
        }
        if (preset.containsKey('ChildrenArray')) {
          final children = preset['ChildrenArray'] as List;
          for (final child in children) {
            if (child is Map && child.containsKey('PresetName')) {
              names.add(child['PresetName'] as String);
            }
          }
        }
      }
    }
    return names;
  }

  /// Check if HandBrakeCLI is available on the system.
  Future<bool> isHandbrakeInstalled() async {
    if (!Platform.isWindows) return false;

    try {
      final result = await Process.run('HandBrakeCLI.exe', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
