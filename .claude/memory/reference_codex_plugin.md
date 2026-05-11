---
name: Codex plugin for GPT adversarial reviews
description: OpenAI Codex CLI + Claude Code plugin for GPT code reviews — version state and slash-command surface
type: reference
---

**Codex CLI:** v0.130.0 (installed 2026-05-11 on Windows workstation via `npm install -g @openai/codex`; was v0.128.0 on the prior macOS install 2026-05-07)
**Codex plugin (Claude Code):** `codex@openai-codex` v1.0.4 (installed 2026-05-11 via `claude plugin marketplace add openai/codex-plugin-cc` + `claude plugin install codex@openai-codex` + `/reload-plugins`; marketplace name `openai-codex` ≠ repo slug `codex-plugin-cc`)
**Auth:** ChatGPT login active (`codex login status` → "Logged in using ChatGPT"; account `hello@badescu.design`)

**User-invocable slash commands (plugin v1.0.4):**
- `/codex:setup` — verify CLI binding, manage stop-time review gate
- `/codex:rescue` — delegate investigation / fix / follow-up to the Codex rescue subagent

The macOS-era v1.0 surface (`/codex:review`, `/codex:adversarial-review`, `/codex:status`, `/codex:result`, `/codex:cancel`) has been consolidated into `/codex:rescue` + subagent invocations as of v1.0.4. 6 agents register alongside the 2 user commands; 3 internal-helper skills (`codex:codex-cli-runtime`, `codex:codex-result-handling`, `codex:gpt-5-4-prompting`) handle wiring and should not be invoked directly.

**When to use:** After implementing a feature, before merging. Especially for security-sensitive code (Process.run calls, file operations, path construction).

**Review gate:** Presumed disabled per prior session preference (avoid runaway back-and-forth loops that drain usage). Confirm in this Windows install via `/codex:setup`.
