import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../database/extensions.dart';
import '../main.dart';
import 'format_utils.dart';

/// Exports the job history to a CSV file via the native save-file picker.
///
/// Used both by the Activity panel's "Export CSV" button (T045) and the
/// `Ctrl+E` keyboard shortcut (US11 T097) — sharing the same flow keeps
/// behavior consistent and avoids duplicating the buffer/save logic.
///
/// Shows a snackbar on the given [context] for empty-history and
/// success cases. Caller is responsible for ensuring [context] is still
/// mounted at call time.
Future<void> exportHistoryToCsv(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final jobs = await jobDao.getCompletedJobsList();
  if (jobs.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No history to export')),
    );
    return;
  }

  final buffer = StringBuffer();
  buffer.writeln(
      'Date,Type,Source,Destination,Files,Size,Status,Duration,Operator');
  for (final job in jobs) {
    final date = job.completedAt?.toIso8601String().split('T').first ?? '';
    final duration = (job.startedAt != null && job.completedAt != null)
        ? formatDuration(job.completedAt!.difference(job.startedAt!))
        : '';
    final size = formatBytes(job.totalBytes);
    final operator = job.operatorName ?? '';
    buffer.writeln(
      '"$date","${job.type.label}","${job.sourcePath}","${job.destinationPath}",'
      '${job.totalFiles},"$size","${job.status.label}","$duration","$operator"',
    );
  }

  final now = DateTime.now();
  final defaultName =
      'copiatorul3000-history-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.csv';

  final savePath = await FilePicker.platform.saveFile(
    dialogTitle: 'Export History',
    fileName: defaultName,
    type: FileType.custom,
    allowedExtensions: ['csv'],
  );
  if (savePath == null) return;

  await File(savePath).writeAsString(buffer.toString());
  messenger.showSnackBar(
    SnackBar(content: Text('History exported to $savePath')),
  );
}
