# Research: Executor Correctness (v2.5.0)

**Feature**: 017-executor-correctness | **Phase**: 0 (Research)
**Date**: 2026-05-08

## R-A1 — PowerShell argument-passing fix

### Decision: Single-quote escape with `-LiteralPath`

```dart
String _escapePsLiteral(String s) => s.replaceAll("'", "''");
final script = "(Get-FileHash -LiteralPath '${_escapePsLiteral(path)}' -Algorithm SHA256).Hash";
final exitCode = await runner.run(
  executable: 'powershell',
  arguments: ['-NoProfile', '-Command', script],
);
```

### Rationale

PowerShell's `-Command` parameter consumes only the next single argv element as the script. Additional argv elements after that are NOT automatically populated into `$args` — `$args` is only filled when the script is a script block invoked with `&` or run via `-File`. The path-as-fourth-argv pattern at four call sites is silently dropped; PowerShell's parser sees the path concatenated into the script string for diagnostic echo only.

Single-quote escape is safe because:
- PS single-quoted strings are literal — no `$var`, no backtick, no escape sequences.
- The only special character is `'`, escaped by doubling (`'` → `''`).
- `-LiteralPath` treats the value verbatim — no wildcard expansion, no variable expansion, no `[`, `]`, `*`, `?` interpretation.
- Smart-quote variants (U+2018, U+2019) are NOT recognized by PS as string delimiters; only ASCII U+0027.

### Alternatives considered

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| Stdin-piped `param()` script | Cleaner separation of script from data | More complex, harder to debug, needs stdin orchestration | Rejected |
| `-EncodedCommand` (base64 UTF-16LE) | No string escaping issues | Hard to read in logs, opaque debug story | Rejected |
| Temp `.ps1` file with `-File <path> -Path <arg>` | Proper named-parameter passing | Adds asset-management overhead, write-permission needs | Rejected for 4 call sites |
| Single-quote escape inline | Simple, audited, fits 5-line helper | Relies on `-LiteralPath` semantic guarantees | **Chosen** |

### Verification path

