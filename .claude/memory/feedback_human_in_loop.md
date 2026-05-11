---
name: Human-in-the-loop for destructive actions
description: All destructive or irreversible actions in the video workflow automation must require explicit human confirmation — never automate deletions or overwrites silently.
type: feedback
---

Destructive, irreversible, or source-data-affecting actions must always be gated behind manual user confirmation in the GUI. Never automate these silently.

**Why:** The video team works with large, hard-to-recover files (50–100 GB per clip). An accidental automated deletion could mean losing an entire shoot. The user explicitly stated this is "super important" and must be respected in all planning.

**How to apply:** When designing any flow for this project, check if the step modifies or deletes source data. If yes, it needs a confirmation button/dialog — not an automatic trigger. Examples: SD card erasure, deleting uncompressed originals, overwriting existing files.
