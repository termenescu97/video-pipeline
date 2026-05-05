# Data Model: Video Pipeline Automation

## Entities

### Job

The central unit of work. Each job is independently configurable and trackable.

| Field | Type | Description |
|-------|------|-------------|
| id | Integer (PK, auto-increment) | Unique job identifier |
| type | Enum: transfer, compression, transfer_and_compress | What this job does |
| status | Enum: queued, in_progress, completed, failed, paused | Current state |
| source_path | String | Source drive/folder path |
| destination_path | String | Where transferred files go |
| compression_output_path | String (nullable) | Where compressed files go (if compression enabled) |
| preset_name | String (nullable) | HandBrake preset name (if compression enabled) |
| auto_chain | Boolean | If true, compression starts automatically after transfer |
| created_at | DateTime | When the job was created |
| started_at | DateTime (nullable) | When processing began |
| completed_at | DateTime (nullable) | When processing finished |
| error_message | String (nullable) | Last error encountered |
| total_files | Integer | Total files to process |
| completed_files | Integer | Files successfully processed |
| total_bytes | Integer | Total bytes to process |
| completed_bytes | Integer | Bytes successfully processed |

### JobFile

Tracks individual file status within a job.

| Field | Type | Description |
|-------|------|-------------|
| id | Integer (PK, auto-increment) | Unique file record identifier |
| job_id | Integer (FK → Job) | Parent job |
| source_file_path | String | Full path to source file |
| destination_file_path | String | Full path to destination file |
| file_name | String | Original file name |
| file_size | Integer | File size in bytes |
| status | Enum: pending, in_progress, completed, failed, skipped | Current state |
| verified | Boolean | Whether the file passed verification after copy |
| error_message | String (nullable) | Error detail if failed |
| started_at | DateTime (nullable) | When this file started processing |
| completed_at | DateTime (nullable) | When this file finished |

### FavoritePath

User-saved folder paths for quick reuse.

| Field | Type | Description |
|-------|------|-------------|
| id | Integer (PK, auto-increment) | Unique identifier |
| path | String | The saved folder path |
| label | String | User-friendly name for this path |
| type | Enum: source, destination, output | What this path is typically used for |
| last_used_at | DateTime | Last time this favorite was selected |
| created_at | DateTime | When saved |

### AppSettings

Global app configuration (singleton).

| Field | Type | Description |
|-------|------|-------------|
| slack_webhook_url | String | Slack incoming webhook URL |
| check_updates_on_launch | Boolean | Whether to check GitHub for updates |
| last_update_check | DateTime (nullable) | Last time update was checked |
| current_version | String | Running app version |

## Relationships

```
Job (1) ──── (many) JobFile
FavoritePath (standalone, referenced by UI)
AppSettings (singleton)
```

## State Transitions

### Job Status

```
queued → in_progress → completed
                    → failed
                    → paused → in_progress (resume)
```

### JobFile Status

```
pending → in_progress → completed
                     → failed
                     → skipped (user chose to skip)
```

## Notes

- Job queue is ordered by `created_at` — first created, first processed
- When a job with `auto_chain = true` completes transfer, a new compression job is automatically created and queued
- `completed_bytes` is updated during transfer by polling destination file size (for intra-file progress display)
- Verification happens immediately after each file copy (before marking as `completed`)
