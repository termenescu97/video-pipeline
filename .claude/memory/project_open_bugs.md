---
name: Open bugs requiring fixes
description: Known bugs not yet fixed — check before starting new features
type: project
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
**State as of 2026-05-11 (post v2.5.0-pre tag)**: `v2.5.0-pre` is tagged + built + installed locally by the developer. No bugs from automated review or CI — all 27 Codex rounds resolved, 161/161 tests passing. **However**: the developer's own pre-check on the installed build surfaced UI issues that need fixing BEFORE handing to the operator. These are NOT yet captured in any spec (developer will bring them into the next session). The framing decision (v2.5.0 polish via re-tag `v2.5.0-pre-2` vs v2.5.1 patch) is open until the developer describes the findings. Recommendation: v2.5.0 polish, so the operator's first impression of v2.5.0 is the polished version. See `HANDOFF_v2.5.0-pre.md` at repo root for full context until that file is deleted.

v2.4.0 (released 2026-05-08) found a CRITICAL (robocopy execution-time overwrite guard) and a HIGH (graceful-shutdown race) in its final review pass; both were bundled as features 015 and 016 rather than deferred to a patch — operator's "bundle deferred fixes before asking for QA" preference.

The operator's 2026-05-08 Windows test on v2.4.0 exposed three executor blockers (PowerShell `$args[0]` cascade, 0/27 progress freeze, hash-failure-treated-as-job-failure) plus three UX failures → 017A + 017B. Then 018 (pre-tag hardening) ran a focused concurrency / atomicity / freshness pass. Then 019 (workflow-integrity hardening) ran a **holistic threat-model audit** — parallel Opus + Codex agents using the same 5-tier framework (source data loss / destination corruption / subprocess attack surface / state-counter correctness / operational resilience) caught 5 convergent workflow-level invariants that 25 incremental review rounds had missed.

Cumulative across 017A + 017B + 018 + 019: **27 Codex adversarial-review rounds**, ~7 P1 + ~45 P2 + 1 documented FP — all resolved or explicitly rejected with rationale. 161/161 tests passing.

Deferred items (no operator-visible behavior gap):
- `ConfirmationDialog.showCritical` consolidation for the SD-erase path. Bundles with v3.0 NAS upload's "wipe local cache" action.
- Ctrl+H keyboard shortcut to focus the HistorySurface search box. P3 nice-to-have; the search box is always visible. Defer to next polish bundle.
- Date-range filter / timeline visualization on the history surface. v3.0.

Deferred to v2.5.1 (single-auditor 019 findings; not load-bearing for the bytes-on-disk contract):
- F-D1 (Codex P3): size-mode TOCTOU between robocopy success and verifyTransfer size read.
- F-D3 (Opus P3): startup_sweep prefix collision with unrelated tools writing `.tmp_robocopy_*`.
- F-D4 (Codex P3): cross-machine NAS staging-tag collision (microsecond race).
- F-D5 (Opus P3): DST/clock-jump `Job.createdAt` mtime cutoff false-classification.
- F-D8 (Codex P3): re-verify `eraseDrive Remove-Item -LiteralPath` after the source-side symlink guard.

**Why:** Keeping this file lets future sessions check for known issues before starting new work. It is intentionally short when no bugs are open.

**How to apply:** If a new bug is identified, append it under a `### SEVERITY: Title` heading with file/line, problem, risk, suggested fix, and the spec-kit feature number that will track it.
