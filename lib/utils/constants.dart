/// Supported video file extensions for transfer and compression.
const videoExtensions = ['.mov', '.mp4'];

/// App version — used for update checking against GitHub Releases.
const appVersion = '1.0.0';

/// GitHub repository for update checking.
const githubRepo = 'YOUR_ORG/video-pipeline';

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
