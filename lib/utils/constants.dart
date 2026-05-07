/// Supported video file extensions for transfer and compression.
const videoExtensions = ['.mov', '.mp4'];

/// GitHub repository for update checking.
/// App version is single-sourced from pubspec.yaml via package_info_plus.
const githubRepo = 'termenescu97/video-pipeline';

/// Default robocopy flags for resumable transfer.
const robocopyFlags = ['/Z', '/V', '/ETA', '/R:3', '/W:5'];

/// Robocopy exit codes: 0-7 = success, 8+ = failure.
const robocopyFailureThreshold = 8;

/// HandBrakeCLI progress regex pattern.
final handbrakeProgressPattern = RegExp(
  r'Encoding: task (\d+) of (\d+), ([\d.]+) %',
);

/// HandBrake presets file path on Windows.
const handbrakePresetsPath = r'%APPDATA%\HandBrake\presets.json';

/// Slack webhook timeout in milliseconds.
const slackTimeoutMs = 10000;
