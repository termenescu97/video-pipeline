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
| `status='failed'` AND `errorMessage LIKE` any of: `'%could not compute hash%'`, `'%hash computation failed%'`, `'%computeFileHash exit=%'`, `'%computeFileHash returned malformed output%'`, `'%computeFileHash threw%'` | `unverified` | `verifyUnreliable` |
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

Reuses existing `markFileCompleted(fileId, {verified: bool})` pattern from `job_file_dao.dart:58` to stay consistent with the v7 dao API. The `verified` parameter becomes optional with default `false`; new code flips it explicitly via the verify-side mark methods below.

```dart
// After robocopy success (≈ line 484 of job_queue_service.dart).
// NOTE: verified=false explicitly — the legacy boolean stays false until
// markFileVerified flips it. Bytes-on-disk semantic, NOT verify done.
await _safeWrite(() => _jobFileDao.markFileCompleted(file.id, verified: false));
await _safeWrite(() => _jobDao.updateJobProgress(
  job.id,
  completedFiles: completedCount,
  completedBytes: completedBytes,
));

// After hash check (≈ line 488-512). New methods on JobFileDao:
//   markFileVerified(fileId, {sourceHash, destHash}) — sets verified=true, verifyStatus='verified'
//   markFileVerifyMismatch(fileId, {sourceHash, destHash}) — verifyStatus='mismatch', failureKind='verifyMismatch'
//   markFileUnverified(fileId) — verifyStatus='unverified', failureKind='verifyUnreliable'
await _safeWrite(() => _jobFileDao.markFileVerified(file.id, sourceHash: ..., destHash: ...));
await _safeWrite(() => _jobDao.incrementVerified(job.id));
```

### Rationale

Per Codex's H1 finding, gating both writes on a single `_safeWrite` recreates the original bug pattern. Splitting them makes the gating bug literally impossible to recreate: copy progress is persisted before verify even starts.

The `_safeWrite` wrapper (load-bearing convention from feature 016) drops writes silently when `_shutdownAbandoned` is set. Two calls mean Phase C cleanup is unaffected — neither call deadlocks, both are idempotent (writing the same state twice is safe).

### Risks

- Race: shutdown fires between the two `_safeWrite` calls. The file is `status=completed + verifyStatus=pending`. **Closed by R-A7** — `recoverStaleJobs` handles this row state.
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
import 'package:characters/characters.dart';

class LogService {
  static const int _maxStderrChars = 200;

  void error(String message, {
    int? jobId, int? fileIndex, int? totalFiles, LogPhase? phase,
    String? subprocessStderr,
  }) {
    var formatted = _format('ERROR', message, jobId, fileIndex, totalFiles, phase);
    if (subprocessStderr != null && subprocessStderr.isNotEmpty) {
      // First line. .split('\n') already strips '\n'; .trim() removes trailing
      // '\r' from Windows CRLF stderr (Codex round-2 R6).
      final firstLine = subprocessStderr.split('\n').first.trim();
      // Truncate by user-perceived characters (grapheme clusters), NOT raw
      // UTF-16 code units. .substring(0, 200) can split a UTF-16 surrogate
      // pair and produce mojibake when the stderr contains emoji or non-BMP
      // code points (Codex round-2 R6). The `characters` package is a
      // transitive Flutter dep — no new dependency.
      final truncated = firstLine.characters.length > _maxStderrChars
          ? '${firstLine.characters.take(_maxStderrChars).toString()}…'
          : firstLine;
      formatted += ': $truncated';
    }
    _writeLine(formatted);
  }
}
```

Callers pass raw stderr; LogService handles truncation. Golden tests cover: empty stderr (skip the colon), Windows CRLF (trim handles `\r`), single line > 200 chars (truncate with ellipsis), multi-line (take first), emoji or surrogate-pair stderr (no mojibake).

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

Two consumers today (verified against `lib/services/job_queue_service.dart:1048-1078` and `lib/ui/screens/create_job_screen.dart:1140-1173`). **Both have identical fields** — they're literally duplicate classes the operator's load-bearing convention has flagged for consolidation:

```dart
class _PlannedFile {
  String sourcePath;          // required
  String destinationPath;     // required (mutable in executor copy, final in UI copy)
  String fileName;            // required
  int fileSize;               // required
  bool wasOverwriteApproved;  // default false; stamped true in _applyResolution per 015
  
