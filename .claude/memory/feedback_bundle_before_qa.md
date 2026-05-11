---
name: Bundle deferred fixes before asking for QA
description: User prefers fixing all known issues into the current release rather than shipping incrementally and asking for repeated QA rounds
type: feedback
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
When a review pass surfaces deferred items (HIGH-level holes, "v2.x.1 follow-on" candidates, hypotheses needing runtime test), do NOT ship the current version with those known-deferred items and ask for QA in between. Bundle them into the current release scope first. The user does QA once, at the end, on the most stable available build.

**Why:** The user's quote, after I proposed "ship v2.4.0 → manual QA → 015 in v2.4.1": "No point in me doing any QA now, I'll start testing when we actually have a product that we can't keep finding holes in." The frustration is cycle cost — every QA round on a known-incomplete build means re-running the full test plan against a build that will be revised anyway. They'd rather wait for convergence and test once than test twice.

**How to apply:**
- After a review, when triaging accepted/pushback/deferred: anything in "deferred" that's actually fixable in the current dev environment goes into the current release scope, not a follow-on. Only true blockers (Windows-only behaviors, hypothesis findings, scope-creep refactors) stay deferred.
- Communicate the scope inflation explicitly. "I'm pulling X into v2.Y.0 so you only QA once" — let the user push back if they want a smaller release.
- Don't ask the user to QA an interim build. If you would have asked for QA, hold the request until the bundled scope is done and reviewed.
- The "spec-kit then ship" cadence still holds — bundling means the v2.Y.0 scope grows, not that we skip /speckit-clarify or the adversarial review.
