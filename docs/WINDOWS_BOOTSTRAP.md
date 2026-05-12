# Windows development bootstrap

Setup runbook for the Windows 11 workstation that will host Copiatorul3000 development going forward (cutover from macOS on 2026-05-11). Follow steps in order; each step is independent enough that you can pause and resume.

**Already installed (per developer, 2026-05-11):** Node.js + npm, Chocolatey, Git, Python 3.14. The steps below assume those are present and on `PATH`. If `node -v`, `choco -v`, `git --version`, and `python --version` all return versions, you're good.

> **Shell convention:** all command blocks below are **Git Bash** unless explicitly marked `powershell`. Run an admin Git Bash window for any `choco install` step (right-click Git Bash → "Run as administrator"). PowerShell is reserved for the few cases where it has no clean Bash equivalent — persistent user-env vars and user `PATH` writes.
>
> **Note on the new Claude session:** once Claude Code is installed and you `cd` into the cloned repo, the first thing the session should do is read `.claude/memory/MEMORY.md` and every file it links — that's how it picks up the full project context across the machine switch. CLAUDE.md's "Session Bootstrap" section instructs the model to do this; if it doesn't, prompt: *"Read the project memory before we start."*

---

## 1. Flutter SDK

Flutter is downloaded as a git checkout. Place it somewhere with a short, space-free path so Windows MAX_PATH limits never bite.

```bash
mkdir -p /c/src
cd /c/src
git clone https://github.com/flutter/flutter.git -b stable
```

Add `C:\src\flutter\bin` to the **user** `PATH`. Easiest via the GUI: Settings → System → About → Advanced system settings → Environment Variables → User variables → Path → Edit → New → `C:\src\flutter\bin`. Alternatively from PowerShell:

```powershell
[Environment]::SetEnvironmentVariable(
  'Path',
  [Environment]::GetEnvironmentVariable('Path', 'User') + ';C:\src\flutter\bin',
  'User'
)
```

Close and reopen your terminal so the change takes effect, then:

```bash
flutter doctor
```

Read the output carefully — `flutter doctor` is the source of truth for what's still missing. Steps 2 and 3 below address the most common gaps for Windows desktop builds; if `flutter doctor` reports anything else (Android toolchain, web toolchain), ignore it — Copiatorul3000 only targets Windows desktop.

## 2. Visual Studio Build Tools 2022 — Desktop C++ workload

`flutter build windows` requires the MSVC toolchain. The standalone Build Tools are enough; full Visual Studio Community is not needed.

```bash
choco install visualstudio2022buildtools -y --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

After install, **reboot**. Then re-run `flutter doctor` and confirm the Visual Studio line is green. If it's still red, the workload didn't install — open Visual Studio Installer GUI and manually enable "Desktop development with C++".

## 3. HandBrakeCLI

The app shells out to `HandBrakeCLI` for compression. This is **separate** from the HandBrake GUI; if you only have the GUI installed, the CLI binary isn't on `PATH`.

```bash
choco install handbrake-cli -y
HandBrakeCLI --version
```

The app also uses presets from `%APPDATA%\HandBrake\presets.json`. If the operator's preset file isn't there yet, they'll be prompted to add one — not a blocker for the dev environment.

## 4. Developer Mode (required for symlinks)

Windows blocks symlink creation by non-admin processes unless Developer Mode is on. Two paths in this project need it:

- `flutter build windows --release` fails with "Building with plugins requires symlink support" — the plugin linker creates symlinks under `build\windows\`.
- `test/unit/source_symlink_guard_test.dart` (3 cases, the F-3 source-symlink-guard suite from 019) fails at fixture-setup with `FileSystemException ... A required privilege is not held by the client, errno = 1314`.

Open the Developer settings page and toggle it on:

```bash
start ms-settings:developers
```

Toggle **Developer Mode** to **On**. No reboot needed; the change applies immediately.

## 5. GitHub CLI + auth

```bash
choco install gh -y
gh auth login
```

Choose: GitHub.com → HTTPS → authenticate via web browser. Sign in with the account that owns `termenescu97/video-pipeline`.

Verify:

```bash
gh repo view termenescu97/video-pipeline
```

## 6. Claude Code

Install globally via npm.

```bash
npm install -g @anthropic-ai/claude-code
claude --version
```

Launch once to complete OAuth:

```bash
claude
```

Sign in with the Anthropic account that has the appropriate plan. Exit (Ctrl+C twice) once auth completes; the credential lives at `%USERPROFILE%\.claude\.credentials.json` and persists across sessions.

## 7. Codex CLI + Codex Claude Code plugin

The project uses GPT adversarial reviews via the OpenAI Codex CLI (driver) wrapped by a Claude Code plugin (slash-command surface). Both are needed; the plugin can't run without the CLI.

### 7a. Install the Codex CLI

```bash
npm install -g @openai/codex
codex --version            # expected ≥ 0.130.0
```

Authenticate with ChatGPT (project uses `hello@badescu.design`):

```bash
codex login
```

This opens a browser to ChatGPT OAuth via a local loopback on port 1455. If the browser doesn't open or the loopback is blocked, fall back to device auth:

```bash
codex login --device-auth
```

Verify:

```bash
codex login status         # → "Logged in using ChatGPT"
```

### 7b. Install the Codex Claude Code plugin

In a Claude Code session — run `claude` from any directory, then inside the TUI:

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
```

