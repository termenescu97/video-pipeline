---
name: No half-baked implementations
description: Do not skip tasks or leave features partially implemented. Finish everything that was planned.
type: feedback
---

Do not skip tasks, defer implementation, or mark items as "done" when they're stubs. If a task is planned, implement it fully.

**Why:** User explicitly called out lazy behavior when tasks T024-T027 (drag-reorder, system tray) were skipped and marked complete without implementation. "Why are you being so comfortable with half-baked features?"

**How to apply:** Before marking any task as complete, verify the code is actually written and functional. If a task genuinely can't be done (e.g., needs hardware testing), say so explicitly and leave it unchecked — don't fake completion.
