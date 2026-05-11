---
name: Never skip speckit-clarify
description: Always run /speckit-clarify in the spec-kit flow — user considers it important even for well-defined bugs
type: feedback
---

Never suggest skipping `/speckit-clarify` in the spec-kit flow. Always run it, even when the issues seem well-defined.

**Why:** User explicitly corrected this: "stop suggesting to skip it... its important to run it." The clarify step caught real decisions in every batch (e.g., subdirectory preservation strategy, job status on shutdown, scan error reporting, stale lock detection, first-run trigger, operator name storage, CSV save method).

**How to apply:** When running the spec-kit flow, always proceed through clarify after specify. Don't suggest skipping it or going "straight to plan." Present it as the natural next step.
