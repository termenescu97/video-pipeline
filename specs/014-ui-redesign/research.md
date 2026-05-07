# Research: UI/UX Redesign — Visual Hierarchy & Operator Trust

**Feature**: 014-ui-redesign
**Date**: 2026-05-07

## R1: Three-column layout vs responsive collapse

**Decision**: Always-on three-column layout. Minimum window size 1280×720. No responsive collapse logic.

**Rationale**: The team uses one fixed Windows 11 workstation. A hard minimum is simpler than maintaining a responsive variant. It also forces the layout to be designed once, well, instead of split brains for narrow vs wide. The 1280×720 minimum is conservative for a desktop app — every modern monitor exceeds it, and `window_manager` enforces minimum sizes natively.

**Alternatives considered**:
- 800×600 with responsive collapse to two-column at <1100px: more flexibility, double the design effort, risk of bugs in the collapsed state nobody tests.
- 1366×768 minimum: tighter, may exclude older monitors.

## R2: Sources column scope

**Decision**: SD cards only. Favorites stay inside Create Job (unchanged).

**Rationale**: The Sources column is for *what's plugged in right now* — the live, dynamic surface. Favorites are user-saved paths used at job creation time; they live correctly inside the form. Mixing them in the Sources column would split the operator's attention and dilute the live-detection signal.

**Alternatives considered**:
- SD cards + source-favorites: more affordances visible permanently, but blurs the column's meaning.
- SD cards + all favorites grouped by type: too crowded for a 240px column.

## R3: Plan summary content (no ETA pre-flight)

**Decision**: Plan summary in Create Job shows file count, total bytes, free-space verdict, conflict count, long-path count. ETA is intentionally omitted; ETA appears only on the active hero card once the job is running.

**Rationale**: There is no reliable way to estimate ETA before the transfer starts. Drive read speed varies wildly between cards and reader hardware (USB 2 vs UHS-I vs UHS-II), and HandBrake compression speed depends on the preset and source bitrate. Showing a fake estimate ("est. 11 min") would actively erode trust when reality differs by 3×. Once the job is running, a rolling-average speed gives a meaningful real-time ETA.

**Alternatives considered**:
- Constant assumption (e.g., 100 MB/s): simple but inaccurate enough to mislead.
- Historical median by phase: requires a usable historical sample; cold-start undefined.
- Both pre-flight and runtime ETA, clearly labeled: doubles the failure surface for a small benefit.

## R4: Status dot states + green dot duration

**Decision**: Five states — grey (idle) / blue (active) / green (recent done) / red (attention) / orange (warning, e.g., Slack unconfigured or HandBrake missing). Green persists until the operator starts the next batch (creates a job or starts the queue) OR 5 minutes elapse, whichever comes first.

**Rationale**: Five states match the typical operator concerns. The 5-minute window is long enough that an operator returning from a coffee break sees the success signal, but short enough that the next morning's launch correctly shows idle. Operator-action-resets-state means the celebration is ended by *intent*, not by an arbitrary timer alone.

**Alternatives considered**:
- Persist green until app restart: drifts into stale state.
- 30-second flash: too brief; misses the "back from break" use case.
- Operator-action only: a forgotten window stays green forever.

## R5: Hero card behavior with no running job

**Decision**: First queued job is promoted to a "Next up" hero variant when nothing is running. Distinct visual from "Active" hero (no progress bar, ready-to-run framing). Pressing Start activates it in place — the same card transitions from Next-up to Active without re-layout.

**Rationale**: The queue panel always anchors on a focal element. Operators get a clear preview of "what pressing Start will do." The in-place transition eliminates layout reflow when the job activates.

**Alternatives considered**:
- All slim rows when nothing running: removes a focal point; "next up" becomes ambiguous in a long queue.
- Layered priority (last completed = celebration; otherwise next-up): more states to manage; harder to debug.

## R6: Inline detail vs separate route

**Decision**: Detail expands inline within the Active job card (and on click for Queued/Done variants). The existing `JobDetailScreen` route is kept registered for backwards compatibility but is no longer the primary path.

**Rationale**: A separate route forces a context switch (queue disappears, detail appears). Inline expansion keeps the queue visible — important for an operator monitoring multiple jobs. Tabs (Files / Audit / Errors) inside the inline detail provide enough information density without overflowing a single screen.

**Alternatives considered**:
- Keep route as primary: more space for detail but operators lose queue context.
- Detail in the right column: blocked by our choice to use the right column for the Activity log.

## R7: Detail tabs — always visible, with counts

**Decision**: Three tabs always visible: Files (N), Audit, Errors (N). Errors tab shows "(0)" when empty.

**Rationale**: Hiding the Errors tab when empty creates a "where did the tab go?" moment when failures appear. Always-visible tabs are predictable. The "(0)" badge converts the empty Errors tab into a positive trust signal — the operator can scan and confirm "no errors" without clicking.

**Alternatives considered**:
- Conditional Errors tab: hides ambiguity but disorients.
- Errors as a banner inside Files: adds a special case, not as scannable.

