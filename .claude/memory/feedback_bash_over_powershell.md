---
name: Prefer Bash over PowerShell on Windows
description: User prefers the Bash tool (Git Bash) over PowerShell for shell commands, even though PowerShell is the Windows default — applies across all sessions
type: feedback
---

Default to the Bash tool for shell commands on Windows. Reach for PowerShell only when the task genuinely requires Windows-only primitives (registry edits, COM objects, Windows-only cmdlets, environment-variable persistence via `[Environment]::Set...`).

**Why:** During the fresh-machine setup on 2026-05-11 the user pushed back the first time a check ran in PowerShell, asking "why are you using powershell and not bash?". Their working pattern on this machine is Git Bash. PowerShell is jarring and forces them to mentally context-switch.

**How to apply:**
- POSIX-style command? → Bash.
- Pipelines, file ops, `gh`/`git`/`flutter`/`dart` invocations? → Bash.
- Reaching for `setx` / user PATH writes / Windows installers / registry / WMI? → PowerShell is fine (those cases produce no popups and have no clean Bash equivalent). The setup session used PowerShell only for `[Environment]::SetEnvironmentVariable('Path', ..., 'User')`.
- Don't preface Bash commands with `cmd.exe /c` unless POSIX really can't express the call — the user reads the command text and the indirection is noise.
