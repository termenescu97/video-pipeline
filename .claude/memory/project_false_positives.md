---
name: Known false positives from reviews
description: Issues that were investigated and confirmed as non-bugs — don't re-investigate
type: project
originSessionId: fb56d0b5-8f89-4add-8cb7-7fab7cca410f
---
### QA-5: DropdownButtonFormField.initialValue "compile error"
**Verdict:** False positive. `initialValue` is the correct parameter in Flutter 3.41.9. The `value` parameter is deprecated (deprecated after v3.33.0-1.0.pre). The QA review was based on older Flutter docs.

### QA-7: startProcessing() race condition
**Verdict:** False positive in Dart's single-threaded event loop. Lines 46-47 (`if (_isProcessing) return; _isProcessing = true;`) execute synchronously — no other code can interleave before the first `await`. The guard is correct for Dart's concurrency model.

### Codex 016: "Process.kill is best-effort and may leak children on Windows"
**Verdict:** False positive — investigated and dismissed during 016 review. Dart's `Process.kill(ProcessSignal.sigkill)` on Windows maps to `TerminateProcess`, which terminates the process tree synchronously. robocopy and HandBrakeCLI do not spawn long-lived children of their own — neither has a worker pool — so there is nothing to leak. The "may leak children" framing is generic Unix advice that doesn't apply to this codebase's specific subprocesses.

### Codex 016: "DB writes after database.close() will throw and crash"
**Verdict:** False positive after fix. With `_safeWrite` wrapping every DAO write inside the processing loop and `_shutdownAbandoned` flipping in Phase B's TimeoutException handler, any DAO write that races Phase C's `database.close()` is silently dropped instead of crashing. The Codex finding was correct in spirit (the original 016 implementation only guarded ~5 sites) — fully resolved by the v2 implementation that wraps all ~25 sites.

### Codex 016: "shell_screen onWindowClose may double-fire"
**Verdict:** False positive. The `_shuttingDown` early-return guard at the top of `_gracefulShutdown` makes it idempotent. `WindowListener.onWindowClose` and `TrayManager.onTrayMenuItemClick("quit")` both go through the same guarded path; the flag is set synchronously before any `await`, so a second invocation no-ops cleanly.

### Codex 017B round-10: "PowerShell smart quotes terminate single-quoted strings"
**Verdict:** False positive. PowerShell's `about_Quoting_Rules` documents that ONLY ASCII U+0027 (`'`) is a single-quote delimiter — never U+2018/U+2019. Smart quotes pass through as regular Unicode characters inside the literal. `test/unit/ps_escape_test.dart` has a regression test pinning this behavior. The Codex finding contradicted both the PS lexer spec and the existing test fixture; a comment in `lib/utils/ps_escape.dart` documents the rejection so future review rounds don't re-litigate.

**How to apply:** If a future review flags any of these again, reference this memory and skip. Don't waste time re-investigating.
