# Contract: Slack Notification Messages

The app sends notifications to a Slack incoming webhook at defined phase transitions.

## Message Formats

### Transfer Started
```json
{
  "text": "📂 *Transfer Started*\nJob: {job_id}\nSource: {source_path}\nDestination: {destination_path}\nFiles: {total_files} ({total_size_gb} GB)"
}
```

### Transfer Completed
```json
{
  "text": "✅ *Transfer Complete*\nJob: {job_id}\nFiles: {completed_files}/{total_files}\nSize: {total_size_gb} GB\nDuration: {duration_minutes} min\nVerification: Passed"
}
```

### Transfer Failed
```json
{
  "text": "❌ *Transfer FAILED*\nJob: {job_id}\nFile: {failed_file_name}\nError: {error_message}\nCompleted: {completed_files}/{total_files} before failure"
}
```

### Compression Started
```json
{
  "text": "🎬 *Compression Started*\nJob: {job_id}\nPreset: {preset_name}\nFiles: {total_files}\nOutput: {output_path}"
}
```

### Compression Completed
```json
{
  "text": "✅ *Compression Complete*\nJob: {job_id}\nFiles: {completed_files}/{total_files}\nSize: {original_size_gb} GB → {compressed_size_gb} GB ({ratio}% reduction)\nDuration: {duration_minutes} min"
}
```

### Compression Failed
```json
{
  "text": "❌ *Compression FAILED*\nJob: {job_id}\nFile: {failed_file_name}\nError: {error_message}\nCompleted: {completed_files}/{total_files} before failure"
}
```

## Delivery Rules

- Notifications are best-effort (pipeline continues if Slack is unreachable)
- Timeout: 10 seconds per request
- No retries on failure (log locally and continue)
- If webhook URL is not configured, skip silently
