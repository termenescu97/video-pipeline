import 'package:flutter/material.dart';

import '../../utils/format_utils.dart';

/// A progress bar widget with label, percentage, ETA, speed, and current file.
class PipelineProgressBar extends StatelessWidget {
  final double progress;
  final String label;
  final String? currentFileName;
  final int completedFiles;
  final int totalFiles;
  final Duration? elapsed;
  final Duration? eta;
  final double? speedBytesPerSec;
  final double? fps;

  const PipelineProgressBar({
    super.key,
    required this.progress,
    required this.label,
    this.currentFileName,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.elapsed,
    this.eta,
    this.speedBytesPerSec,
    this.fps,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(
              '${(progress * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: 4),
        // Current file name.
        if (currentFileName != null)
          Text(
            currentFileName!,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 2),
        // Stats row: files, speed, elapsed, ETA.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (totalFiles > 0)
              Text(
                '$completedFiles / $totalFiles files',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            if (speedBytesPerSec != null)
              Text(
                formatSpeed(speedBytesPerSec!),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            if (fps != null)
              Text(
                '${fps!.toStringAsFixed(1)} fps',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        if (elapsed != null || eta != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (elapsed != null)
                Text(
                  'Elapsed: ${formatDuration(elapsed!)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              if (eta != null)
                Text(
                  'ETA: ${formatDuration(eta!)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
            ],
          ),
      ],
    );
  }
}
