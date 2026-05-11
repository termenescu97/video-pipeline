---
name: docs/WINDOWS_BOOTSTRAP.md has four undocumented gaps (validated 2026-05-11 on Adrian's video-prod workstation)
description: Four steps that the bootstrap doc misses — Developer Mode, deprecated build_runner flag, the actual exe filename, and the entire Codex/spec-kit tooling chain — that every fresh Windows dev install will hit
type: project
---

A fresh-machine bring-up on 2026-05-11 (Adrian's video-prod workstation, Windows 11 Pro 25H2, RTX 3090) successfully reached 161/161 tests + a clean `flutter build windows --release` by following `docs/WINDOWS_BOOTSTRAP.md`, BUT four steps in the doc are stale or missing. Each one bites the next dev who follows the doc verbatim.

**Why:** The doc was written during the macOS-only era and hasn't been validated end-to-end on Windows since the 2026-05-11 fleet cutover. The gaps below were discovered during the second-machine bring-up (this video-prod workstation, in addition to the existing dev workstation). They're not load-bearing for the code, only for the dev-env onboarding.

**How to apply:** When updating the bootstrap doc — or coaching the next dev / a fresh Claude session through Windows setup — patch these three points.

**Gap 1 — Developer Mode is a hard requirement, not optional.** Without it:
- `flutter build windows --release` fails on plugin symlinks ("Building with plugins requires symlink support. Please enable Developer Mode in your system settings.").
- `test/unit/source_symlink_guard_test.dart` (3 cases) fails with `FileSystemException ... A required privilege is not held by the client, errno = 1314` because the test fixture creates symlinks during setup. This is the F-3 source-symlink-guard test suite from 019.

Fix in the doc: add a step before `flutter test` — "Open `ms-settings:developers` and toggle Developer Mode on. Required for symlink creation by the test fixture AND by the release-build plugin linker."

**Gap 2 — `--delete-conflicting-outputs` was removed in the current `build_runner`.** The doc says:
```
dart run build_runner build --delete-conflicting-outputs
```
This succeeds (181 outputs generated cleanly on 2026-05-11) but prints a deprecation warning: `W These options have been removed and were ignored: --delete-conflicting-outputs`. Drop the flag from the doc. The bare `dart run build_runner build` already does what the flag used to.

**Gap 3 — Built executable filename is `video_pipeline.exe`, not `copiatorul3000.exe`.** The doc says output is at `build\windows\x64\runner\Release\copiatorul3000.exe`. Actual filename is **`video_pipeline.exe`** — Flutter takes the binary name from `pubspec.yaml`'s `name:` field (`video_pipeline`), not from the product display name (Copiatorul3000). All other artifacts in that Release dir match the doc (data/, flutter_windows.dll, sqlite3.dll, plugin DLLs). Update the doc's expected-output line.

**Gap 4 — Codex CLI + Codex plugin + uv + spec-kit CLI + `PYTHONUTF8=1` are not covered, even though the documented dev workflow depends on all of them.** A fresh dev machine running the bootstrap doc verbatim finishes with neither Codex review nor the `specify` CLI, yet the project's review process assumes `/codex:rescue` (Claude Code plugin) and the spec-kit workflow assumes `specify check` passes. Validated 2026-05-11 install order:

1. `npm install -g @openai/codex` (Codex CLI — ended at v0.130.0)
2. `codex login` (ChatGPT OAuth; local loopback on port 1455; `--device-auth` fallback if browser doesn't open)
3. `claude plugin marketplace add openai/codex-plugin-cc` (registers `openai-codex` marketplace — note the marketplace name differs from the repo slug)
4. `claude plugin install codex@openai-codex` (plugin v1.0.4)
5. `/reload-plugins` (or restart Claude Code so slash commands register)
6. `/codex:setup` (verify CLI binding + confirm stop-time review gate is **off**)
7. `pip install uv` (Python package manager — installs to user site-packages; ends up in `%APPDATA%\Roaming\Python\Python314\Scripts`, which must be added to user PATH)
8. `uv tool install specify-cli --from git+https://github.com/github/spec-kit.git` (spec-kit CLI; binary lands in `%USERPROFILE%\.local\bin`, already on user PATH from a prior install in Adrian's case)
9. `[Environment]::SetEnvironmentVariable('PYTHONUTF8', '1', 'User')` (Python 3.14 + Windows `cp1252` stdout encoding fix — see `project_windows_python_utf8.md`; without it `specify check` crashes on the spec-kit banner)
10. `specify check` should report "Specify CLI is ready to use!" with Git + Claude Code + Codex CLI all green

Add a "Code review + spec-kit tooling" section to the bootstrap doc covering these 10 steps, or link to a separate `docs/CODEX_AND_SPECKIT_BOOTSTRAP.md`.