  _PlannedFile.copyWith({String? destinationPath, bool? wasOverwriteApproved}) → _PlannedFile;
}
```

Consolidation target: shared definition in `lib/database/planned_file.dart` (or `lib/services/planned_file.dart`) with all 5 fields. Make all final and the class immutable; replace executor's mutable `destinationPath`/`wasOverwriteApproved` assignment in `_applyResolution` with `copyWith`.

Codex M4: a single all-fields-set fixture is insufficient — production paths exercise different field combinations. The contract test must cover:

- **Full population**: all 5 fields set; both consumers (`createBatchTransferJobs` flow + `_applyResolution` flow) process without `null` derefs.
- **Default `wasOverwriteApproved=false`**: covers the common case where preflight detects no conflict on this file.
- **`wasOverwriteApproved=true`**: covers the `_applyResolution` flow where operator chose Overwrite at preflight; verify the executor's delete-pre-robocopy logic respects the flag.
- **Rename via `copyWith(destinationPath: …)`**: the existing `_suffixed` helper produces a renamed file by calling `copyWith`. Contract: `wasOverwriteApproved` and `fileName` are preserved across rename. (`fileName` doesn't change on rename; `destinationPath` does.)
- **Skip resolution**: a planned file is omitted from the resulting `List<_PlannedFile>` entirely. Contract: downstream consumers (DB insert, robocopy invocation) handle the missing rows correctly — they're filtered upstream, never reach the executor.

The contract test runs in CI and fails fast on any divergence between the consolidated shape and either consumer's expectations. **No `existingDestSize` field exists** — earlier draft fabricated this; the conflict UI tracks dest size separately via `ConflictEntry` (`job_queue_service.dart:1040-1045`).

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

**Compression-completed notification expansion** (Codex round-2 H3 + round-3 architectural follow-up): `notifyCompressionCompleted` (`slack_service.dart:106-119`) currently has no verify counts — it just shows files done + duration. For chained compression (auto-chained from a `transferAndCompress` parent), the operator's final Slack ping must surface the parent's transfer-phase verify state, otherwise a clean-looking compression-complete signal could mask a non-clean transfer (Principle V).

**Architectural note**: `_processJob` (`job_queue_service.dart:235-244`) handles `JobType.transferAndCompress` by running `_processTransfer` first, then on success calling `_createChainedCompressionJob` (`job_queue_service.dart:984-1015`) which inserts a NEW `JobType.compression` job. The chained job is a separate Drift row with its own JobFile rows seeded from `FileStatus.pending`. The transfer-phase `verifyStatus` lives on the PARENT's JobFile rows, not the chained compression's. A direct in-memory link is unavailable when `_processCompression` notifies — the chained compression job has no inherent reference to its parent.

**Solution: `Job.parentJobId` column** (added to schema v8, see data-model.md). `_createChainedCompressionJob` sets `parentJobId = transferJob.id` at chain time. At notification finalize time, `_processCompression` reads its own `parentJobId`; if non-null, it queries the parent job's verify counts via DAO and passes them through the new Slack signature.

Expansion:

```dart
Future<void> notifyCompressionCompleted({
  required Job job,
  required int completedFiles,
  required int totalFiles,
  // NULLABLE: when the chained-compression job's parent has the verify
  // counts. Null for directly-created compression jobs (no transfer phase).
  Job? parentTransferJob,                // NEW — derived via parentJobId
  int? parentVerifiedFiles,              // NEW
  int? parentUnverifiedFiles,            // NEW
  int? parentMismatchedFiles,            // NEW
}) async {
  final hasParentSnapshot = parentTransferJob != null;
  final verifyLine = hasParentSnapshot
      ? ((parentMismatchedFiles ?? 0) > 0
          ? '⚠ Transfer verification: $parentMismatchedFiles file(s) FAILED'
          : (parentUnverifiedFiles ?? 0) > 0
              ? '⚠ Transfer verification: $parentUnverifiedFiles file(s) UNVERIFIED'
              : 'Transfer verification: Passed')
      : null;  // standalone compression job — no transfer to report
  // ... format + send ...
}
```

Caller (in `_processCompression` finalize, `job_queue_service.dart:725-735`):

```dart
Job? parentJob;
int verified = 0, unverified = 0, mismatched = 0;
if (job.parentJobId != null) {
  parentJob = await _jobDao.getJob(job.parentJobId!);
  if (parentJob != null) {
    final files = await _jobFileDao.getFilesForJob(parentJob.id);
    verified = files.where((f) =>
        f.verifyStatus == VerifyStatus.verified).length;
    unverified = files.where((f) =>
        f.verifyStatus == VerifyStatus.unverified).length;
    mismatched = files.where((f) =>
        f.verifyStatus == VerifyStatus.mismatch).length;
  }
}
await _slackService.notifyCompressionCompleted(
  job: job,
  completedFiles: completedCount,
  totalFiles: files.length,
  parentTransferJob: parentJob,
  parentVerifiedFiles: parentJob != null ? verified : null,
  parentUnverifiedFiles: parentJob != null ? unverified : null,
  parentMismatchedFiles: parentJob != null ? mismatched : null,
);
```

Graceful fallback: if `parentJobId` is set but the parent has been deleted before notification fires (rare — operator interaction), all four parent params are passed as null and the Slack body omits the verify line. The compression Slack ping degrades to compression-only metrics — same as a directly-created compression job. No crash.

This satisfies FR-016 + FR-019 across both phase boundaries and closes the round-3 architectural finding.
