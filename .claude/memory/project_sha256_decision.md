---
name: SHA-256 verification approach decision
description: Implemented in feature 011 — robocopy + post-transfer SHA-256 hashing with per-job toggle
type: project
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
**Decision (2026-05-06):** SHA-256 file verification uses robocopy for transfer + separate SHA-256 hash after transfer, with a per-job toggle ("Quick verify (size)" vs "Full verify (SHA-256)"). **Implemented in feature 011, released in v2.2.0.**

**Why:** Inline hashing during transfer would require replacing robocopy with a custom Dart copy engine, violating Constitution IV (Minimal Complexity) and losing `/Z` resumable transfers.

**How to apply:** Already implemented. Key implementation details:
- Toggle: SegmentedButton in job creation form + batch copy dialog
- Hash tool: PowerShell `Get-FileHash -LiteralPath '${escapePsLiteral(path)}'` inline-script pattern (017A T032 — replaced the broken `$args[0]` cascade; `-Command` silently drops trailing argv, which was v2.4.0's root-cause hash failure on the operator's 161 GB test). CI grep guard `! grep -rn '\$args\[' lib/` prevents reintroduction.
- Long paths: `\\?\` prefix added by `transfer_service::longPathPrefixed` for paths > 240 chars (019, T031) — PowerShell 5.1 `-LiteralPath` requires it above the Windows MAX_PATH boundary.
- Parallel: source and dest hashed simultaneously via `Future.wait` (different physical drives)
- Null handling: if either hash returns null, it's `verifyStatus=unverified` (subsystem failure, soft warning) NOT `verifyStatus=mismatch` (hard fail, FR-004)
- Storage: `verificationMode` on Jobs table, `sourceHash`/`destinationHash` on JobFiles table (schema v5; 017A added 5-state `VerifyStatus` enum + `FailureKind` enum at v8; 019 added `Job.sourceDriveSerial` at v9)
- UI: shield icon on SHA-256 verified files, expandable to show full hashes
- Slack: notifications include verification method ("SHA-256 — Passed" vs "Size — Passed")

**Alternatives rejected:**
- TeraCopy ($30 license, no byte-level resume)
- rclone (slower for local transfers)
- Dart single-pass (replaces robocopy, loses `/Z`)
- Parallel hash during robocopy (USB controller thrashing)

**v2.4.0 interaction (feature 015):** Robocopy now runs with `/XN /XC /XO` always-on, plus an executor-side delete-then-copy when overwrite was approved at preflight or when resuming an own `/Z` partial. This closes a TOCTOU gap that mattered most in size-only mode: if a partial copy crashed and a different file later happened to land at the dest with the same size, the size-only check would have wrongly marked it complete. With 015, that scenario can't happen — robocopy refuses overwrite and the executor's delete-rule honors actual operator intent. SHA-256 mode was already safe against this (hash mismatch catches it); 015 brings size-only mode up to the same safety floor without paying the hash cost.

**v2.5.0 interaction (017A + 018):** the bytes-credited-before-verify split (`markFileCompleted(verified: false)` lands BEFORE the hash check) means a hash-subsystem flake no longer freezes the operator's progress bar at `0B / 161GB`. The `VerifyStatus` axis is independent of `FileStatus` — bytes-on-disk and verified-with-cryptographic-trust are separate concerns. Operator can Accept a `verifyStatus=mismatch` row (typed-confirmation gate, 018 T005-T007) without the legacy `verified` boolean lying about cryptographic trust. The 5-state `VerifyStatus` enum: `pending` / `verified` (SHA-256 match) / `mismatch` (SHA-256 differ — soft fail) / `unverified` (subsystem failure) / `notVerified` (size-mode baseline, distinct from SHA-256 subsystem failure).
