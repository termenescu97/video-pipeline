# Research: SHA-256 File Verification

## Decision 1: Hash computation tool

**Decision**: Use PowerShell `Get-FileHash` to compute SHA-256 hashes on Windows. On non-Windows (development), use Dart's `crypto` package as fallback.

**Rationale**: `Get-FileHash` is built into Windows, uses .NET's optimized SHA256 implementation, and is 10-30% faster than `certutil -hashfile` for large files. It outputs a clean hash string that's easy to parse. Using it via `Process.run` keeps the pattern consistent with how we use robocopy and HandBrakeCLI (Constitution IV — delegate to system tools).

**Alternatives considered**:
- `certutil -hashfile` — slower, more overhead, clunky output format.
- Dart `crypto` package — would work but reads the file in Dart's event loop, potentially blocking UI responsiveness on 50GB files. Better as a development fallback than production path.

## Decision 2: Hash computation order — sequential, not parallel

**Decision**: Hash source first, then hash destination. Never hash both simultaneously from the same USB device.

**Rationale**: Research showed that two concurrent sequential reads from the same USB 3.0 device cause controller contention, dropping each stream to 40-60% of solo throughput. Sequential hashing (source → destination) takes the same total time but doesn't degrade either operation.

**Alternatives considered**:
- Parallel hashing — slower in practice due to USB contention.
- Hash during transfer (single-pass) — requires replacing robocopy with custom copy engine, losing `/Z` resumable transfers.

## Decision 3: Verification mode storage

**Decision**: Add `verificationMode` text column to Jobs table (enum: `size`, `sha256`, default `size`). Store as text enum via Drift's `textEnum`. Schema v4→v5 migration.

**Rationale**: Matches existing enum patterns (JobType, JobStatus). Per-job storage means each job in the queue can have a different mode — critical for mixed workflows (routine dailies + critical footage in the same batch).

## Decision 4: Hash storage on JobFiles

**Decision**: Add `sourceHash` and `destinationHash` nullable text columns to JobFiles table. Null for size-verified files, populated for SHA-256 verified files.

**Rationale**: Storing hashes per-file enables audit trail and troubleshooting. Nullable means no overhead for size-verified files. The 64-character hex string is lightweight to store.

## Decision 5: Batch copy verification mode

**Decision**: Add a SegmentedButton (same as job creation) to the batch copy dialog/flow. Selected mode applies to all jobs in the batch.

**Rationale**: Per clarification, the operator should be able to SHA-256 verify a full batch without creating individual jobs. The toggle appears before the folder picker in the batch flow.
