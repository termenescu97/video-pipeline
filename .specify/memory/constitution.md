<!-- Sync Impact Report
  Version change: 0.0.0 → 1.0.0 (initial ratification)
  Added principles:
    - I. Human-in-the-Loop
    - II. Single Codebase
    - III. Resilient Pipeline
    - IV. Minimal Complexity
    - V. Observable Progress
    - VI. Update Transparency
  Added sections:
    - Technical Constraints
    - Development Workflow
    - Governance
  Templates requiring updates: ✅ plan-template.md (no changes needed, Constitution Check gate compatible)
  Templates requiring updates: ✅ spec-template.md (no changes needed)
  Templates requiring updates: ✅ tasks-template.md (no changes needed)
  Follow-up TODOs: None
-->

# Video Workflow Automation Constitution

## Core Principles

### I. Human-in-the-Loop

Any action that is destructive, irreversible, or affects source data MUST require explicit user confirmation via the GUI. The system MUST NOT silently delete, overwrite, or erase files. This applies to:

- Erasing SD cards after transfer
- Deleting uncompressed originals after compression
- Overwriting existing files on the destination
- Any bulk operation that cannot be undone

Rationale: The team works with large video files (50–100 GB each). An accidental automated deletion could mean losing an entire shoot with no recovery path.

### II. Single Codebase

All application logic — GUI, automation, file operations, notifications — MUST live in one Flutter/Dart codebase. There MUST be no separate runtimes, no IPC bridges, and no secondary programming languages. The app MUST ship as a single compiled Windows executable.

Rationale: Avoids the complexity of bridging two runtimes and simplifies deployment. One language, one build, one artifact.

### III. Resilient Pipeline

File transfer and compression operations MUST be resumable after interruption (power failure, crash, user cancellation). The app MUST track progress state so that re-running a pipeline picks up where it left off rather than restarting from scratch. No file MUST be considered "transferred" until verified (size validation or checksum).

Rationale: Files are 50–100 GB each. A power outage at 95% of a transfer MUST NOT mean starting over. Resilience is the primary reason the team adopted specialized transfer tools in the first place.

### IV. Minimal Complexity

The app MUST delegate heavy operations to proven CLI tools (robocopy for file transfer, HandBrakeCLI for compression) rather than reimplementing their functionality. The app's role is orchestration — detecting drives, managing queues, reporting progress, and spawning subprocesses. It MUST NOT implement its own file copy engine or video encoder.

Rationale: Robocopy and HandBrakeCLI are battle-tested tools that handle edge cases reliably. The app is the glue, not the engine. This keeps the codebase small and maintainable.

### V. Observable Progress

Every pipeline phase (transfer, compression) MUST report real-time progress to the GUI. Phase transitions and completions (success or failure) MUST be reported to Slack. Failure notifications MUST include actionable detail — which file failed, what error occurred, and at what stage.

Rationale: The goal is to free up the team's time. They MUST be able to walk away and trust that Slack will inform them of what happened. Silent failures are unacceptable.

### VI. Update Transparency

The app MUST NOT silently update itself. When a new version is available, the app MUST notify the user and require explicit confirmation before downloading or applying the update. Updates MUST NOT interrupt an active pipeline.

Rationale: A silent update during a multi-hour compression run could corrupt the process. The user decides when to update.

## Technical Constraints

- **Target platform**: Windows 11
- **File transfer tool**: robocopy (built into Windows, `/Z` flag for resumable transfers)
- **Compression tool**: HandBrakeCLI 1.11.1
- **Staging storage**: External 14TB HDD connected via USB 3
- **Input formats**: .MOV, .MP4 (50–100 GB per file)
- **HandBrake presets**: Read from `%APPDATA%\HandBrake\presets.json`, selectable via GUI dropdown
- **Distribution**: GitHub Actions CI → GitHub Releases → in-app auto-updater (prompted, not silent)
- **Notifications**: Slack via incoming webhook

## Development Workflow

- Development happens on macOS; the target platform is Windows 11
- Windows builds are compiled via GitHub Actions (no dev tools installed on the target machine)
- Spec-driven development via spec-kit: constitution → specify → plan → tasks → implement
- All changes go through git; spec-kit hooks manage commits at each phase
- First install on target machine is a manual `.exe` copy; all subsequent updates via in-app updater

## Governance

- This constitution supersedes all other project documents and practices
- Amendments MUST be documented in this file with a version bump
- Principle changes MUST be agreed upon before implementation proceeds
- Version follows semantic versioning:
  - MAJOR: principle removed or redefined in a backward-incompatible way
  - MINOR: new principle or section added, or existing one materially expanded
  - PATCH: clarifications, wording fixes, non-semantic refinements

**Version**: 1.0.0 | **Ratified**: 2026-05-05 | **Last Amended**: 2026-05-05
