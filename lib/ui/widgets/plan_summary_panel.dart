import 'package:flutter/material.dart';

import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// US8 — Plan summary panel shown live in CreateJobScreen above the
/// "Add to Queue" button. Surfaces the four facts an operator needs to
/// know BEFORE committing a job (FR-026..FR-029):
///   - File count and total bytes (from a source scan)
///   - Free-space verdict against the destination ("plenty of room" /
///     "cutting it close" / "won't fit")
///   - Conflict count (existing files at the planned destinations)
///   - Long-path count (files whose destination path > 260 chars —
///     Windows MAX_PATH limit, may be rejected)
///
/// ETA is intentionally OMITTED (FR-026 / clarification): pre-flight ETA
/// is unreliable for video work — robocopy speed depends on the card
/// reader's actual throughput which we don't know until transfer starts.
/// ETA appears only on running cards (PipelineProgressBar) where we have
/// real bytes/sec.
///
/// All inputs are nullable so the panel renders progressively as the
/// scan resolves: while [scanInProgress] is true, the panel shows a
/// "Scanning…" pill instead of stats. After the scan, missing pieces
/// (e.g., destination not yet picked) just don't render — the panel is
/// shy about claiming things it can't compute.
class PlanSummaryPanel extends StatelessWidget {
  /// Whether a source scan is currently running (debounced trigger from
  /// the host on source/destination change).
  final bool scanInProgress;

  /// Total video files found in the source. `null` while no scan has
  /// completed yet.
  final int? fileCount;

  /// Sum of file sizes across [fileCount]. `null` while not yet scanned.
  final int? totalBytes;

  /// Free space at the picked destination. `null` when no destination
  /// is selected (free-space verdict line is skipped).
  final int? freeBytes;

  /// Number of planned destination paths that already exist on disk.
  /// `null` when the conflict pass hasn't run; the conflict line is
  /// skipped. `0` after the pass with no conflicts (we don't render
  /// a "0 conflicts" line — silence is the success signal).
  final int? conflictCount;

  /// Number of planned destination paths > 260 chars. Same null-vs-0
  /// distinction as [conflictCount].
  final int? longPathCount;

  const PlanSummaryPanel({
    super.key,
    required this.scanInProgress,
    this.fileCount,
    this.totalBytes,
    this.freeBytes,
    this.conflictCount,
    this.longPathCount,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;

    return Container(
      padding: const EdgeInsets.all(Insets.m),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Headline: file count + bytes.
          Row(
            children: [
              Icon(Icons.summarize_outlined,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: Insets.s),
              Expanded(
                child: Text(
                  _headline(),
                  style: AppTextStyles.body,
                ),
              ),
              if (scanInProgress)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),

          // Free-space verdict — colored sentence (matches inline
          // _FreeSpaceSentence behavior in CreateJobScreen, but composed
          // here so all plan facts live in one panel).
          if (freeBytes != null) ...[
            const SizedBox(height: Insets.s),
            _FreeSpaceLine(
              freeBytes: freeBytes!,
              plannedBytes: totalBytes,
              statusColors: statusColors,
            ),
          ],

          // Conflict count — neutral if 0, warning color if > 0.
          if (conflictCount != null && conflictCount! > 0) ...[
            const SizedBox(height: Insets.xs),
            Row(
              children: [
                Icon(Icons.swap_horiz,
                    size: 16, color: statusColors.warning),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    conflictCount == 1
                        ? '1 file already exists at the destination — '
                            'you\'ll be asked how to resolve'
                        : '${conflictCount!} files already exist at the destination — '
                            'you\'ll be asked how to resolve',
                    style: AppTextStyles.caption
                        .copyWith(color: statusColors.warning),
                  ),
                ),
              ],
            ),
          ],

          // Long-path inline note — yellow, replaces the v2.3.0 blocking
          // AlertDialog (T072). Surfaces upfront so the operator decides
          // BEFORE creating the job (FR-028).
          if (longPathCount != null && longPathCount! > 0) ...[
            const SizedBox(height: Insets.xs),
            Row(
              children: [
                Icon(Icons.warning_amber,
                    size: 16, color: statusColors.warning),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    longPathCount == 1
                        ? '1 file has a path > 260 chars — '
                            'Windows may reject it'
                        : '${longPathCount!} files have paths > 260 chars — '
                            'Windows may reject these',
                    style: AppTextStyles.caption
                        .copyWith(color: statusColors.warning),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Headline text. Stays useful at every loading stage:
  ///   - no scan, no source     → "Pick a source to scan"
  ///   - scan running, no totals → "Scanning source…"
  ///   - scan done              → "47 files · 118 GB"
  ///   - scan done, 0 files     → "No video files found"
  String _headline() {
    if (fileCount == null) {
      return scanInProgress ? 'Scanning source…' : 'Pick a source to scan';
    }
    if (fileCount == 0) return 'No video files found';
    final bytes = totalBytes != null ? formatBytes(totalBytes!) : '—';
    return '$fileCount file${fileCount == 1 ? '' : 's'} · $bytes';
  }
}

/// Inline free-space verdict (FR-027). Three states:
///   - won't fit: red, shows shortfall
///   - cutting it close: yellow (planned > 90% of free)
///   - plenty of room: neutral
class _FreeSpaceLine extends StatelessWidget {
  final int freeBytes;
  final int? plannedBytes;
  final StatusColors statusColors;

  const _FreeSpaceLine({
    required this.freeBytes,
    required this.plannedBytes,
    required this.statusColors,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final freeText = formatBytes(freeBytes);

    String sentence;
    Color color = scheme.onSurfaceVariant;
    IconData icon = Icons.check_circle_outline;

    if (plannedBytes != null && plannedBytes! > freeBytes) {
      final shortBy = plannedBytes! - freeBytes;
      sentence =
          "$freeText free — won't fit, you have ${formatBytes(plannedBytes!)} "
          "to copy (${formatBytes(shortBy)} short)";
      color = statusColors.error;
      icon = Icons.error_outline;
    } else if (plannedBytes != null && plannedBytes! > freeBytes * 0.9) {
      sentence =
          '$freeText free — cutting it close (planned ${formatBytes(plannedBytes!)})';
      color = statusColors.warning;
      icon = Icons.warning_amber;
    } else if (freeBytes > 1024 * 1024 * 1024 * 1024) {
      sentence = '$freeText free — plenty of room';
    } else {
      sentence = '$freeText free';
    }

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Text(
            sentence,
            style: AppTextStyles.caption.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
