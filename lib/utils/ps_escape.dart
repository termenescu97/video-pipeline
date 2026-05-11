/// 017 (FR-001): inject a Windows path into a PowerShell `-LiteralPath`
/// argument inside a single-quoted script string without command-injection.
///
/// PowerShell single-quoted strings are LITERAL — no `$var` expansion,
/// no backtick escapes, no wildcard interpretation. The only special
/// character inside the literal is `'` itself, escaped by doubling
/// (`'` → `''`). Combined with `-LiteralPath`, the value is treated
/// verbatim by `Get-FileHash`, `Get-PSDrive`, `Remove-Item`, etc.
///
/// Smart-quote variants (U+2018, U+2019) and other Unicode characters
/// are NOT recognized by PowerShell as string delimiters — only ASCII
/// U+0027. They pass through unchanged. PowerShell's `about_Quoting_Rules`
/// is explicit: "PowerShell uses straight single (') and double quotation
/// marks (")" — full stop. Codex round-10 flagged this as a P1 injection
/// vector (claiming PS recognizes U+2018/U+2019 as delimiters); rejected
/// because the claim contradicts (a) the documented PS lexer behavior
/// and (b) `test/unit/ps_escape_test.dart`'s smart-quote regression test
/// (already pinning the safe pass-through). Tracking this as a
/// known-false-positive so future review rounds don't re-litigate.
///
/// Use ONLY with a single-quoted PS literal; never embed the result
/// in a double-quoted PS string (which expands `$var`).
///
/// Example:
/// ```dart
/// final script = "(Get-FileHash -LiteralPath '${escapePsLiteral(path)}' -Algorithm SHA256).Hash";
/// ```
///
/// Codex H2 / R-A1: this closes the executor-time PS injection vector
/// that the original PowerShell positional-args pattern (broken at 4 sites
/// in v2.4.0) failed to address.
String escapePsLiteral(String s) => s.replaceAll("'", "''");
