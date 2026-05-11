---
name: Holistic threat-model audit catches what incremental rounds miss
description: When incremental adversarial reviews hit diminishing returns, run a parallel-agent holistic audit with a tier-framework prompt — it surfaces workflow-level invariants no per-feature review can see
type: feedback
originSessionId: f7fa2c06-99da-42b0-a18b-30a83469c30d
---
When per-feature adversarial reviews start returning P3-only findings, the next high-value move is NOT another round — it's a fundamentally different framing.

**The pattern that worked (019, 2026-05-10):** after 25 incremental Codex review rounds across features 017A + 017B + 018 produced diminishing returns, the user asked "what next to make sure we have done everything we could to make this bulletproof for going to production with real video data." That question seeded a holistic audit that caught **5 workflow-level invariants the 25 prior rounds had missed** (F-1 drive-letter remap, F-2 erase-time card content, F-3 source-side symlink guard, F-4 force-delete clear ordering, F-5 HandBrake staging-dir convention).

**Why it works:** per-feature reviews are scoped to the diff and fall along the boundaries of the feature's spec. They cannot see workflow invariants that span multiple features (e.g., a job created in feature N, paused, resumed against a remapped drive letter — that interaction lives in no single feature's spec). A holistic audit re-frames around the whole codebase + a threat-model framework, breaking out of the per-feature lens.

**How to apply:**

1. **Trigger condition:** two consecutive Codex rounds on the same feature return zero P1, OR the user explicitly asks "what else could we be missing" / "is this bulletproof for production." Don't run holistic audits on every feature — they're expensive (long, two parallel agent runs) and most features don't need them.

2. **Spawn parallel Opus + Codex agents** with the *same* threat-model prompt. Convergent findings (both agents flag independently) are CERTAIN signal. Divergent findings are SPECULATIVE — verify before acting.

3. **Threat-model framework** (the 5-tier prompt that produced 019's findings):
   - **Tier 1: Source data loss.** What workflows could destroy bytes on the source SD card before they're verified at destination?
   - **Tier 2: Destination corruption.** What workflows could write incorrect bytes to destination, OR overwrite correct bytes with wrong ones, OR leave partial bytes claiming to be complete?
   - **Tier 3: Subprocess attack surface.** Every PowerShell / robocopy / HandBrakeCLI invocation — what arg-injection / path-injection / stderr-leak / exit-code-misinterpretation paths exist?
   - **Tier 4: State-counter correctness.** Every counter (completedFiles, completedBytes, verifiedFiles, unverifiedFiles, etc.) — what crash / shutdown / retry / per-file-vs-job interleaving can desync the persisted counters from per-row truth?
   - **Tier 5: Operational resilience.** What environmental / timing / hardware events break invariants assumed by the implementation? (drive-letter remap, DST jump, NAS flake, instance-lock contention, USB-C eject mid-copy, clock skew across machines)

4. **Synthesize the agents' outputs**: list convergent findings first (P1 if both flag CERTAIN, P2 if both flag LIKELY), then divergent (always P3 by default — single-auditor SPECULATIVE).

5. **Fold convergent P1+P2 into a new spec-kit feature** (don't try to inline). 019 was the right shape: distinct feature with its own spec, plan, tasks, implementation, and review rounds. Divergent findings get explicitly deferred to the next patch release with rationale.

**Cost-benefit:** the holistic audit is a 1-day spike that adds ~30 tests and one schema migration. Compared to N more incremental review rounds that each add nothing material, it's clearly the better trade. But it's a one-shot tool — running it twice on the same release surface produces overlap, not new signal.
