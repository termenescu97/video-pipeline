import '../utils/constants.dart';

/// Parsed progress from HandBrakeCLI stdout.
class HandbrakeProgress {
  final int currentTask;
  final int totalTasks;
  final double percentage;
  final double? fps;
  final double? avgFps;
  final String? eta;

  HandbrakeProgress({
    required this.currentTask,
    required this.totalTasks,
    required this.percentage,
    this.fps,
    this.avgFps,
    this.eta,
  });
}

/// Parses HandBrakeCLI stdout for progress information.
///
/// HandBrakeCLI outputs lines like:
/// `Encoding: task 1 of 1, 13.25 % (49.87 fps, avg 62.48 fps, ETA 00h33m34s)`
class HandbrakeParser {
  /// Parse a single line of HandBrakeCLI output.
  /// Returns null if the line doesn't contain progress info.
  static HandbrakeProgress? parseLine(String line) {
    final match = handbrakeProgressPattern.firstMatch(line);
    if (match == null) return null;

    final currentTask = int.tryParse(match.group(1)!) ?? 1;
    final totalTasks = int.tryParse(match.group(2)!) ?? 1;
    final percentage = double.tryParse(match.group(3)!) ?? 0;

    // Parse optional fps and ETA.
    double? fps;
    double? avgFps;
    String? eta;

    final fpsMatch = RegExp(r'([\d.]+) fps').firstMatch(line);
    if (fpsMatch != null) {
      fps = double.tryParse(fpsMatch.group(1)!);
    }

    final avgFpsMatch = RegExp(r'avg ([\d.]+) fps').firstMatch(line);
    if (avgFpsMatch != null) {
      avgFps = double.tryParse(avgFpsMatch.group(1)!);
    }

    final etaMatch = RegExp(r'ETA (\d+h\d+m\d+s)').firstMatch(line);
    if (etaMatch != null) {
      eta = etaMatch.group(1);
    }

    return HandbrakeProgress(
      currentTask: currentTask,
      totalTasks: totalTasks,
      percentage: percentage,
      fps: fps,
      avgFps: avgFps,
      eta: eta,
    );
  }
}