- Unit test mocks `Process.start` and asserts `arguments.length == 3` for inline-script invocations.
- Permanent CI guard: `! grep -rn '\$args\[' lib/` in pre-merge check.
- Path fixtures exercise: `'` (apostrophe), `[`, `]`, `*`, `?`, `` ` ``, `$`, U+2018, U+2019, ASCII > 260 chars.
- Operator's Windows test corpus (27 files, 161 GB, paths with spaces and special characters) is the acceptance test.

## R-A3 — Drift migration v7 → v8

### Decision: Single-transaction column adds + backfill UPDATEs

Existing pattern from migrations v3 → v4 (operator name), v5 → v6 (behavior preferences), v6 → v7 (`wasOverwriteApproved`) uses Drift's `MigrationStrategy.onUpgrade` with `m.addColumn`. For v8, all four column adds (`JobFile.verifyStatus`, `JobFile.failureKind`, `Job.unverifiedFiles`, `AppSettings.sourcesPanelCollapsed`) plus the backfill UPDATEs are wrapped in `customStatement` calls inside a single Drift `transaction { ... }` block.

### Rationale

A mid-migration crash (power loss during the column adds or backfill) must NOT leave the schema in an inconsistent state. SQLite's `ALTER TABLE ADD COLUMN` is atomic individually, but the four-step migration with backfill is not — wrapping in a transaction ensures either all changes apply or none do.

Backfill rules per Codex M5 + H2 (corrected against actual v7 schema in `lib/database/tables.dart`):

The real v7 schema uses:
- `Jobs.verificationMode` as `textEnum<VerificationMode>` storing `'size'` or `'sha256'` (NOT a `requireHashVerification` boolean — earlier draft was wrong).
- `JobFiles.status` as `textEnum<FileStatus>` storing literal strings (`'completed'`, `'failed'`, etc.) — NOT integer ordinals.
- `JobFiles.verified` (pre-existing v5) — boolean set to `true` when verification (size match OR SHA-256 match per the configured mode) succeeded.

Codex H2: `'%SHA-256%'` alone is too broad — it matches BOTH real mismatches and hash-subsystem failures, causing wrong classification. Use narrow patterns based on the actual error strings emitted by `job_queue_service.dart`:

- Real mismatch (line 503): `'SHA-256 hash mismatch'`
- Subsystem failure (line 490): `'SHA-256 verification failed: could not compute hash'`
- Subsystem failure (transfer_service.dart line 117): `'computeFileHash exit=...'`

| Existing row state | Backfilled `verifyStatus` | Backfilled `failureKind` |
|--------------------|---------------------------|--------------------------|
| `status='completed'` AND `verified=1` AND parent `verification_mode='sha256'` | `verified` | `none` |
| `status='completed'` AND `verified=1` AND parent `verification_mode='size'` | `unverified` (size-only doesn't establish cryptographic trust) | `none` |
| `status='completed'` AND `verified=0` (rare — recovery edge case) | `pending` (will re-verify) | `none` |
| `status='failed'` AND `errorMessage LIKE '%SHA-256 hash mismatch%' OR LIKE '%SHA-256 MISMATCH%' OR LIKE '%hash mismatch%'` | `mismatch` | `verifyMismatch` |
| `status='failed'` AND `errorMessage LIKE '%could not compute hash%' OR LIKE '%hash computation failed%' OR LIKE '%computeFileHash exit=%'` | `unverified` | `verifyUnreliable` |
| `status='failed'` (other) | `pending` (default) | `copyError` |
| `status='pending'` / `'inProgress'` / `'skipped'` | `pending` (default) | `none` (default) |

### Alternatives considered

| Approach | Verdict |
|----------|---------|
| Skip backfill, leave new columns at default and let future runs populate | Rejected — operator's existing v2.4.0 history would show all completed jobs as "unverified" until next interaction, eroding trust. |
| Add a new `verification_history` table | Rejected — adds complexity without solving the immediate problem; per-row state is fine. |
| Synthesize `failureKind` only from `errorMessage` parsing without backup default | Rejected — fragile to log message phrasing changes across versions. |

### Risks

- Backfill UPDATEs on a large historical DB (thousands of jobs) could be slow. Mitigation: operator's DB is small (tens to low hundreds of jobs), so single-transaction is fine. If this changes in v3.0, batch the UPDATEs.
- `errorMessage` parsing is brittle. Mitigation: pattern is conservative ("hash mismatch" or "SHA-256" exact substring); ambiguous cases default to `copyError`.

## R-A4 — Two-step writes inside `_safeWrite`

### Decision: Two separate `_safeWrite` calls — copy first, verify second

```dart
// After robocopy success (≈ line 484 of job_queue_service.dart)
await _safeWrite(() => _jobFileDao.markFileCopied(file.id));
await _safeWrite(() => _jobDao.updateJobProgress(
  job.id,
  completedFiles: completedCount,
  completedBytes: completedBytes,
));

// After hash check (≈ line 488-512)
await _safeWrite(() => _jobFileDao.markFileVerified(file.id));     // or markFileVerifyMismatch / markFileUnverified
await _safeWrite(() => _jobDao.incrementVerified(job.id));         // or incrementFailed / incrementUnverified
```

### Rationale

Per Codex's H1 finding, gating both writes on a single `_safeWrite` recreates the original bug pattern. Splitting them makes the gating bug literally impossible to recreate: copy progress is persisted before verify even starts.

The `_safeWrite` wrapper (load-bearing convention from feature 016) drops writes silently when `_shutdownAbandoned` is set. Two calls mean Phase C cleanup is unaffected — neither call deadlocks, both are idempotent (writing the same state twice is safe).

### Risks

- Race: shutdown fires between the two `_safeWrite` calls. The file is `status=copied + verifyStatus=pending`. **Closed by R-A7** — `recoverStaleJobs` handles this row state.
- The new mark methods on `JobFileDao` need symmetric extension on `JobDao` (counters). Tests cover both paths.

## R-A6 — Logging API backward-compat + truncation

### Decision: Add named params; keep one-arg signature working; enforce truncation INSIDE LogService.error

```dart
// Old call site (preserved):
logService.info('App started');

// New call site with full context:
logService.info(
  'Hash verification complete',
  jobId: 1,
  fileIndex: 27,
  totalFiles: 27,
  phase: LogPhase.verify,
);

// New call site with partial context (M3):
logService.info('Job created', jobId: 5);
// → [2026-05-08 14:23:45] [INFO] [job=5] Job created

