/// Maps raw error messages to human-friendly descriptions with remediation steps.
class ErrorMapper {
  static const _patterns = <String, String>{
    'Access is denied':
        'The destination folder is protected. Try running the app as Administrator or choose a different folder.',
    'Access denied':
        'The destination folder is protected. Try running the app as Administrator or choose a different folder.',
    'not enough space':
        'The destination drive is full. Free up space or choose a different drive.',
    'disk full':
        'The destination drive is full. Free up space or choose a different drive.',
    'cannot find the path':
        'The source path no longer exists. The SD card may have been removed.',
    'cannot find the file':
        'A source file could not be found. The SD card may have been removed.',
    'network path was not found':
        'The network drive is not reachable. Check your network connection.',
    'being used by another process':
        'A file is locked by another application. Close other programs using the file and retry.',
    'Verification failed':
        'The copied file does not match the original. The transfer may have been corrupted. Try again.',
    'SD card disconnected':
        'The SD card was removed during transfer. Re-insert the card and tap Retry.',
  };

  /// Returns a user-friendly error message. Falls back to a generic message.
  static String getFriendlyMessage(String? rawError) {
    if (rawError == null || rawError.isEmpty) {
      return 'An unexpected error occurred.';
    }

    final lower = rawError.toLowerCase();
    for (final entry in _patterns.entries) {
      if (lower.contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }

    return 'An unexpected error occurred. See Technical Details for more information.';
  }
}