> **Naming gotcha:** the marketplace name `openai-codex` differs from the repo slug `codex-plugin-cc`. Use `codex@openai-codex` for the install target — `codex@codex-plugin-cc` will fail.

After `/reload-plugins`, slash commands register. The v1.0.4 surface is intentionally narrow — only **two** user-invocable commands:

- `/codex:setup` — verify CLI binding, manage the stop-time review gate (keep it **disabled** per project convention — see `.claude/memory/reference_codex_plugin.md`).
- `/codex:rescue` — delegate investigation / fix / follow-up to the Codex rescue subagent.

The macOS-era surface (`/codex:review`, `/codex:adversarial-review`, `/codex:status`, `/codex:result`, `/codex:cancel`) was consolidated into `/codex:rescue` + 6 internal subagents as of plugin v1.0.4. Don't waste time looking for the old commands — they're not there.

Run `/codex:setup` once to confirm the CLI is bound and the review gate is off. Project model standard is `gpt-5.5` (not `gpt-5.5-codex` — that variant is rejected by this account) at `--effort high` (escalate to `xhigh` for data-loss-CRITICAL passes). If `gpt-5.5` is rejected at runtime, see `.claude/memory/feedback_adversarial_review.md`.

## 8. spec-kit CLI (`specify`)

The project's feature workflow runs through spec-kit (`/speckit-specify` → `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement`). The Claude Code plugin pieces are already in the repo (`.claude/skills/speckit-*`), but the `specify check` CLI is needed for toolchain verification.

### 8a. Set `PYTHONUTF8=1` (required before installing spec-kit)

Python 3.14 on Windows defaults stdout to `cp1252`, which can't render the Unicode glyphs the `rich` library uses for `specify check`'s pretty-printed banner. Without this env var, the next command crashes with `UnicodeEncodeError: 'charmap' codec`.

```powershell
[Environment]::SetEnvironmentVariable('PYTHONUTF8', '1', 'User')
```

**Close every shell and reopen** so the env var propagates. This is per-user, persistent, no reboot needed.

### 8b. Install `uv` + spec-kit

`uv` is the Python package manager spec-kit uses for isolated tool installs.

```bash
pip install uv
```

`uv` lands in `%APPDATA%\Roaming\Python\Python314\Scripts`. If `uv --version` fails after install, that directory isn't on user PATH yet — add it via the same GUI flow as Flutter (Settings → System → ... → User variables → Path), or via PowerShell:

```powershell
[Environment]::SetEnvironmentVariable(
  'Path',
  [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:APPDATA + '\Roaming\Python\Python314\Scripts',
  'User'
)
```

Install `specify-cli`:

```bash
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
```

