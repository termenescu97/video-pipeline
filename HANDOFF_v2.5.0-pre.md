# Handoff — v2.5.0-pre is built, developer pre-check pending

> **Purpose of this file**: session-state snapshot for a fresh Claude session. Captures what's not yet in CLAUDE.md / memory because it just happened. Read this FIRST, then proceed to whatever the user brings up. Once the work it describes is complete (UI fixes done, re-tagged), this file should be deleted (it's session-specific, not durable).

## Where things stand (2026-05-11, end of session)

**v2.5.0-pre is tagged, built, and installed on the developer's machine.**

- `main` is at commit `e004d2c` (merge of feature 019). Four `--no-ff` attribution merges visible in `git log --graph --merges`: 017A → 017B → 018 → 019.
- Tag `v2.5.0-pre` pushed to origin. GitHub Actions Windows build succeeded in 5m28s. Release `v2.5.0-pre` exists at https://github.com/termenescu97/video-pipeline/releases/tag/v2.5.0-pre with the .exe zip attached. **Correctly marked as Pre-release** (we flipped the flag manually — `softprops/action-gh-release@v2` does NOT auto-detect `-pre` as a prerelease pattern; future tags with `-pre` suffix will also need the manual flip via `gh release edit <tag> --prerelease`).
- v2.4.0 still tagged as Latest — v2.4.0 operators do NOT auto-prompt to upgrade. By design.
- Local working tree: clean. 161/161 tests passing. `flutter analyze` clean.

## The actual next step (this is what the user is about to ask about)

