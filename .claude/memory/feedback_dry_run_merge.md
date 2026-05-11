---
name: Dry-run the merge sequence before tagging a release
description: Catches CI / merge-conflict / cross-branch-drift failures at developer-time cost rather than at tag-time when GitHub Actions has already started — validated by catching a real CI guard false positive on v2.5.0-pre
type: feedback
originSessionId: f7fa2c06-99da-42b0-a18b-30a83469c30d
---
Before pushing a tag that triggers a CI build (especially for data-safety-critical bundles like v2.5.0 with 4+ feature branches), run the documented merge sequence locally on a throwaway branch first. Verify analyzer + tests pass on the merged tree. Then push for real.

**Why:** the cost asymmetry is huge. A failed merge or CI step during a real release means: (a) the broken tag is on GitHub, (b) GitHub Actions wasted 5+ minutes building a broken state, (c) you need to delete the tag (`git push origin :v<tag>`), fix, re-tag, re-push, (d) any operator who polled `/releases/latest` in the meantime saw a non-existent or broken release. Dry-running locally avoids all of that for a ~15-minute investment.

**Validated this session (v2.5.0, 2026-05-11):** the dry-run of the documented 4-step merge sequence (017A → 017B → 018 → 019 → main) caught a real bug. The CI grep guard I had added in round-27b (`! grep -rn '\$args\[' lib/`) would have failed the very first GitHub Actions build because two comment lines in `lib/services/drive_service.dart` referenced the retired `$args[0]` pattern by literal string inside backticks. The grep doesn't distinguish code from comments. Fix: rephrased the comments to "PowerShell dollar-args positional indexing" — preserves the doc, removes the literal substring the guard scans for. Caught at developer-time, not at tag-time.

**How to apply:**

1. **Create a throwaway branch from main**: `git checkout -b dry-run-<tag>-merge main`
2. **Run the documented merge sequence verbatim** (whatever the release notes specify — usually a `--no-ff` chain of feature branches).
3. **Verify the merged tree matches expectations**: `git diff --stat HEAD <target-branch>` should be empty if the branches are stacked correctly.
4. **Run the full local gate**: `flutter analyze --no-pub`, `flutter test`, plus any CI-specific guard steps (e.g., the `! grep -rn '\$args\[' lib/` guard). Anything CI does locally should be doable locally.
5. **If clean**: delete the dry-run branch (`git checkout main && git branch -D dry-run-<tag>-merge`), then re-do the merge on real main, push, tag, push tag.
6. **If broken**: fix on the feature branch (so the fix carries forward through the merge), commit, abandon the dry-run branch, re-dry-run with the fix in place to confirm. THEN proceed to real merge.

**When NOT to dry-run:**
- Single feature branch with no stacking — trivial fast-forward merge, not worth the ceremony.
- Hotfix releases of one or two commits where the cost of a re-tag is minimal anyway.
- When CI is fundamentally untrusted (e.g., flaky tests) — in that case the dry-run won't predict CI behavior reliably anyway; investigate the CI flakiness first.

**Confirmation flag on GitHub release marking:** `softprops/action-gh-release@v2` does NOT auto-detect `-pre` as a prerelease tag pattern. After pushing a `*-pre` tag, manually flip the prerelease flag: `gh release edit <tag> --prerelease`. Verify via `gh release view <tag> --json isPrerelease,isDraft`. Skip this and the `-pre` build will show as Latest, causing v<prior>.x operators to auto-prompt to upgrade to an unverified build — exactly what `-pre` was meant to prevent.