logService.info('Phase boundary', phase: LogPhase.transfer);
// → [2026-05-08 14:23:45] [INFO] [phase=transfer] Phase boundary
```

### Format spec for every (jobId × fileIndex × totalFiles × phase) combination

Codex M3: define independently per non-null field, in stable order.

| jobId | fileIndex / totalFiles | phase | Bracket content |
|-------|-----------------------|-------|------------------|
| ✗ | ✗ | ✗ | (no bracket) |
| ✓ | ✗ | ✗ | `[job=N]` |
| ✗ | ✗ | ✓ | `[phase=X]` |
| ✓ | ✗ | ✓ | `[job=N phase=X]` |
| ✓ | ✓ (both set) | ✗ | `[job=N file=K/total]` |
| ✓ | ✓ (both set) | ✓ | `[job=N file=K/total phase=X]` |
| ✗ | ✓ (both set) | ✓ | `[file=K/total phase=X]` |
| `fileIndex` set without `totalFiles` (or vice versa) | — | — | Treated as missing both; `[job=N phase=X]` only |

Field order inside the bracket: `job`, `file`, `phase`. Always space-separated. No trailing space.

### Truncation enforced INSIDE LogService.error (Codex M2)

Per Codex M2, "every caller manually truncates stderr" is fragile. A mechanical migration can miss one path. Solution: enforce in `LogService.error` itself.

```dart
class LogService {
  static const int _maxStderrChars = 200;

