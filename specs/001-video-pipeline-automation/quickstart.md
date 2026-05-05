# Quickstart: Video Pipeline Automation

## Prerequisites

- Flutter SDK (stable channel, latest)
- Dart SDK (included with Flutter)
- Git
- A Windows 11 machine (for testing) or GitHub Actions (for CI builds)

## Setup (Development - macOS)

```bash
# Clone the repo
git clone <repo-url>
cd video-pipeline-automation

# Get dependencies
flutter pub get

# Generate drift database code
dart run build_runner build

# Run the app (macOS for development — UI layout only, subprocess features won't work)
flutter run -d macos
```

## Setup (Target - Windows 11)

```powershell
# Ensure HandBrakeCLI is installed and in PATH
HandBrakeCLI.exe --version

# Run the built executable
./video_pipeline.exe
```

## First Run Configuration

1. Launch the app
2. Go to Settings
3. Enter Slack webhook URL
4. (Optional) Save favorite paths for quick job creation

## Building for Windows (via GitHub Actions)

Push to the repo. GitHub Actions will:
1. Build the Windows executable
2. Create a GitHub Release
3. Attach the `.exe` as a release asset

The app on the target machine will detect the new release on next launch and prompt to update.

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `win32` | Windows API access (drive detection) |
| `device_manager` | USB hot-plug event monitoring |
| `drift` + `sqflite_common_ffi` | SQLite database (job queue persistence) |
| `dio` | HTTP client (Slack webhooks, GitHub API) |
| `auto_updater` or custom | App update checking |
| `flutter_riverpod` or `bloc` | State management |

## Project Structure

```
lib/
├── main.dart
├── app.dart
├── models/              # Drift database schema
├── services/            # Business logic
│   ├── drive_service.dart
│   ├── transfer_service.dart
│   ├── compression_service.dart
│   ├── slack_service.dart
│   └── update_service.dart
├── ui/                  # Flutter widgets
│   ├── screens/
│   ├── widgets/
│   └── theme/
└── utils/               # Helpers, constants
```
