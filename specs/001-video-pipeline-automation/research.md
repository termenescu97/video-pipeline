# Research: Video Pipeline Automation

## Drive Detection on Windows (Flutter/Dart)

**Decision**: Use `win32` package with `GetLogicalDrives()` + `GetDriveType()` for enumeration, and `device_manager` package for real-time USB insertion/removal events.

**Rationale**: Native Win32 APIs are the most reliable way to detect removable drives. `GetDriveType()` returns `DRIVE_REMOVABLE` for SD cards in USB hubs. The `device_manager` package handles `WM_DEVICECHANGE` messages for live monitoring.

**Alternatives considered**:
- Polling filesystem periodically — works but wasteful and has latency
- Platform channels with custom C++ — unnecessary when `win32` package exists

## Robocopy Progress Tracking

**Decision**: Track progress at the file level (completed files / total files) rather than per-file byte progress. Use robocopy's log output to detect file completion events.

**Rationale**: Robocopy does not output inline per-file percentage to stdout. It outputs file names as they start/complete. For 50-100 GB files, we can supplement with destination file size polling to show intra-file progress.

**Alternatives considered**:
- `/V /ETA` flags — provide ETA but not parseable percentage per file
- Custom file copy implementation — violates Minimal Complexity principle
- TeraCopy CLI — requires Pro license, less scriptable

**Exit code handling**: Robocopy uses bitmask exit codes. Codes 0-7 = success, 8+ = failure. Must check `exitCode >= 8` not `exitCode != 0`.

## HandBrakeCLI Progress Parsing

**Decision**: Parse stdout using regex pattern `Encoding: task (\d+) of (\d+), ([\d.]+) %`. HandBrakeCLI also supports `--json` flag for structured output.

**Rationale**: HandBrakeCLI outputs progress line: `Encoding: task 1 of 1, 13.25 % (49.87 fps, avg 62.48 fps, ETA 00h33m34s)`. This is easily parseable and provides percentage, FPS, and ETA.

**Alternatives considered**:
- `--json` flag — provides structured output but is less documented; regex on standard output is proven
- Log file monitoring — adds latency vs direct stdout streaming

## State Persistence (Job Queue)

**Decision**: Use `drift` (type-safe SQLite ORM for Dart) via `sqflite_common_ffi`.

**Rationale**: The job queue requires structured data (jobs with status, file lists, progress), frequent updates (status changes during processing), efficient queries (filter by status), and atomic transactions (mark file as complete + update job progress). Drift provides all of this with compile-time checked SQL and reactive `.watch()` queries for live UI updates.

**Alternatives considered**:
- Hive (NoSQL key-value) — fast but lacks relational queries, no transactions
- JSON file — simple but no partial updates, risk of corruption on crash
- shared_preferences — too simple for structured data
- Raw sqflite — works but drift's type safety reduces bugs

## Auto-Update Mechanism

**Decision**: Custom implementation using `dio` to check GitHub Releases API, with a prompted update dialog in the app.

**Rationale**: Constitution Principle VI (Update Transparency) requires explicit user confirmation. The `auto_updater` package uses Sparkle/WinSparkle which may auto-download without our control. Custom implementation gives full control over the UX: check on launch, show dialog with version notes, user clicks "Update Now" or "Later."

**Alternatives considered**:
- `auto_updater` package — mature but less control over UX, may conflict with transparency principle
- `desktop_updater` — newer, less proven
- No auto-update — requires manual download each time, bad UX

## Slack Notifications

**Decision**: Use `dio` package for HTTP POST to Slack incoming webhook URL.

**Rationale**: Slack incoming webhooks are simple HTTP POST with JSON body. No SDK needed. `dio` is already a dependency for the auto-updater. One package, two uses.

**Alternatives considered**:
- `http` package — simpler but `dio` is needed anyway for updater
- Slack SDK — overkill for webhook-only integration
