import 'dart:convert';
import 'dart:io';

import '../utils/handbrake_parser.dart';
import '../utils/process_runner.dart';

/// Callback for reporting compression progress.
typedef CompressionProgressCallback = void Function(HandbrakeProgress progress);

/// Orchestrates video compression via HandBrakeCLI subprocess.
class CompressionService {
  CompressionProgressCallback? onProgress;
  final _processRunner = ProcessRunner();

  /// Kill the currently running subprocess.
  void cancel() {
    _processRunner.kill();
  }

  /// Compress a single file using HandBrakeCLI with the given preset.
  /// Returns true on success, false on failure.
  Future<bool> compressFile({
    required String inputFile,
    required String outputFile,
    required String presetName,
  }) async {
    if (!Platform.isWindows) return false;

    void parseLine(String line) {
      final progress = HandbrakeParser.parseLine(line);
      if (progress != null) onProgress?.call(progress);
    }

    final exitCode = await _processRunner.run(
      executable: 'HandBrakeCLI.exe',
      arguments: ['-i', inputFile, '-o', outputFile, '--preset', presetName],
      onStdoutLine: parseLine,
      onStderrLine: parseLine,
    );

    return exitCode == 0;
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
