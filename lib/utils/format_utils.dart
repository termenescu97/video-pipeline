/// Format bytes into human-readable string (e.g., "45.2 GB", "800 MB").
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 0) return 'N/A';
  if (bytes == 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  int i = 0;
  double size = bytes.toDouble();
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(decimals)} ${units[i]}';
}

/// Format duration into human-readable string (e.g., "1h 23m", "45m 12s").
String formatDuration(Duration d) {
  if (d.inHours > 0) {
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }
  return '${d.inSeconds}s';
}

/// Format a DateTime as a relative timestamp (e.g., "5 min ago", "Yesterday").
String formatRelativeTime(DateTime date) {
  final now = DateTime.now();
  final diff = now.difference(date);

  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hours ago';
  if (diff.inHours < 48) return 'Yesterday';

  // Absolute date for older entries.
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[date.month - 1]} ${date.day}';
}

/// Format transfer speed (e.g., "125.3 MB/s").
String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '—';
  return '${formatBytes(bytesPerSecond.toInt())}/s';
}
