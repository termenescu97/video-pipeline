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
/// CSV escaping follows RFC 4180: fields containing quotes have those
/// quotes doubled. The temp+rename write pattern means an interrupted
/// export does not leave a truncated file at the operator's chosen path.
Future<void> exportHistoryToCsv(BuildContext context) async {
  final jobs = await jobDao.getCompletedJobsList();
  if (!context.mounted) return;
  if (jobs.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
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
      [
        _csv(date),
        _csv(job.type.label),
        _csv(job.sourcePath),
        _csv(job.destinationPath),
        '${job.totalFiles}',
        _csv(size),
        _csv(job.status.label),
        _csv(duration),
        _csv(operator),
      ].join(','),
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

  // Atomic write: stage to a sibling temp file, then rename over the
  // destination. An interrupted run leaves the temp file (cleaned up
  // on the next successful export) without ever truncating the
  // operator's chosen path.
  final tmpPath = '$savePath.tmp';
  try {
    await File(tmpPath).writeAsString(buffer.toString(), flush: true);
    await File(tmpPath).rename(savePath);
  } catch (e) {
    // Best-effort cleanup of the temp file before surfacing the error.
    try {
      await File(tmpPath).delete();
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Export failed: $e')),
    );
    return;
  }

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('History exported to $savePath')),
  );
}

/// RFC 4180 CSV field encoder. Wraps the value in double-quotes and
/// doubles any embedded double-quote.
String _csv(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}
