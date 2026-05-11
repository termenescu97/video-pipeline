---
name: Copiatorul3000 project state
description: Flutter desktop app for video production workflow automation — current development state, methodology, and what's left to do
type: project
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
**Copiatorul3000** is a Flutter desktop app (Windows 11) automating video file transfer and compression for a video production team. Lives at `~/Music/copiatorul3000/`, repo at github.com/termenescu97/video-pipeline.

**Why:** The video team was manually using TeraCopy + HandBrake GUI to transfer from SD cards, compress, and upload to NAS. This app automates steps 1-3 (NAS upload remains manual, out of scope).

**Scope: still MVP / continuous-testing phase.** Each test cycle uses a freshly-built install folder; the SQLite `.db` at `%APPDATA%\com.example\video_pipeline\video_pipeline.db` is essentially throwaway state — there is no months-of-operator-history scenario to protect yet. **Implications for code review and recommendations:** do NOT propose DB-backup features, integrity-check pragmas, schema-rollback procedures, or any "preserve operator history across upgrades" defenses — those are production-deployment concerns that don't apply yet. If the DB looks weird, the answer is "delete the .db, restart, regenerate." The data that DOES matter (always, even in MVP) is the bytes on disk: source SD card content (read-only-effectively until typed-confirmation erase) and destination video files (protected by /XN /XC /XO + executor-side delete gating + optional SHA-256 verify). Concerns about destination overwrite, source erase, hash mismatch handling, etc. remain in scope. Concerns about DB content preservation across upgrades do not.

**How to apply:** When working in `~/Music/copiatorul3000/`, read the CLAUDE.md for full project context. Use spec-kit methodology (`/speckit-specify` → `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement`) for all features. Never skip `/speckit-clarify`. Constitution at `.specify/memory/constitution.md` has 6 binding principles. After implementing a feature, run an adversarial review via `/codex:adversarial-review` or a Rick Sanchez agent prompt.

**Current state (2026-05-11):** 19 features in flight. v2.4.0 released and tagged; `v2.5.0-pre` tagged + built + locally installed by the developer. `main` is at `e004d2c` (4 attribution merges of 017A → 017B → 018 → 019). GH Actions Windows build succeeded; release at https://github.com/termenescu97/video-pipeline/releases/tag/v2.5.0-pre marked Pre-release (manual `gh release edit --prerelease` flip — the GH Action doesn't auto-detect `-pre` as a prerelease pattern). v2.4.0 stays Latest. Database schema v9. 161/161 tests passing. Developer is now doing pre-check QA on the installed build BEFORE handing to operator — UI fixes from this pre-check are expected to land as v2.5.0 polish (re-tag `v2.5.0-pre-2`), not v2.5.1. The v2.5.1 slot (`specs/020-v2.5.1-field-findings/`) stays reserved for AFTER-operator-acceptance findings. **Development moved from macOS (`~/Music/copiatorul3000/`) to the Windows workstation on 2026-05-11**; pre-check QA and v2.5.0 polish continue there. macOS checkout is archive-only.

**v2.5.0 was driven by the operator's 2026-05-08 Windows test failure.** Three executor blockers (PowerShell `$args[0]` cascade, 0/27 progress freeze, hash-failure-treated-as-job-failure) plus three UX failures (panels open all the time, filter pills wrap, no first-class history). 017A closes the executor; 017B closes the UX. **16 Codex adversarial-review rounds** total across both branches; cumulative findings 4 P1 + ~28 P2 + 1 documented FP — all resolved.

**No open bugs.** The v2.4.0 final-review CRITICAL (robocopy execution-time overwrite guard) and HIGH (graceful-shutdown race) were bundled as features 015 and 016. The only deferred item from v2.4.0 (`ConfirmationDialog.showCritical` consolidation for the SD erase path) still defers to v3.0's NAS upload "wipe local cache" action.

