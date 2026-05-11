---
name: Codex plugin for GPT adversarial reviews
description: OpenAI Codex plugin installed in Claude Code — enables GPT code reviews via slash commands
type: reference
---

**Plugin:** openai/codex-plugin-cc (installed 2026-05-07)
**Auth:** ChatGPT login active (hello@badescu.design)
**Codex CLI:** v0.128.0

**Commands available:**
- `/codex:review` — standard read-only code review by GPT
- `/codex:adversarial-review` — skeptical review that challenges design decisions
- `/codex:rescue` — delegate tasks (investigation, fixes, research) to Codex as background jobs
- `/codex:status` / `/codex:result` / `/codex:cancel` — manage background Codex jobs
- `/codex:setup` — verify installation, toggle review gate

**When to use:** After implementing a feature, before merging. Especially for security-sensitive code (Process.run calls, file operations, path construction).

**Review gate:** Disabled (recommended — avoids runaway back-and-forth loops that drain usage).
