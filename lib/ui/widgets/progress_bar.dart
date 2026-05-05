import 'package:flutter/material.dart';

/// A progress bar widget with label and percentage display.
class PipelineProgressBar extends StatelessWidget {
  final double progress;
  final String label;
  final String? currentFileName;
  final int completedFiles;
  final int totalFiles;

  const PipelineProgressBar({
    super.key,
    required this.progress,
    required this.label,
    this.currentFileName,
    this.completedFiles = 0,
    this.totalFiles = 0,
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (currentFileName != null)
              Expanded(
                child: Text(
                  currentFileName!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (totalFiles > 0)
              Text(
                '$completedFiles / $totalFiles files',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
      ],
    );
  }
}
