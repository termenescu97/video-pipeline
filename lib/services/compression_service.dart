import 'dart:convert';
import 'dart:io';

import '../utils/handbrake_parser.dart';

/// Callback for reporting compression progress.
typedef CompressionProgressCallback = void Function(HandbrakeProgress progress);

/// Orchestrates video compression via HandBrakeCLI subprocess.
class CompressionService {
  CompressionProgressCallback? onProgress;
  Process? _currentProcess;

  /// Kill the currently running subprocess.
  void cancel() {
    _currentProcess?.kill();
    _currentProcess = null;
  }

  /// Compress a single file using HandBrakeCLI with the given preset.
  /// Returns true on success, false on failure.
  Future<bool> compressFile({
    required String inputFile,
    required String outputFile,
    required String presetName,
  }) async {
    if (!Platform.isWindows) return false;

    final process = await Process.start(
      'HandBrakeCLI.exe',
      ['-i', inputFile, '-o', outputFile, '--preset', presetName],
    );
    _currentProcess = process;

    // Stream stderr for progress (HandBrakeCLI outputs progress to stderr).
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((data) {
      for (final line in data.split('\n')) {
        final progress = HandbrakeParser.parseLine(line);
        if (progress != null) {
          onProgress?.call(progress);
        }
      }
    });

    // Also check stdout for progress (some versions output there).
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen((data) {
      for (final line in data.split('\n')) {
        final progress = HandbrakeParser.parseLine(line);
        if (progress != null) {
          onProgress?.call(progress);
        }
      }
    });

    final exitCode = await process.exitCode;
    _currentProcess = null;
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

      // HandBrake presets.json structure: array of preset objects with "PresetName".
      if (data is List) {
        return _extractPresetNames(data);
      }
      // Some versions wrap in a top-level object with "PresetList".
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
        // Direct preset.
        if (preset.containsKey('PresetName')) {
          names.add(preset['PresetName'] as String);
        }
        // Category with children.
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