**Features implemented:**
- 001: Video pipeline automation (MVP) — 43 tasks
- 002: UI improvements — 5 tasks
- 003: Critical bug fixes — 23 tasks
- 004: Core UX improvements — 42 tasks
- 005: Polish & code quality — 29 tasks
- 007: Critical bug fixes v2 (from review) — 10 tasks
- 008: High-priority QA fixes (from review) — 14 tasks
- 009: Product gaps (progress wiring, logging, instance lock, onboarding) — 21 tasks
- 010: Medium fixes (operator name, CSV export, timestamps, path fixes) — 21 tasks
- 011: SHA-256 file verification (per-job toggle, hash audit trail) — 19 tasks
- 012: Test card prep utility (one-click QA setup) — 4 tasks
- 013: Data safety & reliability hardening — 46 tasks
- 014: UI/UX redesign (visual hierarchy, three-column shell, status bar, slim/hero/done card variants, inline detail tabs, side-nav settings, M3 theme, 12 keyboard shortcuts, mandatory typed-confirmation gate) — 114 tasks
- 015: Robocopy execution-time overwrite guard (bundled into v2.4.0; schema v6→v7, split delete-rule, mtime cutoff guard, per-file `wasOverwriteApproved`)
- 016: Graceful shutdown race hardening (bundled into v2.4.0; phased shutdown with phase-local timeouts, `_safeWrite` abandonment-aware DAO wrapper)
- 017A: Executor correctness for v2.5.0 (PowerShell argv length-3 invariant + escapePsLiteral, progress decoupled from verify, schema v7→v8 with VerifyStatus + FailureKind + parentJobId + unverifiedFiles + forceDestDeleteApproved, recovery for completed+pending verify rows, persisted forceDestDelete approval, NTFS case-collision normalization, robocopy staging-dir rename, structured LogService named-param API)
- 017B: UX restructuring for v2.5.0 (drop ActivityPanel, collapsible SourcesPanel with persistence, auto-hide CreateJobScreen pane, filter chips horizontal-scroll, HistorySurface with search + verify-axis status filters, Diagnostics → Recent failures, transferAndCompress auto-chain gate + Accept-resume flow, VerifyStatus.notVerified for size-mode baseline)
- 018: Pre-tag hardening before v2.5.0 (per-file retry atomicity, typed-gate phrase enforcement, chain-dedup transactional gate, _stopRequested no-await race fix, FK pragma in beforeOpen, stale error_message cleanup, markFileUnverifiedAndIncrement atomic primitive, JOIN-based self-healing of unverifiedFiles counter, size-mode `_processTransfer` mirrors SHA-256 sequence, orphaned staging-dir cold-start sweep with `host=`-only liveness check)
- 019: Workflow-integrity hardening (holistic threat-model audit pass — parallel Opus + Codex audits caught 5 convergent workflow-level invariants that 25 incremental review rounds had missed: drive-letter remap on reinsert closed by `Job.sourceDriveSerial` capture+resume re-check, erase-time card content reconciliation, source-side symlink guard, force-delete deferred clear, HandBrake staging-dir convention with recursive sweep; +3 bundled defenses: Slack getWebhookUrl in try block, SHA-256 long-path `\\?\` prefix, drive_service argv runtime guard + permanent CI grep step; schema v9 with sentinel migration)

**What's left (v3.0 roadmap):**
- Tier 1: NAS upload automation, auto-detect SD cards, dashboard stats
- Tier 2: Job templates, scheduled jobs, multi-machine sync, selective file copy (PM-10)
- Tier 3: Cloud backup, metadata extraction, team activity feed

**Key decisions made:**
- Flutter/Dart single codebase (not Python + Flutter) — avoids IPC bridge
- robocopy over TeraCopy — free, built-in, better CLI, `/Z` resumable
- Drift/SQLite for state persistence — reactive queries feed UI, schema v5
- GitHub Actions for CI/CD — builds Windows .exe on tag push
- Per-job configuration with favorites — not a global settings approach
- Master-detail desktop layout — not mobile push/pop navigation
- ValueNotifier for progress data (not streams or state management libs)
- OS-level instance lock via `RandomAccessFile.lock(FileLock.exclusive)` (rewritten in 013 — was a check-then-write PID file before)
- Log file next to executable (not AppData) — accessible to non-technical operators
- Operator name stamped on Job record at creation (not read from settings at display time)
- SHA-256 via PowerShell Get-FileHash with single-quoted `-LiteralPath '${escapePsLiteral(path)}'` and length-3 argv (017A fix — the previous `$args[0]` pattern was actually broken because `-Command` silently drops trailing argv; that's the root cause of the operator's 2026-05-08 hash failures)
- Parallel hashing of source + destination via Future.wait, each call gets its own ProcessRunner (013 fix — single shared runner raced over the second hash's process handle)
- Codex plugin (openai/codex-plugin-cc) installed for GPT adversarial reviews
