# 020 — v2.5.1 Field Findings

> **Status: SKELETON.** This spec is a pre-created slot, not a finished spec. It exists so anything the operator reports during v2.5.0 Windows acceptance has an obvious home — the next session doesn't have to rebuild context from chat scrollback. The "Operator-reported findings" section below is empty by design; populate it as findings come in. Once at least one operator finding is reported, run `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement` against this spec. Until then, leave it alone.

## Why this slot exists

v2.5.0 (017A + 017B + 018 + 019 bundle) ships with two known categories of follow-up work:

1. **Operator findings during the 21-step Windows acceptance** (the 13 baseline steps from 017 + 8 019-specific steps documented in `RELEASE_NOTES_v2.5.0.md`). Real-world bytes-on-disk testing on the actual workstation is the load-bearing ship gate; the diminishing-returns logic encoded in `feedback_adversarial_review.md` "Stop conditions" says we ship to operator instead of doing review #N+1, so we EXPECT some findings here.
2. **The 5 deferred 019 P3s** (single-auditor only; not load-bearing for the bytes-on-disk contract; explicitly deferred at v2.5.0 tag time per CLAUDE.md "Deferred to v2.5.1").

This spec captures both into a single v2.5.1 patch release. Bundling preference (operator standing rule): pull deferred fixes into the next release rather than ship + request repeat QA. See `feedback_bundle_before_qa.md`.

## Scope

### In scope
- Operator-reported regressions, UI bugs, workflow surprises, or data-handling concerns from v2.5.0 acceptance
- The 5 documented deferred P3s (F-D1 through F-D8 — see "Pre-known deferred items" below)
- Any P3-grade Codex findings that surfaced in round-27a/27b but were deemed not-worth-fixing-pre-tag (cross-reference `specs/v2.5.0-audit-findings.md`)

### Out of scope
- New features (NAS upload moves to v2.6.0, see CLAUDE.md "Roadmap")
- Schema changes UNLESS an operator finding genuinely requires one (default: no)
- Re-running the holistic threat-model audit framework — that's a one-shot tool per release surface (see `feedback_holistic_audit.md`)

## Pre-known deferred items (single-auditor 019 P3s)

Each item below is a placeholder with the source-finding rationale carried forward from CLAUDE.md → "Open Bugs → Deferred to v2.5.1". Sharpen each into a real US/FR with `/speckit-clarify` once we're actively working on this spec.

### F-D1 — Size-mode TOCTOU (Codex-only, P3)
Size-mode `_processTransfer` has a TOCTOU window between robocopy success and `verifyTransfer`'s size read; an external process could modify the destination in the gap. Probability is vanishingly low (operator's own machine, dest path freshly created), and the SHA-256 path is already TOCTOU-immune. Bundle when the next feature touches `_processTransfer`.

**Suggested fix sketch**: stat the destination file size BEFORE verifyTransfer's separate stat call → throw if size changed under us. Or: hold a file handle on the destination across the robocopy → verify boundary so external truncation surfaces. Real fix likely depends on what `_processTransfer` looks like after operator-driven changes land.

### F-D3 — Sweep prefix collision (Opus-only, P3)
`startup_sweep` matches both `.tmp_robocopy_*` (legacy 018) AND `.tmp_handbrake_copiatorul3000_*` (019, more specific). The bare `.tmp_robocopy_*` matcher could collide with an unrelated tool that creates similarly-named directories in the same destination root. Mitigated by foreign-host marker preservation (cross-machine NAS guard), but the absent-marker case still deletes.

**Suggested fix sketch**: tighten `.tmp_robocopy_*` → `.tmp_robocopy_copiatorul3000_*` (mirroring the HandBrake prefix pattern), add the new prefix to `transfer_service::transferFile`, and keep the legacy `.tmp_robocopy_*` matcher in the sweep for ONE more release as a backwards-compat sweep of pre-019 staging dirs. Drop the legacy matcher in v2.6.0.

### F-D4 — Cross-machine NAS write race (Codex-only, P3)
Two operators on different machines targeting the same NAS root could theoretically both write `.live` markers in the same staging dir name (microsecond `DateTime.now().microsecondsSinceEpoch.toRadixString(36)` tag collision is astronomically unlikely but not impossible). The host check on read is the load-bearing primitive; collision-by-tag would need a UUID upgrade.

**Suggested fix sketch**: replace the microsecond tag with a UUID v4 (or include `Platform.localHostname` as a prefix in the tag itself, e.g. `.tmp_robocopy_<host>_<tag>`). The latter is cheaper and self-disambiguating. Requires no schema or marker-format change — just a `transferFile` and `compressFile` tag-construction tweak.