  void error(String message, {
    int? jobId, int? fileIndex, int? totalFiles, LogPhase? phase,
    String? subprocessStderr,
  }) {
    var formatted = _format('ERROR', message, jobId, fileIndex, totalFiles, phase);
    if (subprocessStderr != null && subprocessStderr.isNotEmpty) {
      // Single-line, max 200 chars.
      final firstLine = subprocessStderr.split('\n').first.trim();
      final truncated = firstLine.length > _maxStderrChars
          ? '${firstLine.substring(0, _maxStderrChars)}…'
          : firstLine;
      formatted += ': $truncated';
    }
    _writeLine(formatted);
  }
}
```

Callers pass raw stderr; LogService handles truncation. Golden tests cover multi-line input.

### Rationale

Per Codex L8 — golden tests on the formatted output prevent silent regressions. Adding named params is non-breaking (Dart resolves by argument shape). Existing call sites can migrate incrementally; uninteresting call sites (e.g. "App started") stay at the one-arg form forever.

### Verification path

- Golden test per `(level × phase)` combination — 4 levels × 9 phases = 36 fixture lines.
- Golden test per partial-context combination (8 cases above).
- Truncation goldens: multi-line stderr, > 200-char single line, empty stderr.
- Log file parser used by future activity-feed work in feature 018 must accept BOTH old and new format lines.

## R-A8 — NTFS case-only collision normalization

### Decision: Manual `toLowerCase()` on the Windows-rooted destination path

```dart
String _windowsKey(String destPath) {
  // Lowercase the entire Windows path. Drive letter, dir separator, and
  // file name all collapse case under NTFS's case-insensitive matching.
  return destPath.toLowerCase();
}
```

Build a `Set<String>` of normalized keys at preflight; collision = duplicate insert.

### Rationale

`path.canonicalize` resolves symlinks and `..` components, which the executor doesn't want to do (preserves operator's intended path). `toLowerCase()` matches NTFS's case-insensitive comparison rule for ASCII paths.

For non-ASCII paths (extremely rare in this domain — Windows NTFS uses UTF-16 with case-folding tables that are mostly Unicode-stable), `toLowerCase()` covers the operator's actual file population (Latin-script filenames) and won't introduce false positives in their corpus. If multilingual filenames become common in v3.0, swap for ICU-based folding.

### Alternatives considered

| Approach | Verdict |
|----------|---------|
| Skip detection; let robocopy handle | Rejected — robocopy with `/XN /XC /XO` would skip the second file silently after the first claimed the destination, losing data. |
| Filesystem-level collision check via `File.existsSync` for each planned path before copying the next | Rejected — race condition; doesn't catch two-source-files-one-destination at preflight. |
| Use `path.canonicalize` | Rejected — resolves symlinks (operator's NAS path may include junctions). |
| Manual `toLowerCase()` over the destination string | **Chosen** |

### Verification path

- Unit test fixture: `[DCIM/IMG_001.MOV, dcim/img_001.mov]` — assert collision detected and `_suffixed` produces distinct keys.
- macOS HFS+/APFS test environment: same code runs, but case-only collisions on macOS source filesystems are the natural input — test that the key-set detects them correctly even when the source filesystem already disambiguates.

## Cross-cutting research notes

### Path-shape validation for PowerShell helpers (R-A1 supplement)

Validate before invoking PS:

| Path shape | Action |
|------------|--------|
| Empty string | Throw `ArgumentError` with "path must not be empty" |
| Starts with `\\` (UNC) | For `getDiskFreeSpace`: log a `WARNING` with `phase=preflight` and return `null` (no UNC support in v2.5; v3.0 NAS feature adds Win32 `GetDiskFreeSpaceEx` via FFI). For `computeFileHash`: continue — PS handles UNC for `Get-FileHash` natively. |
| Drive-letter without colon (e.g. `E`) | Caller bug — throw `ArgumentError`; tighten regex to `^[A-Za-z]:` (with colon) for `getDiskFreeSpace`. |
| Length > 260 chars | Continue but log a `WARNING` once at preflight. PS 5.1 may fail; test on operator's machine. |

### `_PlannedFile` consolidation contract (R-A9, Codex M7 + M4 refinement)

Two consumers today:
- `JobQueueService.createBatchTransferJobs` and `_processTransfer` (executor side)
- `CreateJobScreen._applyResolution` and conflict UI (creation side)

Consolidation target: shared definition in `lib/database/planned_file.dart` with the union of fields used by both consumers.

Codex M4: a single all-fields-set fixture is insufficient — production paths often pass sparse shapes. The contract test must cover:

- **Full population**: every field set; both consumers process without `null` derefs.
- **Subset shapes per consumer**:
  - Batch creation: `sourcePath`, `destPath`, `fileSize` set; `wasOverwriteApproved=false`, `existingDestSize=null`.
  - Single-job creation with rename: `sourcePath`, `destPath` (renamed), `fileSize`, `wasOverwriteApproved=false`.
  - Single-job creation with overwrite: `wasOverwriteApproved=true`, `existingDestSize` set.
  - Skip resolution: file omitted from the planned set entirely (assert downstream handles missing rows correctly).
- **`copyWith` preservation**: `wasOverwriteApproved` and `existingDestSize` survive `_PlannedFile.copyWith(destPath: ...)` calls used during rename suffix generation.

The contract test runs in CI and fails fast on any divergence between the consolidated shape and either consumer's expectations.

### Slack notification expansion for unverified files (Codex H3 → new FR)

Constitution Principle V mandates "failure notifications MUST include actionable detail". The graceful-degradation model in this feature introduces a new failure-shaped state ("copied, unverified") that today's `notifyTransferCompleted(allVerified: bool)` cannot express. Operator who walks away gets a green checkmark + "Passed" for jobs with unverified files — silent failure violation.

Decision: expand `SlackService.notifyTransferCompleted` to take separate counts:

```dart
Future<void> notifyTransferCompleted({
  required Job job,
  required int completedFiles,
  required int verifiedFiles,
  required int unverifiedFiles,
  required int mismatchedFiles,
}) async {
  final mode = job.verificationMode == VerificationMode.sha256 ? 'SHA-256' : 'Size';
  final verdict = mismatchedFiles > 0
      ? '⚠ $mismatchedFiles file(s) FAILED verification'
      : unverifiedFiles > 0
          ? '⚠ $unverifiedFiles file(s) copied but UNVERIFIED'
          : 'Verification: $mode — Passed';
  await _send(
    '✅ *Transfer Complete*\n'
    'Job: ${job.id}${_operatorLine(job)}\n'
    'Files: $completedFiles/${job.totalFiles}\n'
    'Verified: $verifiedFiles · Unverified: $unverifiedFiles · Mismatch: $mismatchedFiles\n'
    'Size: ${formatBytes(job.totalBytes)}\n'
    '$verdict',
  );
}
```

Callers (`job_queue_service.dart::_processTransfer` and `_processCompression`) pass the per-job aggregate counters from the schema v8 fields. Mismatch and unverified counts > 0 trigger the warning prefix.
