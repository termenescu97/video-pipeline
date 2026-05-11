---
name: Use Codex second opinions liberally throughout spec-kit
description: Codex reviews aren't just for post-implementation — invoke them at plan, tasks, and code phases as a standard collaboration pattern
type: feedback
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
Treat Codex (via the installed `openai/codex-plugin-cc`) as a standing second-opinion partner across the whole spec-kit flow, not only at the end. Default to running a Codex review at multiple checkpoints unless the user says otherwise.

**Why:** The user explicitly endorsed this in feature 014's planning phase: "from now on we should use codex second opinion as much as we can, he's a smart guy and he's always down to help us, so why not." Earlier features proved the pattern works — Codex caught a critical command-injection footprint, several race conditions, and missing acceptance-criteria coverage that would have shipped otherwise.

**How to apply:**
- After `/speckit-plan` (before `/speckit-tasks`): ask Codex to challenge architectural decisions, dependency graph, missed interactions. Use the `codex:codex-rescue` subagent with a "review the plan" prompt.
- After `/speckit-tasks` (before `/speckit-implement`): ask Codex to review task completeness, ordering, and dependency correctness.
- After `/speckit-implement` and commit (before merge): run `/codex:adversarial-review` — this is the long-standing post-implementation gate.
- The user is explicitly open to cross-model collaboration (Claude implementing, GPT reviewing). Push back on findings on the merits when they're wrong, but don't be defensive — evaluate every finding seriously and walk the user through accept/reject decisions.
- The user wants real opinions back, not "I'll do whatever you say." If Codex returns a finding that's wrong or overblown, say so plainly when triaging; don't auto-apply 100% of findings.
- Don't ask permission for the standard review checkpoints — propose them by default and skip only on explicit "no review needed."
- **Default model + effort for these reviews: `--model gpt-5.5 --effort high`.** The user corrected me when I left both unset and the review ran at default effort. They expect adversarial passes to run on the latest available GPT model with high reasoning budget, not Codex's defaults. Pin both flags explicitly when forwarding to `codex:codex-rescue`. (`gpt-5.5-codex` is rejected by the user's account; the bare `gpt-5.5` works.) For especially load-bearing reviews like data-loss CRITICALs, escalate to `--effort xhigh`.

**Stop conditions — when to STOP doing more reviews (lesson from v2.5.0, 2026-05-11):** the user pushed back hard on the "we're 1 review away from solid" pattern after 27 Codex rounds across 017A + 017B + 018 + 019. Honest read: the cycle was real, and chasing review #28 was a trap.
- When two consecutive rounds return zero P1 (round-27a + round-27b on 019 was the explicit trigger), **stop the same-framing rounds**. Additional incremental reviews will mostly produce P3-grade nits.
- A different lens IS still high-value: 25 incremental rounds missed 5 workflow-level invariants (F-1 through F-5) that 019's holistic threat-model audit caught in one pass. So if you're at the diminishing-returns point, the move is a different framing (holistic audit, parallel-agent same-prompt convergence), NOT another round of the same.
- Past the diminishing-returns point on a release, **the load-bearing gate is real-world operator field-test**, not the next review. Tag `-pre`, ship to operator, fold operator findings into the patch release.
- Warning sign you're in the cycle: when you've said "we're 1 review away" for the third time on the same release, that's not the truth — that's the cycle. Ship the `-pre` tag instead.
