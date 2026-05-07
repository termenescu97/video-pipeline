# Data Model Changes: Data Safety & Reliability Hardening

**Feature**: 013-data-safety-hardening  
**Date**: 2026-05-07  
**Schema Version**: 5 → 5 (no schema migration needed)

## Summary

This feature does NOT require a database schema migration. All changes are behavioral (query logic, transaction wrapping, startup recovery). The existing tables and columns are sufficient.

## Existing Entities (unchanged schema)

### Jobs

| Column | Type | Notes for this feature |
|--------|------|----------------------|
| status | JobStatus enum | Recovery: inProgress → paused on startup |
| sortOrder | int | Fix: getNextQueuedJob() must order by this first |
| destinationPath | text | Batch copy: now includes per-card subfolder |

**State transitions affected**:
- `inProgress` → `paused` (new: startup recovery)
- Existing: `queued` → `inProgress` → `completed`/`failed`

### JobFiles

| Column | Type | Notes for this feature |
|--------|------|----------------------|
| status | FileStatus enum | Recovery: inProgress → pending on startup |
| destinationFilePath | text | Batch copy: includes per-card subfolder in path |
| verified | bool | Erase gate: size-only verified triggers warning |
| sourceHash / destinationHash | text? | Cancellable hash: may be null if hash was interrupted |

**State transitions affected**:
- `inProgress` → `pending` (new: startup recovery, hash cancellation)

## New DAO Methods

### JobDao

- `recoverStaleJobs()` — transaction: move all inProgress jobs to paused, their inProgress files to pending
- `createJobWithFiles(JobsCompanion job, List<JobFilesCompanion> files, int totalFiles, int totalBytes)` — transaction: insert job + files + totals atomically
- `getNextQueuedJob()` — modified: order by sortOrder ASC, then createdAt ASC
- `getMaxSortOrder()` — new: returns highest current sortOrder for assigning new jobs

### No New Tables or Columns

The existing schema v5 supports all changes. No `onUpgrade` migration step needed.

## Path Construction Changes

### Current (broken for batch)
```
destination/DCIM/100CANON/C0001.MP4  ← same for all cards
```

### New (per-card subfolder)
```
destination/EOS_DIGITAL_E/DCIM/100CANON/C0001.MP4
destination/EOS_DIGITAL_F/DCIM/100CANON/C0001.MP4
```

### Chained compression (fixed)
```
output/EOS_DIGITAL_E/DCIM/100CANON/C0001.MP4  ← preserves relative path
output/EOS_DIGITAL_F/DCIM/100CANON/C0001.MP4
```
