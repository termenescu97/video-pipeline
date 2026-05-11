---
name: PYTHONUTF8=1 required on Windows for Python rich-using CLIs
description: Python 3.14 + Windows + rich library crashes on Unicode glyphs unless PYTHONUTF8=1 is set; affects specify check and any rich-using Python CLI
type: project
---

Python 3.14 on Windows defaults stdout to `cp1252` (Windows-1252), which can't encode the Unicode box-drawing / emoji glyphs the `rich` library uses for pretty-printed output. Any Python CLI that uses `rich` to render trees, tables, or status output will crash with `UnicodeEncodeError: 'charmap' codec can't encode characters in position 0-N` — most prominently `specify check` (the spec-kit toolchain check), but any modern Python CLI is suspect.

**Why:** Encountered on Windows 11 Pro 25H2 with Python 3.14.5 during the 2026-05-11 fresh-machine bring-up. `specify check` immediately faulted on the spec-kit banner; the same code path works on macOS because macOS Python defaults to UTF-8 stdout. Fix is Python's built-in UTF-8 mode (`PYTHONUTF8=1`), which forces UTF-8 for stdin/stdout/stderr regardless of system locale.

**How to apply:** Set `PYTHONUTF8=1` as a persistent user env var on every Windows dev machine — `[Environment]::SetEnvironmentVariable('PYTHONUTF8', '1', 'User')` from PowerShell, or `setx PYTHONUTF8 1`. Already set on Adrian's video-prod workstation 2026-05-11. Once set, Python processes from new shells pick it up automatically — no per-command prefix needed. Existing Claude Code / shell sessions need to be restarted to inherit it.

If you ever see `UnicodeEncodeError: 'charmap' codec` from a Python CLI on Windows, check this env var first.