**The developer (user) installed v2.5.0-pre locally and found UI issues during their own pre-check.** They have NOT handed it to the actual operator (the video team's non-technical user on the Windows workstation) for formal QA yet. They want to fix the UI things they spotted FIRST, then hand off a polished build.

**Expect the user to come into the fresh session with a list of UI complaints.** They will describe specific things they saw that bug them. Your job is to:

1. **Capture each finding into `specs/020-v2.5.1-field-findings/spec.md`** → "Operator-reported findings" section (the template is already there). Even though these are developer-found-during-pre-check rather than operator-found-during-formal-QA, the same slot works. You may want to rename the section to "Pre-operator UI findings" or similar, but the spec already accommodates this.

2. **Decide framing with the user**: are these UI fixes (a) v2.5.0 polish (re-tag `v2.5.0-pre-2`, ship after fix), or (b) v2.5.1 patch (ship v2.5.0 as-is, fix in next release)? **Recommendation: (a) v2.5.0 polish.** The developer found these BEFORE the operator saw them — fixing now means the operator's first impression of v2.5.0 is the polished version, not the rough one. The whole point of a `-pre` tag is the developer-and-operator-acceptance buffer; this is exactly what that buffer is for. v2.5.1 stays reserved for what the operator finds AFTER seeing the polished v2.5.0.

3. **Run the spec-kit flow on the findings**: `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement`. This is real spec-kit work; don't skip clarify (`feedback_never_skip_clarify.md`).

4. **Re-tag after fix**: delete the old `v2.5.0-pre` tag (`git tag -d v2.5.0-pre && git push origin :v2.5.0-pre`), create `v2.5.0-pre-2` on the new commit, push. **You'll need to manually mark v2.5.0-pre-2 as prerelease via `gh release edit v2.5.0-pre-2 --prerelease`** since the GH Action doesn't auto-detect `-pre`. Alternative: keep the old tag, just push a NEW `v2.5.0-pre-2` — simpler but leaves a stale tag pointing at the un-polished build. Up to the user.

5. **Then**: hand off `OPERATOR_QA_v2.5.0.md` to the actual operator on the Windows workstation. They run the 4-tier checklist, log any findings to `specs/020-v2.5.1-field-findings/spec.md`, and that becomes the next-release scope.

## Don't fall into these traps

- **Don't suggest the user hand off to operator yet.** They explicitly DON'T want to do that until UI is polished. Operator QA happens AFTER pre-check fixes.
- **Don't suggest another round of Codex adversarial review** on the UI fixes. The lesson from this session (encoded in `feedback_adversarial_review.md` → "Stop conditions") is: stop reviewing past zero-P1. UI polish for a -pre tag does NOT need N rounds. ONE round at plan, ONE at implement, or fewer if the change is small. The dry-run merge before the new -pre-2 tag IS still valuable (it caught a real bug this session — see point below).
- **Don't suggest doing a fresh holistic threat-model audit.** That's a one-shot tool per release surface (`feedback_holistic_audit.md`). 019's audit covered v2.5.0. No new audit until the next major release surface.
- **Don't suggest a v2.5.1 spec-kit cycle yet.** v2.5.1 is for after-operator-QA findings, not for the developer's pre-check findings.

## What was accomplished in the session that just ended

So you have full context:

- **019 Codex round-27b fold-back** (commit `29f29e1`): legacy-job banner now surfaces via `QueueStateNotifier.operatorMessages` stream → SnackBar; queue starvation fixed via new `JobDao.getNextQueuedJobExcluding(Set<int>)`; batch identity-refused reported as distinct axis from `skipped`; HandBrake sweep made recursive (was missing nested staging dirs under compression hierarchy); recovery branch clears stale `forceDestDeleteApproved`; CI grep guard step added to `.github/workflows/build.yml`.
- **019 Phase 11 + 12 docs** (commit `a6e7cc6`): new "v9 (019) Load-Bearing Conventions" section in CLAUDE.md; "Workflow-integrity hardening (019)" subsection in `RELEASE_NOTES_v2.5.0.md`; 8 019-specific Windows acceptance steps added; merge sequence documented.
- **Honest reckoning on the review cycle** (the meta-moment of the session): user challenged me on the "vicious cycle" pattern after 27 Codex rounds. I admitted the pattern was real. Encoded the lesson durably as "Stop conditions" in `feedback_adversarial_review.md` and in CLAUDE.md → "Codex Adversarial-Review Cadence". The encoded rule: stop same-framing reviews at zero-P1 trajectory; if a different lens is needed, run a holistic audit (not another incremental round); past the diminishing-returns point, the load-bearing gate is real-world operator field-test, not review #N+1.
- **Comprehensive docs + memory refresh** (commit `5ca555a`): CLAUDE.md current state bumped to 2026-05-11; feature table updated with 018 + 019; Codex Cadence section gained the "Stop conditions" subsection; roadmap rewritten (v2.5.0 = workflow-integrity bundle; v2.5.1 = post-operator findings; v2.6.0 = NAS upload, was previously v2.5).
- **Grep guard CI fix** (commit `dd2894b`): the round-27b CI grep guard would have failed the v2.5.0-pre build because two comment lines in `lib/services/drive_service.dart` referenced the retired `$args[0]` pattern by literal substring inside backticks. Rephrased to "PowerShell dollar-args positional indexing" — preserves the doc, kills the literal match. **THIS WAS THE BUG THE DRY-RUN MERGE CAUGHT** — see "Dry-run merge catches CI failures" lesson encoded in memory.
- **v2.5.1 spec skeleton** (commit `d77d5cb`): `specs/020-v2.5.1-field-findings/` pre-created with `spec.md` + `tasks.md`. Pre-populates the 5 deferred 019 P3s (F-D1 through F-D8). Empty operator-findings section with template. **This is the slot the user's UI findings will (probably) NOT go into — see "framing" decision point above.**
- **OPERATOR_QA_v2.5.0.md** (commit `07721eb`): 4-tier focused acceptance checklist for the operator (Pre-flight → Smoke → 161 GB run → UI → optional negative). Markdown checkboxes for progress. Operator-friendly tone. This is what the operator will run AFTER the UI fixes land.
- **Dry-run merge → real merge → push** (commits `c014b4f` through `e004d2c`): the documented 4-step `--no-ff` sequence into main worked cleanly (tree-equivalent to 019 branch after merge). Pushed main + tagged `v2.5.0-pre`. GitHub Actions built successfully.
- **Romanian work reports drafted** for the developer's non-technical manager covering May 6/7/8. Not in the repo (delivered as chat content). The developer copy-pasted into their MD-to-PDF editor.

## Files to know about (relative to repo root)

| File | Purpose |
|---|---|
| `CLAUDE.md` | Auto-loaded project state. Reflects post-019. Read first. |
| `RELEASE_NOTES_v2.5.0.md` | Full operator-facing release notes + 21-step Windows acceptance + merge sequence |
| `OPERATOR_QA_v2.5.0.md` | Focused 4-tier acceptance checklist (operator's actual playbook on workstation) |
| `specs/020-v2.5.1-field-findings/spec.md` | Pre-created slot for findings. Has a finding template. Currently empty operator-findings section. |
| `specs/020-v2.5.1-field-findings/tasks.md` | Pre-populated tasks for the 5 deferred 019 P3s; placeholder for operator findings |
| `specs/v2.5.0-audit-findings.md` | 019's holistic audit synthesis (Opus + Codex parallel agents) |
| `specs/v2.5.0-pre-tag-findings.md` | 017A/017B-era pre-tag findings (historical reference) |
| `.github/workflows/build.yml` | CI workflow. New step: "PowerShell argv guard" runs `grep -rn '\$args\[' lib/` and fails if any hit. |

## Memory state (auto-loaded; verify before relying on file:line citations)

Index at `~/.claude/projects/-Users-andreibadescu-Music/memory/MEMORY.md`. Notable entries:

- `feedback_adversarial_review.md` — Codex review pattern + "Stop conditions" subsection (added this session, durable lesson from the cycle reckoning)
- `feedback_holistic_audit.md` — new this session — when incremental rounds hit diminishing returns, run parallel-agent 5-tier audit
- `feedback_bundle_before_qa.md` — operator's standing rule to bundle deferred fixes rather than ship + repeat-QA
- `feedback_never_skip_clarify.md` — always run /speckit-clarify
- `project_copiatorul3000.md` — current state pointer (note: a brand-new fresh session should re-read CLAUDE.md to get truly-current state, since memory is point-in-time)
- `project_v2_4_load_bearing.md` — v2.4.0 + v2.5.0 (017A/017B/018) + v9 (019) invariants pointer
- `project_open_bugs.md` — deferred items + the 5 v2.5.1 P3s
- `project_release_workflow.md` — merge → tag → push pattern; "Exception — data-safety-bundle releases" section added this session

## People involved (so a fresh session doesn't confuse them)

- **"User" / "Developer"** = you, the technical lead reading this. Andrei. Romanian-speaking. The one writing the Dart code, running the spec-kit flow, doing pre-check QA.
- **"Operator"** = the non-technical video editor on the Windows workstation in the studio. The actual end-user of the app. The one who'll run `OPERATOR_QA_v2.5.0.md`.
- **"Manager"** = developer's manager who receives the daily Romanian work reports. NOT the operator. NOT involved in QA.

The video team uses the app on the workstation; the developer builds and tests it; the manager just wants daily progress reports.

## Open question for the user to confirm in the fresh session

When the user describes the UI issues they found:

> **"Should these UI fixes ship as v2.5.0 polish (re-tag `v2.5.0-pre-2` after fix, then operator runs QA on the polished build) or as v2.5.1 (operator QAs the current v2.5.0-pre AS-IS, then we patch what they find PLUS your UI findings in v2.5.1)?"**
>
> **Recommended: v2.5.0 polish (option a).** Cleanest narrative: operator never sees the rough version. `-pre` tag's whole purpose is the dev-and-operator buffer before the real release; this is exactly the buffer's job. v2.5.1 stays reserved for what the operator finds AFTER the polished v2.5.0 lands.
