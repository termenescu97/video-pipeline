---
name: Copiatorul3000 release workflow
description: How to ship a tagged release — merge, tag, push, GitHub Actions builds, app auto-prompts on launch
type: reference
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
The release flow validated through v2.0–v2.4.0:

```
git checkout main
git merge --no-ff feature/<branch>           # bundle multiple features if appropriate
git tag vX.Y.Z
git push origin main vX.Y.Z
```

GitHub Actions (`.github/workflows/release.yml`) triggers on tag push, builds the Windows .exe, packages it, and creates a GitHub Release via `softprops/action-gh-release@v2`.

**Auto-update mechanics (`lib/services/update_service.dart`)**:
- App polls `https://api.github.com/repos/termenescu97/video-pipeline/releases/latest` on launch.
- Compares against the local version sourced from `pubspec.yaml` via `package_info_plus`.
- If newer, prompts the operator via dialog (Constitution Principle VI — never silent).
- **Gotcha:** `/releases/latest` excludes pre-releases. Tag a build with `-pre` suffix (or check the "pre-release" box in the GitHub Release UI) to upload a Windows build for staging without prompting operators. Useful when bundling work across multiple features and you want internal QA before going live.

**Bundling preference (operator):** Pull deferred fixes into the current release rather than ship and request repeat QA. v2.4.0 bundled 014 + 015 + 016 because operator's standing rule is "don't make me QA the same workflow three times in three weeks." See `feedback_bundle_before_qa.md`.

**Internal-tool simplifications consciously rejected:**
- No staging environment. Operator runs `.exe` directly.
- No pre-release tag dance for normal merges. Just merge → tag → push.
- No release notes file beyond the GitHub Release body (auto-generated from commit log).

**Why:** Single-team internal tool. The cost of release ceremony exceeds the cost of operator-driven manual QA. The operator pushed back explicitly when an earlier session over-engineered this: "we are overcomplicating this for no reason, its an internal tool, do we really need all this?"

**How to apply:** Default to the simple flow above. Don't propose pre-release tags, draft releases, or staging environments unless the operator asks. If they want a build on the workstation but not yet "live," the simplest path is a `-pre` suffix on the tag — it skips the auto-update prompt while still firing GitHub Actions.

**Exception — data-safety-bundle releases (validated v2.5.0, 2026-05-11):** when a release contains data-safety hardening that resolves a real prior production failure (e.g. v2.5.0's executor blockers from the operator's 2026-05-08 161 GB transfer test) AND has gone through many adversarial-review rounds, ship to a `-pre` tag FIRST and run a documented operator acceptance checklist before promoting. Rationale: incremental adversarial reviews hit diminishing returns past a certain point (see `feedback_adversarial_review.md` "Stop conditions") — the operator's real-bytes-on-disk field test is the load-bearing gate, not review #N+1. v2.5.0 ships under a 21-step acceptance documented in `RELEASE_NOTES_v2.5.0.md`. This pattern doesn't apply to small bug fixes or polish releases — only to releases bundling load-bearing data-safety changes.
