# Operator Acceptance Checklist — v2.5.0

> **Why this file exists**: the full release notes are long. This is the focused checklist you actually run on the workstation. Print it, keep it open in a second window, or check items off in GitHub's preview — whatever works.
>
> **The honest summary of what changed in v2.5.0**: this is a data-safety hardening release driven by the 2026-05-08 failed 161 GB transfer. The critical path is **Tier 2** — re-running that exact scenario and confirming it now works. Everything else is supporting evidence.

---

## Time estimate

- **Pre-flight**: 10 min
- **Tier 1 (smoke test)**: 15 min
- **Tier 2 (the actual 161 GB re-run)**: ~4 hours unattended, ~15 min of attention
- **Tier 3 (UI verification)**: 30 min
- **Tier 4 (negative testing — OPTIONAL)**: 1-2 hours
- **Total minimum to ship**: ~5 hours, mostly unattended

If you only have time for Pre-flight + Tier 1 + Tier 2 + Tier 3, that's still a valid acceptance pass. Tier 4 is "try to break it on purpose" — useful but not ship-blocking.

---

## Pre-flight (do this first, before installing v2.5.0-pre)

- [ ] **P1. Backup your `.db` file.** Close Copiatorul3000 if running. Copy `%APPDATA%\com.example\video_pipeline\video_pipeline.db` to a safe location (Desktop or USB). The schema migration v8 → v9 is transactional and tested, but a backup means a 30-second rollback if anything weird happens.
- [ ] **P2. Note your current version.** Settings → About → version number. Should be 2.4.0. If different, tell me before continuing.
- [ ] **P3. Download v2.5.0-pre Windows .exe** from GitHub Releases page. Look for the `v2.5.0-pre` tag; extract the zip; run the .exe. The auto-update prompt will NOT fire on `-pre` tags by design.
- [ ] **P4. First launch.** App should open normally. Schema auto-migrates from v8 → v9. Check Settings → Diagnostics → log path; the log should show `Migration: v8 → v9 — backfilled N existing jobs with __legacy_v8__ sentinel` (where N is your old job count). If you see schema errors, STOP and report — restore the backup .db.

---

## Tier 1: Smoke test (15 min, mandatory)

The point: prove nothing catastrophic before committing 4 hours to the big run.

