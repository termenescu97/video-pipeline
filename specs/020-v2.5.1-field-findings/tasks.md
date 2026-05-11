# 020 — v2.5.1 Field Findings: Tasks

> **Status: SKELETON.** Pre-populated with the 5 known deferred P3s as task placeholders. The operator-findings task section is empty by design — populate after Windows acceptance reports come in. **Do not start implementing these tasks yet.** This file is a slot, not a work order.

## Phase 0 — Wait state (do not start)

- [ ] **T000** Operator runs the v2.5.0 21-step Windows acceptance from `RELEASE_NOTES_v2.5.0.md`. Reports any P1 / P2 / P3 findings into `spec.md` → "Operator-reported findings". Until at least one finding lands OR all 5 pre-known P3s are explicitly scheduled, this spec stays in skeleton state.

## Phase 1 — Sharpen + plan (gated on T000)

- [ ] **T001** `/speckit-clarify` against the populated `spec.md`. For EACH operator-reported finding, ask: (a) is the "expected vs observed" framing accurate, (b) is the severity guess right, (c) is the fix sketch the right shape or does it need a different approach?
- [ ] **T002** `/speckit-plan` — design the patch as a single coherent pass. Don't split into sub-features unless the operator-finding count is genuinely large (>10 P1+P2). For pre-known P3s, decide which to fix vs which to re-defer with updated rationale.
- [ ] **T003** ONE round of Codex `--model gpt-5.5 --effort high` review on the plan. NOT N rounds — see `feedback_adversarial_review.md` "Stop conditions".

## Phase 2 — Pre-known deferred P3s (skeleton)

Each task below is a stub. Re-verify the fix sketch is still correct against current code before implementing — comments and line numbers may have moved.

- [ ] **T010** [F-D1] Size-mode TOCTOU. File: `lib/services/job_queue_service.dart::_processTransfer` (size-mode branch). Test: extend `test/unit/size_mode_progress_order_test.dart` with a TOCTOU injection case (mid-call file truncation). Sharpen the fix shape during /speckit-plan; one of "stat-twice + compare" or "hold a file handle" or "accept and document" — cheapest depends on Dart's File API behavior on Windows.
- [ ] **T011** [F-D3] Sweep prefix collision. Files: `lib/services/transfer_service.dart::transferFile` (rename `.tmp_robocopy_` → `.tmp_robocopy_copiatorul3000_`), `lib/services/startup_sweep.dart` (add new prefix to matcher; KEEP legacy matcher for one release). Test: extend `test/unit/staging_dir_sweep_test.dart` cases 1+2 to cover both prefixes.
- [ ] **T012** [F-D4] Cross-machine NAS write race. Files: `lib/services/transfer_service.dart` + `lib/services/compression_service.dart` (tag construction). Switch from `microsecondsSinceEpoch.toRadixString(36)` to `${Platform.localHostname}_${microsecondsSinceEpoch.toRadixString(36)}`. Test: add a case asserting two simulated hosts produce non-colliding tags.
- [ ] **T013** [F-D5] DST/clock-jump mtime. File: `lib/services/job_queue_service.dart::_processTransfer` (mtime cutoff guard). Add a "trust window" check: if `now - createdAt < -3600`, treat as unsafe and route to refusal branch. Test: synthetic DST-jump injection.
- [ ] **T014** [F-D8] `eraseDrive` re-verify after symlink guard. File: `lib/services/drive_service.dart::eraseDrive`. Add unit test constructing a temp DCIM tree with paths containing `[`, `]`, `*`, `?`, `` ` ``, smart quotes; verify enumeration via mocked PowerShell stub. **Likely no code change** — this is a verification task that may close cleanly with just the new test.

## Phase 3 — Operator-reported findings (populate as they land)

- [ ] **T0XX** [F-OY] <one-line title> — `<file_path:line_or_function>`. <Brief approach>. Test in `test/unit/<test_file>.dart`.

(Add one task per operator finding. Use `T020+` numbering for operator-found work to keep separate from pre-known P3 numbering at T010-T014.)

## Phase 4 — Verification + ship

- [ ] **T100** All flagged findings either resolved or re-deferred with operator concurrence. Re-deferred items move to a new "v2.5.2 deferred" subsection in CLAUDE.md.
- [ ] **T101** `flutter analyze --no-pub` clean.
- [ ] **T102** `flutter test` — all existing 161 tests still pass; new tests for each fixed finding pass.
- [ ] **T103** CI grep guard `! grep -rn '\$args\[' lib/` returns 0.
- [ ] **T104** Dry-run merge sequence locally (mirror v2.5.0 process from `RELEASE_NOTES_v2.5.0.md`): branch from main, merge `020-v2.5.1-field-findings`, verify analyzer + tests pass on merged tree, delete dry-run branch. Catches merge conflicts at our time, not GH Actions time.
- [ ] **T105** ONE round of Codex `--model gpt-5.5 --effort high` post-implement review. NOT N rounds.
- [ ] **T106** Update `CLAUDE.md`: bump test count, mark this feature complete in the table, add v2.5.1 to "Latest release" once tagged. Add any new load-bearing conventions to the existing v9 section if applicable.
- [ ] **T107** Write `RELEASE_NOTES_v2.5.1.md`. One subsection per finding addressed; one subsection listing re-deferred items (if any).
- [ ] **T108** Tag `v2.5.1-pre`, GH Actions builds, operator runs a focused acceptance (subset of the v2.5.0 21-step list — only the steps relevant to what changed). After pass: re-tag `v2.5.1` to promote.

## Dependencies

- T001 → T002 → T003 (sharpen → plan → review-plan).
- T010-T014 may run in parallel with operator-found tasks unless they share files.
- All Phase 2 + Phase 3 tasks gate on Phase 1 completion.
- All Phase 4 tasks gate on Phase 2 + Phase 3 completion.

## Effort estimate (ballpark, revise after operator findings land)

- If 0 operator P1s + 0 operator P2s land: this becomes a small polish patch, ~5–10 task pass to address the 5 P3s. ~1 day.
- If 1–3 operator P1s/P2s land: ~10–20 tasks, ~2–3 days. Single coherent patch.
- If >5 operator P1s/P2s land: this isn't a patch anymore — escalate to a v2.6.0-scope bundle and split into a fresh feature spec.

## Anti-goals

- **Do not** pre-implement the P3s before operator findings land. Bundle preference says we wait, gather, fix in one pass.
- **Do not** run a holistic re-audit "just in case." See `feedback_holistic_audit.md` — it's a one-shot tool per release surface.
- **Do not** escalate Codex review cadence past one-at-plan + one-at-implement unless real signal demands it. The v2.5.0 cycle taught the cost of compulsive reviewing.
