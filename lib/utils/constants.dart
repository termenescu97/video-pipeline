/// Supported video file extensions for transfer and compression.
const videoExtensions = ['.mov', '.mp4'];

/// GitHub repository for update checking.
/// App version is single-sourced from pubspec.yaml via package_info_plus.
const githubRepo = 'termenescu97/video-pipeline';

/// Default robocopy flags for resumable transfer.
///
/// `/Z`     — restartable mode (resumable on network blip mid-invocation).
/// `/V`     — verbose, used by RobocopyParser to track per-file progress.
/// `/ETA`   — show ETA, parsed alongside the percentage stream.
/// `/R:3`   — retry up to 3 times on a transient failure.
/// `/W:5`   — wait 5 s between retries.
/// `/XN`    — eXclude Newer dest files (don't overwrite a newer dest).
/// `/XO`    — eXclude Older dest files (don't downgrade a newer dest).
/// `/XC`    — eXclude Changed dest files (different size, same time).
///
/// 015: `/XN /XC /XO` together mean "robocopy only copies when dest
/// does NOT exist." The executor in JobQueueService._processTransfer
/// is responsible for deleting the dest BEFORE invoking robocopy when
/// the operator explicitly approved overwrite (`wasOverwriteApproved`)
/// OR when we're resuming our own /Z partial fragment (`startedAt
/// != null` AND `destSize < sourceSize`). In every other case the
/// flags ensure robocopy does not silently overwrite.
const robocopyFlags = ['/Z', '/V', '/ETA', '/R:3', '/W:5', '/XN', '/XC', '/XO'];

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
