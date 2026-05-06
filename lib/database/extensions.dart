import 'package:flutter/material.dart';

import 'tables.dart';

/// Extension methods on JobType for consistent label display.
extension JobTypeX on JobType {
  String get label => switch (this) {
        JobType.transfer => 'Transfer',
        JobType.compression => 'Compression',
        JobType.transferAndCompress => 'Copy & Compress',
      };
}

/// Extension methods on JobStatus for consistent label and color display.
extension JobStatusX on JobStatus {
  String get label => switch (this) {
        JobStatus.queued => 'Queued',
        JobStatus.inProgress => 'In Progress',
        JobStatus.completed => 'Completed',
        JobStatus.failed => 'Failed',
        JobStatus.paused => 'Paused',
      };

  Color get color => switch (this) {
        JobStatus.queued => Colors.grey,
        JobStatus.inProgress => Colors.blue,
        JobStatus.completed => Colors.green,
        JobStatus.failed => Colors.red,
        JobStatus.paused => Colors.orange,
      };

  IconData get icon => switch (this) {
        JobStatus.queued => Icons.schedule,
        JobStatus.inProgress => Icons.sync,
        JobStatus.completed => Icons.check_circle,
        JobStatus.failed => Icons.error,
        JobStatus.paused => Icons.pause_circle,
      };
}

/// Extension methods on FileStatus for consistent icon display.
extension FileStatusX on FileStatus {
  IconData get icon => switch (this) {
        FileStatus.pending => Icons.schedule,
        FileStatus.inProgress => Icons.sync,
        FileStatus.completed => Icons.check_circle,
        FileStatus.failed => Icons.error,
        FileStatus.skipped => Icons.skip_next,
      };

  Color get color => switch (this) {
        FileStatus.pending => Colors.grey,
        FileStatus.inProgress => Colors.blue,
        FileStatus.completed => Colors.green,
        FileStatus.failed => Colors.red,
        FileStatus.skipped => Colors.orange,
      };
}