`specify` binary lands in `%USERPROFILE%\.local\bin` (typically already on user PATH from `uv tool install`'s setup).

Verify everything together:

```bash
specify check
```

Expected: "Specify CLI is ready to use!" with Git + Claude Code + Codex CLI all green.

## 9. Atlassian MCP (Jira + Confluence)

Lets Claude Code read and edit Jira tickets directly. Atlassian hosts the MCP as a remote SSE endpoint with OAuth — no local process, no token to manage.

```bash
claude mcp add --scope user --transport sse atlassian https://mcp.atlassian.com/v1/sse
claude mcp list
```

Expected line: `atlassian: https://mcp.atlassian.com/v1/sse (SSE) - ! Needs authentication`. Inside a Claude Code session, run `/mcp`, pick `atlassian`, authenticate. A browser opens to `id.atlassian.com`, you OAuth, then it redirects back. After that, `claude mcp list` should show `✓ Connected`. Tool names appear as `mcp__atlassian__*` (e.g. `mcp__atlassian__jira_get_issue`, `mcp__atlassian__jira_create_issue`, `mcp__atlassian__jira_update_issue`).

Cloud-only — does not work for self-hosted Jira Server / Data Center. The project's Atlassian instance is Cloud (`*.atlassian.net`), so this path is the right one.

## 10. Clone the repo and verify build

Pick a development root. Suggested:

```bash
cd /c/Users/$USER
git clone https://github.com/termenescu97/video-pipeline.git copiatorul3000
cd copiatorul3000
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

Expected: `flutter analyze` clean, `flutter test` shows **161 passing**. If either is red, do NOT proceed to building — open Claude Code and triage. The whole point of moving development to Windows is reproducing operator issues; a red test baseline poisons that.

If the symlink-guard test cases fail with `errno = 1314`, Developer Mode (step 4) isn't actually on — re-check via `start ms-settings:developers`.

Optional smoke build of the actual Windows binary:

```bash
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\video_pipeline.exe` (binary name comes from `pubspec.yaml`'s `name: video_pipeline` field, not the product display name). If this succeeds, the Windows toolchain is fully wired up — the same path GH Actions uses on tag push.

## 11. First Claude Code session in the repo

```bash
cd /c/Users/$USER/copiatorul3000
claude
```

Session should:

1. Auto-load `CLAUDE.md` (it's at repo root — the harness picks it up).
2. Read the "Session Bootstrap — READ THIS FIRST" section of CLAUDE.md, then read `.claude/memory/MEMORY.md` and every linked file.
3. After loading memory, the session has the same context the macOS sessions had: project state, deferred bugs, false positives, feedback rules, decisions.

**Sanity check questions** to verify the context loaded:

- *"Where were we?"* → should produce the v2.5.0-pre status summary (tagged, awaiting Windows operator acceptance, 161/161 tests, 5 deferred 019 P3s, pre-check QA pending).
- *"What are the load-bearing conventions?"* → should reference CLAUDE.md's v7 / v8 / v8-017B / v8-018 / v9 sections without re-grepping the code.
- *"Are there any known false positives I shouldn't re-investigate?"* → should cite `project_false_positives.md` and list QA-5, QA-7, etc.

If any of those fall flat, the memory load didn't fire — explicitly prompt the session to read `.claude/memory/MEMORY.md` and proceed.

---

## What you should NOT do

- **Don't copy `~/.claude/.credentials.json` from macOS to Windows.** Per-machine OAuth; re-auth via `claude`, `codex login`, and `/codex:setup`.
- **Don't copy `~/.claude/projects/-Users-andreibadescu-Music/` session transcripts.** Those are macOS-specific harness state and ~40 MB of conversation history — irrelevant to a fresh session and potentially sensitive.
- **Don't push the macOS checkout further.** After the 2026-05-11 cutover commit, the macOS checkout is read-only archive. All new commits originate from the Windows machine.
- **Don't worry about reproducing the macOS auto-memory path.** The repo `.claude/memory/` is now the source of truth. CLAUDE.md tells the model to read from there, not from `~/.claude/projects/<encoded-cwd>/memory/`.

## Troubleshooting

- **`flutter doctor` shows Visual Studio Build Tools red after install**: reboot, then re-run. If still red, the C++ workload didn't install — open "Visual Studio Installer" GUI and check the "Desktop development with C++" box manually.
- **`flutter pub get` fails on a Drift-related package**: ensure Dart 3.x is bundled with your Flutter stable channel. `flutter --version` should show Dart 3.x.
- **`flutter test` shows fewer than 161 tests**: a test discovery issue. Run `flutter test --reporter expanded` and check for compilation errors. Drift generated files might be stale — re-run `dart run build_runner build`.
- **`flutter test` shows `errno = 1314` / "A required privilege is not held by the client"**: Developer Mode (step 4) is off. `start ms-settings:developers` and toggle it on. No reboot needed.
- **`flutter build windows` fails with "Building with plugins requires symlink support"**: same fix — Developer Mode is off.
- **`flutter build windows` fails with linker errors**: usually a missing C++ component. Reinstall the workload via `choco install visualstudio2022buildtools --force --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`.
- **`specify check` crashes with `UnicodeEncodeError: 'charmap' codec`**: `PYTHONUTF8=1` not set or not propagated to current shell. Close every shell, reopen, retry.
- **`/codex:rescue` or `/codex:setup` not recognized in Claude Code**: plugin didn't load. Run `/plugin list` to confirm `codex@openai-codex` shows installed; if yes, `/reload-plugins`. If no, repeat the install steps in 7b.
- **Claude Code session won't read `.claude/memory/`**: prompt explicitly — *"Read the project memory before we start."* If it still doesn't, check that the directory is actually present (`ls .claude/memory/`) and that `CLAUDE.md` was pulled fresh.

## Next steps after bootstrap

1. Resume pre-check QA on the installed `v2.5.0-pre` build. Per `HANDOFF_v2.5.0-pre.md`, UI findings from pre-check land as v2.5.0 polish (re-tag `v2.5.0-pre-2`), not v2.5.1.
2. Once the developer is satisfied with the polished build, promote to `v2.5.0` proper and hand to the operator for the 21-step Windows acceptance in `RELEASE_NOTES_v2.5.0.md`.
3. Operator field-test findings flow into `specs/020-v2.5.1-field-findings/` (skeleton already present).
