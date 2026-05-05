# Video Production Workflow Automation

## Goal

Automate the video production team's post-shoot ingestion pipeline — from SD card insertion through file transfer and compression — eliminating manual queuing and reducing hands-on time. NAS upload remains a manual step (out of scope).

## Current Manual Workflow

1. **SD Card Ingestion** — Insert filled SD cards into a multi-slot SD card hub connected to the main machine
2. **File Transfer** — Open TeraCopy, manually queue all SD card volumes for transfer to the main machine's local storage
3. **Compression** — After transfer completes, manually queue the transferred files in HandBrake for compression
4. **NAS Upload** *(out of scope)* — After compression completes, manually upload the compressed files to the Synology NAS via its dashboard

Steps 1–3 are sequential and require someone to monitor completion before starting the next. The automation will cover steps 1–3.

## Technical Approach

### Stack: Flutter + Dart (single codebase)

- **GUI** — Flutter desktop app (Windows)
- **Automation logic** — Dart (`dart:io`) running in the same app
- **File transfer** — Robocopy (built into Windows, free, better CLI output than TeraCopy) spawned as a subprocess
- **Compression** — HandBrakeCLI spawned as a subprocess
- **Slack notifications** — HTTP POST to Slack webhook via `dart:io HttpClient`
- **Deployment** — Single compiled Windows executable

### Why Dart over Python

- No IPC bridge needed — script logic and GUI share the same runtime
- One language, one codebase, one build artifact
- Dart's `Process.start()` can stream subprocess stdout in real-time for progress tracking
- Ships as a single `.exe`, no Python installation required on the machine

### Build & Distribution

- **Source control** — Private GitHub repository (free tier)
- **CI/CD** — GitHub Actions builds the Windows `.exe` on every push/tag (free: 2,000 min/month)
- **Releases** — GitHub Releases hosts versioned `.exe` builds (free, no storage limits on assets)
- **Updates** — In-app auto-updater checks GitHub Releases on launch; prompts the team to update (human-confirmed, not silent)
- **First install** — Manual `.exe` copy to the video production machine
- **Development** — Code is written on macOS, pushed to GitHub; the Windows build happens entirely in GitHub Actions (no dev tools needed on the target machine)

### Versions

- **TeraCopy** — 3.17 (Pro version needed for full CLI support — to be confirmed)
- **HandBrake** — 1.11.1

### Key Technical Notes

- Robocopy supports automation via `robocopy <src> <dst> /Z /V /ETA` — restartable mode, verbose, with ETA
- Robocopy outputs detailed per-file progress to stdout — can be streamed directly into Flutter widgets
- App manages its own transfer queue/state for resilience (resume after power failure, skip already-transferred files)
- **Future consideration:** cross-platform support possible by abstracting copy engine (robocopy on Windows, rsync on macOS/Linux)
- HandBrakeCLI outputs progress (percentage, ETA) to stdout — can be streamed directly into Flutter widgets
- HandBrake custom presets are stored as JSON files at `%APPDATA%\HandBrake\presets.json` on Windows — the app can read this file, list available presets, and pass the preset name to HandBrakeCLI via `--preset-import-file` and `--preset`
- Input files: `.mov` and `.mp4`, 50–100 GB each — compression will be CPU-intensive and long-running per file

## Core Principles

### Human-in-the-Loop for Decisive Actions

**Any action that is destructive, irreversible, or affects source data must require explicit human confirmation.** The automation should handle the heavy lifting (transfer, compression, queuing), but critical decisions — such as erasing SD cards, deleting original files, or overwriting existing data — must always be gated behind a manual confirmation step in the GUI. This principle must be respected in all current and future planning.

Examples:
- SD card erasure → manual button in the GUI, never automatic
- Deleting uncompressed originals after compression → requires explicit user confirmation
- Overwriting files on the destination → requires explicit user confirmation

## Requirements

### GUI

- A desktop GUI application for the video team to manage and monitor the pipeline
- Should display pipeline status (which phase is running, progress, errors)
- Team should be able to trigger/start the process from the GUI

> **Open:** What level of control does the team need? Just a "Start" button and status view, or more granular control (pause, skip files, choose presets, etc.)?

### Slack Notifications

- Send Slack messages at each phase transition (transfer started/completed, compression started/completed)
- Include success/failure status
- On failure, include enough detail to know what went wrong

> **Open:** Which Slack channel/workspace? Do we need a dedicated Slack bot/app, or is a webhook to an existing channel enough?

## Open Questions

### Hardware & Environment

- [x] What OS is the main machine running? — **Windows 11**
- [x] What SD card hub model/brand is being used? — **Kingston 9934534-003.AOOLF 5V**
- [x] How much local storage is available on the main machine for staging files between steps? — **Not used. An external 14TB HDD connected via USB 3 is used as the staging/intermediary drive.**
- [x] What is the NAS model/brand? How is it connected? — **Synology NAS, uploads done via Synology dashboard. SSH access available if needed.**
- [x] Is the NAS share always mounted, or does it require manual connection/credentials? — **N/A — NAS upload is out of scope for this automation.**

### Files & Volume

- [x] What video format/codec are the cameras recording in? — **.MOV and .MP4**
- [x] What is the typical file size per clip? Per SD card? — **50–100 GB per file**
- [ ] How many SD cards per session/shoot?
- [ ] How often does this workflow run? (daily, weekly, per shoot)

### Compression

- [x] What HandBrake preset or settings are currently being used? — **Custom preset created by the team. App reads `%APPDATA%\HandBrake\presets.json` and shows a dropdown in the GUI — no need to hardcode a preset name.**
- [ ] Is the output format/codec the same for all videos, or does it vary?
- [ ] Are there files that should skip compression? (e.g., audio-only, photos, project files)

### Post-Transfer

- [x] What should happen to the files on the SD cards after a verified transfer? — **Not automatic. A manual "Erase SD Card" button in the GUI, so the team can validate before wiping. (Human-in-the-loop principle)**
- [ ] Should the original uncompressed files be kept on local storage, or deleted after compression? *(if deleted, must also be human-confirmed per core principle)*
- [ ] What is the folder structure expected on the NAS? (by date, project name, camera, etc.)

### Process & Oversight

- [ ] Does anyone need to review or rename files before compression begins?
- [x] Should there be notifications on completion or failure? — **Yes, Slack notifications for each phase (transfer, compression) with success/failure status.**
- [ ] Is there a naming convention for files or folders?
- [ ] Who is responsible for inserting/removing the SD cards, and do they need to confirm anything before the pipeline starts?