### F-D5 — DST/clock-jump mtime cutoff (Opus-only, P3)
`Job.createdAt` baseline TOCTOU guard could mis-classify a foreign intrusion as own-partial if the clock jumps backward (DST end, NTP correction). The window is small (1h DST shift); operator-visible attack surface is essentially zero on a single-operator workstation.

**Suggested fix sketch**: use a monotonic clock for the comparison, OR bound the "trust window" to `now - createdAt > -3600` — anything outside that range is treated as "I don't trust the timestamp comparison" and falls back to the safe (refusal) branch. The latter is simpler.

### F-D8 — `eraseDrive Remove-Item -LiteralPath` re-verify after symlink guard (Codex-only, P3)
The 017A `eraseDrive` migration to inline-script pattern + the 019 source-side symlink guard should mean a hypothetical DCIM subdirectory with embedded special chars is fully covered. Re-verify after the 019 source-side symlink guard is in operator hands — if a real case appears in the field, it'll show up here first.

**Suggested fix sketch**: probably nothing to fix; this is a re-verification task. Add a unit test that constructs a temp DCIM tree with paths containing `[`, `]`, `*`, `?`, `` ` ``, and embedded smart quotes, runs `eraseDrive` against it (via a mocked PowerShell stub), and asserts every file is enumerated.

## Operator-reported findings (v2.5.0 acceptance)

> **Empty by design.** Populate as the operator reports issues. Each finding gets its own subsection with: which acceptance step caught it (1–21, see RELEASE_NOTES), what was expected vs observed, files / paths / log lines if available, severity guess (P1 / P2 / P3), suggested fix sketch.

### Finding template

```markdown
### F-O1 — <one-line title>
- **Acceptance step**: <step number 1–21 from RELEASE_NOTES_v2.5.0.md>
- **Expected**: <what the step said should happen>
- **Observed**: <what actually happened>
- **Severity guess**: P1 (data loss / blocks operator) / P2 (workflow degraded) / P3 (cosmetic / nice-to-have)
- **Files / logs**: <if known>
- **Repro**: <if reliably reproducible; otherwise note frequency>
- **Fix sketch**: <if obvious; otherwise leave for /speckit-plan>
```

### Findings

(none yet — populate after acceptance)

## Codex round 28+ (only if a holistic re-audit is run later)

> **Default: do not run.** Per `feedback_adversarial_review.md` "Stop conditions" and `feedback_holistic_audit.md`, additional review rounds on the same surface produce diminishing returns. If the v2.5.0 → v2.5.1 cycle uncovers signal that justifies a holistic re-audit (e.g., operator finds 3+ P1s in the field), record those findings here so the next release has structured material to work with. Otherwise leave this section empty.

## Acceptance criteria

- All operator-reported findings flagged P1 / P2 are resolved or explicitly accepted as won't-fix with operator concurrence.
- All 5 pre-known deferred P3s either resolved OR re-deferred with updated rationale (don't let them roll forward indefinitely without a decision).
- Existing 161-test suite still passes.
- New tests added for any operator-found regression so it can't recur silently.
- `flutter analyze` clean.
- CI grep guard still passes.
- Release notes bumped: `RELEASE_NOTES_v2.5.1.md` summarizing what changed.

## Workflow

1. **Wait for operator field-test signal.** Don't pre-fill the operator-findings section — wait for actual reports.
2. **Once at least one finding lands**: run `/speckit-clarify` to sharpen the spec. Treat each finding's "fix sketch" as a hypothesis to verify, not a foregone plan.
3. **`/speckit-plan`**: design the patch. Probably a single thin pass since v2.5.1 is meant to be a focused patch release, not another months-long bundle. If the patch grows beyond ~20 tasks, reconsider whether it's still a patch or has become v2.6.0 territory.
4. **`/speckit-tasks`** → **`/speckit-implement`** → review → ship.
5. **Codex review cadence**: per the v2.5.0 lesson, ONE round at plan and ONE at post-implement is appropriate for a patch release. Don't escalate to N rounds unless something new genuinely warrants it.

## Constitution check

This spec doesn't introduce new architectural decisions; it inherits from prior features. No constitutional risk flagged.

- I (Human-in-the-Loop): inherited; any new destructive action must route through `ConfirmationDialog.showCritical`.
- II (Single Codebase): inherited.
- III (Resilient Pipeline): operator findings will tell us if the v2.5.0 hardening actually held under real load.
- IV (Minimal Complexity): patch release should REMOVE complexity where possible, not add.
- V (Observable Progress): if any operator finding is "I couldn't tell what the app was doing," that's a constitutional violation and needs its own spec section.
- VI (Update Transparency): inherited.