## R8: Erase placement — always visible, disabled with reason

**Decision**: Erase SD Card button lives in the active card's header action area. Always visible for transfer-type jobs whose source is a removable drive. Disabled with a clear textual reason ("Waiting for SHA-256 verification" / "Job not yet complete") until eligible. All existing safety gates (serial-number identity check, typed drive-path confirmation, size-only warning) remain.

**Rationale**: Operators perform erase many times a day. Knowing it exists *before* a job completes — and why it isn't yet enabled — sets expectations and avoids the post-success scroll-to-find-the-button friction. The disabled-with-reason pattern is more informative than hidden-until-eligible.

**Alternatives considered**:
- Hidden until eligible (current behavior): forces a scroll-and-discover pattern.
- Celebration-only (Opus's proposal): adds a state but hides the affordance during the job.

## R9: Settings — side-nav vs single column

**Decision**: Side-nav layout with five sections: Notifications / Operator / Behavior / Diagnostics / About.

**Rationale**: Settings will accumulate over time (testing flags, future preferences). Side-nav scales gracefully; single-column doesn't. The Diagnostics tab gives a clean home for content that has nowhere logical to live today (Prep Test Cards, log file path, instance lock state, HandBrake detection status). About separates app metadata from operational settings.

**Alternatives considered**:
- Keep single column: adequate today, becomes a dumping ground.
- Tabs across the top: less scalable than side-nav; fewer items visible.

## R10: Theme direction — Material 3 vs restrained Windows 11 palette

**Decision**: Stay on Material 3 with the existing seeded-blue color scheme. Add `Insets`, `AppTextStyles`, expanded `StatusColors` usage, JetBrains Mono asset, `VisualDensity.compact`. No rebrand.

**Rationale**: Material 3 gives a cohesive system out-of-the-box and is well-supported by Flutter widgets. The restrained Windows 11 palette proposed by Codex is more "production software"-feeling but requires more bespoke styling work. Tightening the existing Material 3 system (spacing scale, type scale, density) closes most of the "feels generic" gap without a rebrand.

**Alternatives considered**:
- Rebrand to Windows 11 native palette (Codex proposal): more visual credibility, more effort, less Flutter-idiomatic.
- Pure neutral grayscale: too austere for a workflow app.

## R11: Dark mode

**Decision**: Skip dark mode in this feature. Theme infrastructure should support it for future addition; specifically, `StatusColors` extension defines both light and dark variants even though only light is wired into `app_theme.dart`'s `darkTheme` getter.

**Rationale**: The team uses the app in daylight on a single workstation. There's no demand. Implementing it now doubles design and QA effort without value. The infrastructure decisions (theme extensions, density, spacing scale) don't preclude adding it later.

**Alternatives considered**:
- Implement now: doubles effort.
- Follow Windows system theme: would require dark mode anyway.

## R12: Density — compact vs default

**Decision**: `VisualDensity.compact` globally. Increases information density ~25% vertically.

**Rationale**: Material 3's default density is calibrated for touch and adds generous padding to controls. On a desktop app with a queue list as the central view, that padding wastes vertical space. Compact density is the desktop-appropriate choice and matches Windows 11's native control density.

**Alternatives considered**:
- Default density: more click area, less queue visible.
- Adaptive density: operator preference setting; over-engineered.

## R13: JetBrains Mono asset

**Decision**: Bundle JetBrains Mono Regular as a font asset; use it for paths and SHA-256 hashes throughout the UI. Optionally include the Bold variant for hash labels.

**Rationale**: System monospace fonts are inconsistent across machines (Consolas on Windows, Menlo on macOS, Liberation Mono on Linux). The hashes and paths are surfaces where consistency matters — operators visually compare hash strings, and an inconsistent font undermines that. JetBrains Mono is open-licensed (OFL), well-tuned for code and data display, and adds ~50-100KB to the binary.

**Alternatives considered**:
- System monospace fallback (current): inconsistent rendering.
- Other monospace fonts (Cascadia, Fira Code): equivalent quality; JetBrains Mono picked for cleaner zero-vs-O distinction at small sizes.

## R14: Keyboard shortcut focus scoping

**Decision**: All shortcuts live inside Flutter's `Shortcuts` widget at the shell level. `Shortcuts` already scopes properly — TextField widgets capture key events first, so typing `?` in an input inserts the character without firing the cheat-sheet shortcut.

**Rationale**: Native Flutter behavior. No extra infrastructure required.

**Alternatives considered**:
- `RawKeyboardListener` at the root: less idiomatic, requires manual focus handling.

## R15: Tray tooltip live updates

**Decision**: Push the status bar's summary text to `trayManager.setToolTip()` whenever it changes, throttled to 1Hz.

**Rationale**: The tray is the only visible affordance when the window is minimized — its tooltip should reflect the live state. Without throttling, frequent progress updates (per file) could spam the tray manager. 1Hz is fast enough for human perception and harmless for the OS.

**Alternatives considered**:
- No throttling: works but wasteful.
- Static "Idle" (current behavior): defeats the purpose of an unattended-monitoring tray.
