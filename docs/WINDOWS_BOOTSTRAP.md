# Windows development bootstrap

Setup runbook for the Windows 11 workstation that will host Copiatorul3000 development going forward (cutover from macOS on 2026-05-11). Follow steps in order; each step is independent enough that you can pause and resume.

**Already installed (per developer, 2026-05-11):** Node.js + npm, Chocolatey, Git. The steps below assume those three are present and on `PATH`. If `node -v`, `choco -v`, and `git --version` all return versions, you're good.

> **Note on the new Claude session:** Once Claude Code is installed and you `cd` into the cloned repo, the first thing the session should do is read `.claude/memory/MEMORY.md` and every file it links — that's how it picks up the full project context across the machine switch. CLAUDE.md's "Session Bootstrap" section instructs the model to do this; if it doesn't, prompt: *"Read the project memory before we start."*

---

## 1. Flutter SDK

Flutter is downloaded as a git checkout. Place it somewhere with a short, space-free path so Windows MAX_PATH limits never bite.

```powershell
# In an elevated PowerShell
mkdir C:\src
cd C:\src
git clone https://github.com/flutter/flutter.git -b stable
```

Add `C:\src\flutter\bin` to the system `PATH` (Settings → System → About → Advanced system settings → Environment Variables → System variables → Path → Edit → New). Open a fresh terminal, then:

```powershell
flutter doctor
```

Read the output carefully — `flutter doctor` is the source of truth for what's still missing. Steps 2 and 3 below address the most common gaps for Windows desktop builds; if `flutter doctor` reports anything else (Android toolchain, web toolchain), ignore it — Copiatorul3000 only targets Windows desktop.

## 2. Visual Studio Build Tools 2022 — Desktop C++ workload

`flutter build windows` requires the MSVC toolchain. The standalone Build Tools are enough; full Visual Studio Community is not needed.

```powershell
# Elevated PowerShell
choco install visualstudio2022buildtools -y --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

After install, **reboot**. Then re-run `flutter doctor` and confirm the Visual Studio line is green. If it's still red, the workload didn't install — open Visual Studio Installer GUI and manually enable "Desktop development with C++".

## 3. HandBrakeCLI

The app shells out to `HandBrakeCLI` for compression. This is **separate** from the HandBrake GUI; if you only have the GUI installed, the CLI binary isn't on `PATH`.

```powershell
choco install handbrake-cli -y
```

Verify:

```powershell
HandBrakeCLI --version
```

The app also uses presets from `%APPDATA%\HandBrake\presets.json`. If the operator's preset file isn't there yet, they'll be prompted to add one — not a blocker for the dev environment.

## 4. GitHub CLI + auth

```powershell
choco install gh -y
gh auth login
```

Choose: GitHub.com → HTTPS → authenticate via web browser. Sign in with the account that owns `termenescu97/video-pipeline`.

Verify:

```powershell
gh repo view termenescu97/video-pipeline
```

## 5. Claude Code

Install globally via npm. Node was already installed by the developer.

```powershell
npm install -g @anthropic-ai/claude-code
claude --version
```

Launch once to complete OAuth:

```powershell
claude
```

Sign in with the Anthropic account that has the appropriate plan. Exit (Ctrl+C twice) once auth completes; the credential lives at `%USERPROFILE%\.claude\.credentials.json` and persists across sessions.

## 6. Codex plugin (GPT adversarial reviews)

Inside a Claude Code session — `cd` anywhere, then `claude`:

```
/plugin install openai/codex-plugin-cc
```

Follow the prompts. After install:

```
/codex:setup
```

Authenticate with ChatGPT (the project uses `hello@badescu.design`). On model selection, the project standard is:

- **Model**: `gpt-5.5` (NOT `gpt-5.5-codex` — that variant is rejected by this account)
- **Effort**: `high` (or `xhigh` for data-loss-CRITICAL passes)

If `gpt-5.5` is rejected at runtime, see `.claude/memory/feedback_adversarial_review.md` for the workaround and escalation. Don't block development on Codex auth — if it's flaky, defer adversarial reviews until it's sorted.

## 7. Clone the repo and verify build

Pick a development root. Suggested:

```powershell
cd C:\Users\<your-user>
git clone https://github.com/termenescu97/video-pipeline.git copiatorul3000
cd copiatorul3000
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

Expected: `flutter analyze` clean, `flutter test` shows **161 passing**. If either is red, do NOT proceed to building — open Claude Code and triage. The whole point of moving development to Windows is reproducing operator issues; a red test baseline poisons that.

Optional smoke build of the actual Windows binary:

```powershell
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\copiatorul3000.exe`. If this succeeds, the Windows toolchain is fully wired up — the same path GH Actions uses on tag push.

## 8. First Claude Code session in the repo

```powershell
cd C:\Users\<your-user>\copiatorul3000
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

- **Don't copy `~/.claude/.credentials.json` from macOS to Windows.** Per-machine OAuth; re-auth via `claude` and `/codex:setup`.
- **Don't copy `~/.claude/projects/-Users-andreibadescu-Music/` session transcripts.** Those are macOS-specific harness state and ~40 MB of conversation history — irrelevant to a fresh session and potentially sensitive.
- **Don't push the macOS checkout further.** After this commit, the macOS checkout is read-only archive. All new commits originate from the Windows machine.
- **Don't worry about reproducing the macOS auto-memory path.** The repo `.claude/memory/` is now the source of truth. CLAUDE.md tells the model to read from there, not from `~/.claude/projects/<encoded-cwd>/memory/`.

## Troubleshooting

- **`flutter doctor` shows Visual Studio Build Tools red after install**: reboot, then re-run. If still red, the C++ workload didn't install — open "Visual Studio Installer" GUI and check the "Desktop development with C++" box manually.
- **`flutter pub get` fails on a Drift-related package**: ensure Dart 3.x is bundled with your Flutter stable channel. `flutter --version` should show Dart 3.x.
- **`flutter test` shows fewer than 161 tests**: a test discovery issue. Run `flutter test --reporter expanded` and check for compilation errors. Drift generated files might be stale — re-run `dart run build_runner build --delete-conflicting-outputs`.
- **`flutter build windows` fails with linker errors**: usually a missing C++ component. Reinstall the workload via `choco install visualstudio2022buildtools --force --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`.
- **Claude Code session won't read `.claude/memory/`**: prompt explicitly — *"Read the project memory before we start."* If it still doesn't, check that the directory is actually present (`ls .claude/memory/`) and that `CLAUDE.md` was pulled fresh.

## Next steps after bootstrap

1. Resume pre-check QA on the installed `v2.5.0-pre` build. Per `HANDOFF_v2.5.0-pre.md`, UI findings from pre-check land as v2.5.0 polish (re-tag `v2.5.0-pre-2`), not v2.5.1.
2. Once the developer is satisfied with the polished build, promote to `v2.5.0` proper and hand to the operator for the 21-step Windows acceptance in `RELEASE_NOTES_v2.5.0.md`.
3. Operator field-test findings flow into `specs/020-v2.5.1-field-findings/` (skeleton already present).