- [ ] **T1.1. Insert a small SD card** (~5-10 GB worth of footage, doesn't matter what). Sources panel on the left should show it within 5 seconds.
- [ ] **T1.2. Create a small transfer job.** Source = the small card. Destination = a NEW empty folder on E:\ (e.g., `E:\v2.5.0-smoke\`). Verification: SHA-256.
- [ ] **T1.3. Click Start. Watch for the first 30 seconds.** You should see:
  - Progress bar starts moving (NOT stuck at `0B / XGB`)
  - File counter starts incrementing (`1 / N files`, `2 / N files`, ...)
  - The active job card shows the current filename
  - INFO lines appearing in the log (Settings → Diagnostics → "Open log")
- [ ] **T1.4. Let it complete.** Job status flips to Completed. All files verified. No PowerShell errors in the log.
- [ ] **T1.5. Spot-check ONE destination file.** Open it in your video player. Confirm playback. This is the bytes-on-disk truth — everything else is tooling around it.
- [ ] **T1.6. (Optional) Erase the small card** to test the new card-content reconciliation. Click Erase on the source. Type the confirmation phrase. Card should erase cleanly.

**If any T1 step fails, STOP. Report which step + what happened. Do NOT continue to Tier 2 — we want to fix the smoke-test failure before burning 4 hours.**

---

## Tier 2: The actual 161 GB re-run (mandatory — this is THE ship gate)

This replays the exact scenario that failed on v2.4.0 on 2026-05-08. If this passes cleanly, v2.5.0 has done its job.

- [ ] **T2.1. Insert the same Canon SD card setup as last time.** 27 files, 161 GB, intended destination `E:\Studio Termene\Brut - To compress\test\Canon_Reels_H`.
- [ ] **T2.2. Create a transferAndCompress job.** Source = `H:\` (or wherever the card mounts). Destination = the path above. Verification: SHA-256. Compression preset = whatever you used last time.
- [ ] **T2.3. Click Start. Stay at the workstation for 5 minutes.** Confirm:
  - Progress bar advances during transfer phase (bytes credited live)
  - File counter increments live (`1 / 27`, `2 / 27`, ...)
  - Phase indicator transitions Transfer → Verify → Compress
  - INFO lines for each successful copy appear in the log with `[job=N file=K/27 phase=transfer]` prefix
- [ ] **T2.4. Walk away.** Come back when the Slack notification arrives (or check periodically).
- [ ] **T2.5. When the job completes, verify in this order**:
  1. Slack message says "Transfer completed" with verify counts (e.g., "27 verified · Passed")
  2. Job card status = Completed (green)
  3. Compression chained automatically (no manual re-trigger)
  4. Compression finishes, second Slack message arrives
  5. Open 3 random destination files — confirm playback works
  6. Open the log — search for "ERROR" or "WARNING". Acceptable: zero ERROR lines, zero WARNING lines (other than recovery-related warnings if you'd had a prior crash). UNACCEPTABLE: any "PowerShell parser error" line, any `0 / 27` reading, any "hash mismatch" without a clear cause.

**If T2.5 passes cleanly, v2.5.0 has cleared its primary acceptance gate.** The remaining tiers are supporting evidence, not blocking.

---

## Tier 3: UI verification (mandatory, but quick — 30 min)

These are the user-visible 017B / 018 / 019 changes. Click through each and confirm.

- [ ] **T3.1. Sources panel collapse.** `Ctrl+1` toggles between 240 px (expanded) and 48 px (collapsed icon strip). Persists across app restart.
- [ ] **T3.2. CreateJob auto-hide.** Idle state has no empty pane on the right. `Ctrl+N` opens the form, the queue narrows. Save closes the form, the queue expands back to full width.
- [ ] **T3.3. Filter pills.** Job queue's filter chips (All / Pending / In progress / Completed / Failed) sit in a single horizontal-scroll row. Try resizing the window narrower — they should scroll, not wrap to multiple rows.
- [ ] **T3.4. History search.** The Done section at the bottom of the queue has a search box. Type part of a source path — the list filters. Status filter dropdown includes Mismatch and Unverified (not just Failed).
- [ ] **T3.5. Diagnostics → Recent failures.** Settings → Diagnostics shows a "Recent failures" list at the bottom. Should be empty if T1+T2 went clean. If the smoke job had any verify warnings, they'd appear here.
- [ ] **T3.6. Active card phase indicator.** Start a transferAndCompress job. The active card should show `[Transfer] → [Verify] → [Compress]` with the current phase highlighted in primary color. File counter line: `12 / 27 files · 38 GB / 161 GB` with tabular-figure spacing (digits don't reflow as numbers change).
- [ ] **T3.7. Keyboard shortcuts cheat sheet.** Press `?`. The cheat sheet modal appears. Lists all 12 shortcuts (`Ctrl+N`, `Ctrl+Enter`, `Ctrl+1`, etc.).

---

## Tier 4: Negative testing (OPTIONAL — try to break it on purpose)

These exercises require deliberately constructing failure scenarios. Each catches a specific class of bug. Skip any that requires setup you don't want to deal with — they're not ship-blocking.

- [ ] **T4.1. Card-swap detection (the 019 F-1 case).** Create a transferAndCompress job for SD card A mounted at `H:\`. Stop the queue mid-transfer. Eject card A, insert a DIFFERENT card B at the same drive letter. Click Resume on the job.
  - **Expected**: app refuses with banner "Card identity mismatch at H:\ — original: <serial-A>, current: <serial-B>. Re-insert the original card to resume." Card B is NOT touched.
  - Re-insert card A → resume succeeds.
- [ ] **T4.2. Erase-rescan (the 019 F-2 case).** Create + complete a transfer for 5 files on SD card A. Before clicking Erase, copy ONE additional file to the card via Explorer (simulating a camera flush after the job ran).
  - **Expected**: clicking Erase shows refusal "1 file(s) added to the card since the job was created — including <filename>". Erase is BLOCKED until you delete the new file or re-create the job.
- [ ] **T4.3. Hash subsystem broken.** Temporarily rename `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` (you'll need admin rights). Run a SHA-256 transfer.
  - **Expected**: files end with `verifyStatus=unverified` warning chip; copy progress STILL advances (bytes-on-disk credited regardless of verify outcome); job is NOT marked failed. Restore powershell.exe afterward.
- [ ] **T4.4. Bytes mismatch.** Start a SHA-256 transfer of a single small file. While it's copying, modify the source file's contents (open in a text editor, change a byte, save).
  - **Expected**: that file ends with `verifyStatus=mismatch` (soft fail); other files complete normally; banner offers Investigate / Retry / Skip.
- [ ] **T4.5. Force-kill mid-verify.** Start a SHA-256 transfer. Mid-verify-phase (when the log shows `[phase=verify]`), force-end the process via Task Manager (End Task, not just Close).
  - **Expected**: on relaunch, recovery message in log: `Recovered job #N`. The mid-verify file re-enters verify-only (NOT re-copy). Counters re-derived correctly. No double-credited bytes.
- [ ] **T4.6. Long-path SHA-256.** Create a deeply nested folder hierarchy at the destination so the full file path exceeds 260 characters. Run a SHA-256 transfer there.
  - **Expected**: hash succeeds. Without the v2.5.0 long-path fix, this would fail with "FileNotFoundException".
- [ ] **T4.7. Identity-refused vs empty-card distinction.** Insert two SD cards. While "Copy All Cards" is reading them, eject one quickly so its WMI identity probe fails.
  - **Expected**: SnackBar says "Created 1 jobs, refused 1 card (could not read serial — re-insert and retry)" — distinct from "skipped 1 empty card".

---

## Reporting findings

Anything that doesn't behave as expected goes here, **NOT in chat scrollback** (which gets lost). The next session will start by reading these reports.

**Where to write findings**: `specs/020-v2.5.1-field-findings/spec.md` → "Operator-reported findings" section. Use the template in that file. One subsection per finding.

**What to capture per finding**:
1. Which tier + step number caught it
2. What you expected to happen
3. What actually happened
4. Severity guess: P1 (data loss / blocks workflow) / P2 (workflow degraded but workable) / P3 (cosmetic)
5. Whether it's reliably reproducible
6. If you have a copy of the relevant log section, paste it

**If something LOOKS like data loss** (file missing, wrong bytes, source erased without consent): STOP. Don't run further tiers. Report immediately and we'll triage before continuing.

---

## Recovery procedures (if something breaks)

This is the MVP / continuous-testing phase — DB content is recoverable by deleting + reinstalling. The bytes-on-disk are what matters.

- **App crashes on launch**: delete `%APPDATA%\com.example\video_pipeline\video_pipeline.db`, relaunch — fresh v9 schema. If still crashes, restore the backup `.db` from Pre-flight P1, downgrade to v2.4.0 from GitHub Releases, report the crash.
- **App launches but UI looks broken**: same path — delete the `.db` and relaunch.
- **A transfer reports completed but a destination file is missing/corrupt**: source SD card is intact (the app does not auto-erase). Re-run a per-file Retry from the JobCardDone menu, or re-create the job. The audit tab shows source/destination hashes for every file in SHA-256 mode — diff those.
- **Orphaned `.tmp_robocopy_*` or `.tmp_handbrake_copiatorul3000_*` directories in destination**: cold-start sweep removes them on next launch. If they persist across restarts, check the `.live` marker's `host=` field — if it says another machine, that's working as designed (cross-machine NAS guard).
- **Migration v8 → v9 left the DB in a weird state**: restore the backup, report the symptom, we'll triage offline.

---

## After acceptance

- **All Tier 1 + 2 + 3 passed, no P1/P2 findings**: tell me. I'll re-tag `v2.5.0` (drop the `-pre` suffix), GitHub Actions builds the final release, the auto-update prompt fires for any v2.4.0 install on next launch.
- **One or more findings**: log them in `specs/020-v2.5.1-field-findings/spec.md`. We'll batch-fix in v2.5.1. Don't tag `v2.5.0` until we've decided whether each finding is ship-blocking or v2.5.1-deferrable.
- **Tier 4 produced findings but Tiers 1-3 are clean**: case-by-case. Tier 4 findings are usually deferrable to v2.5.1 unless they reveal a workflow you actually depend on.
