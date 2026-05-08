import 'package:flutter/material.dart';

import '../../utils/format_utils.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Pipeline progress bar (T104 polish, FR-009/FR-010).
///
/// Three regions, top to bottom:
///   1. Title row — phase label + percentage
///   2. Animated bar — slow shimmer when active (progress between 0
///      and 1 strictly), idle linear when paused/done
///   3. Single-line dense stats — `184 MB/s · 23/49 · 12m elapsed ·
///      done by 18:14` (FR-009 — replaces v2.3.0's three separate
///      stat rows)
///   4. Optional middle-ellipsis filename
///
/// All numeric stats inherit `AppTextStyles.caption`'s
/// `tabularFigures`, so a digit-changing speed (`184 MB/s` → `203 MB/s`)
/// no longer reflows the row.
class PipelineProgressBar extends StatefulWidget {
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
  State<PipelineProgressBar> createState() => _PipelineProgressBarState();
}

class _PipelineProgressBarState extends State<PipelineProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _maybeRunShimmer();
  }

  @override
  void didUpdateWidget(covariant PipelineProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeRunShimmer();
  }

  /// Run the shimmer only while the job is actively in progress
  /// (0 < progress < 1). When paused/queued/done, idle the controller
  /// so we don't burn frames repainting an unmoving bar.
  void _maybeRunShimmer() {
    final active = widget.progress > 0 && widget.progress < 1;
    if (active && !_shimmer.isAnimating) {
      _shimmer.repeat();
    } else if (!active && _shimmer.isAnimating) {
      _shimmer.stop();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mutedColor = scheme.onSurfaceVariant;
    final clamped = widget.progress.clamp(0.0, 1.0);
    final active = clamped > 0 && clamped < 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(widget.label, style: AppTextStyles.title),
            Text(
              '${(clamped * 100).toStringAsFixed(1)}%',
              style: AppTextStyles.caption,
            ),
          ],
        ),
        const SizedBox(height: Insets.s),
        // Bar — wrapped in AnimatedBuilder so the shimmer overlay
        // moves; the underlying LinearProgressIndicator value still
        // reflects real progress.
        AnimatedBuilder(
          animation: _shimmer,
          builder: (_, _) => _ShimmerBar(
            progress: clamped,
            shimmerOffset: active ? _shimmer.value : null,
            scheme: scheme,
          ),
        ),
        const SizedBox(height: Insets.xs),
        // Middle-ellipsis filename (FR-013) — the basename can be long
        // (`A001_C012_05072B.MOV`); a head ellipsis would hide the
        // distinguishing suffix, so we truncate the middle.
        if (widget.currentFileName != null)
          _MiddleEllipsisText(
            text: widget.currentFileName!,
            style: AppTextStyles.caption.copyWith(color: mutedColor),
          ),
        const SizedBox(height: Insets.xs),
        // Single-line dense stats. Components are joined by " · " and
        // dropped when their input is null — operator sees only what's
        // currently meaningful.
        _DenseStatsLine(
          completedFiles: widget.completedFiles,
          totalFiles: widget.totalFiles,
          elapsed: widget.elapsed,
          eta: widget.eta,
          speedBytesPerSec: widget.speedBytesPerSec,
          fps: widget.fps,
          mutedColor: mutedColor,
        ),
      ],
    );
  }
}

/// Linear bar with an optional shimmer highlight that sweeps L→R while
/// active (T104, FR-009). When [shimmerOffset] is null, renders as a
/// plain `LinearProgressIndicator` (paused/done state).
class _ShimmerBar extends StatelessWidget {
  final double progress;
  final double? shimmerOffset;
  final ColorScheme scheme;

  const _ShimmerBar({
    required this.progress,
    required this.shimmerOffset,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Stack(
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
            if (shimmerOffset != null)
              // Shimmer band — a translucent white gradient that
              // travels left to right within the filled portion of
              // the bar. Width is 25% of the bar; clipping keeps it
              // inside the bar's rounded corners.
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: ClipRect(
                    child: Align(
                      alignment: Alignment(
                          -1 + 2 * shimmerOffset!, 0),
                      child: FractionallySizedBox(
                        widthFactor: 0.25,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0),
                                Colors.white.withValues(alpha: 0.35),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Single-line dense stats (T104, FR-009). Renders as
/// `184 MB/s · 23/49 · 12m elapsed · done by 18:14` — components
/// are dropped when their inputs are null. Joined by " · " so the
/// row stays one line on the active card width (~360px) until very
/// late stages where everything is populated.
///
/// Stateful so we can cache the "done by HH:mm" wall-clock string
/// across rebuilds. Without the cache, `DateTime.now()` inside build
/// could flip the minute boundary on unrelated rebuilds even when
/// the ETA itself hasn't moved — visible jitter on a fast progress
/// stream (Codex Phase 14 review).
class _DenseStatsLine extends StatefulWidget {
  final int completedFiles;
  final int totalFiles;
  final Duration? elapsed;
  final Duration? eta;
  final double? speedBytesPerSec;
  final double? fps;
  final Color mutedColor;

  const _DenseStatsLine({
    required this.completedFiles,
    required this.totalFiles,
    required this.elapsed,
    required this.eta,
    required this.speedBytesPerSec,
    required this.fps,
    required this.mutedColor,
  });

  @override
  State<_DenseStatsLine> createState() => _DenseStatsLineState();
}

class _DenseStatsLineState extends State<_DenseStatsLine> {
  Duration? _cachedEta;
  String? _cachedDoneByText;

  @override
  void initState() {
    super.initState();
    _refreshDoneByCache(widget.eta);
  }

  @override
  void didUpdateWidget(covariant _DenseStatsLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only rebuild the wall-clock string when ETA actually moves; keep
    // the previous text otherwise so unrelated parent rebuilds (a new
    // current-filename, a speed sample) don't flip "done by 18:14"
    // → "done by 18:15" mid-second.
    if (widget.eta != oldWidget.eta) {
      _refreshDoneByCache(widget.eta);
    }
  }

  void _refreshDoneByCache(Duration? eta) {
    if (eta == null) {
      _cachedEta = null;
      _cachedDoneByText = null;
      return;
    }
    _cachedEta = eta;
    _cachedDoneByText = _doneByClockTime(eta);
  }

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (widget.speedBytesPerSec != null) {
      parts.add(formatSpeed(widget.speedBytesPerSec!));
    }
    if (widget.totalFiles > 0) {
      parts.add('${widget.completedFiles}/${widget.totalFiles}');
    }
    if (widget.fps != null) {
      parts.add('${widget.fps!.toStringAsFixed(1)} fps');
    }
    if (widget.elapsed != null) {
      parts.add('${formatDuration(widget.elapsed!)} elapsed');
    }
    if (widget.eta != null) {
      // Defensive: if didUpdateWidget didn't fire (initial state has
      // null ETA, then ETA arrives), make sure the cache is current.
      if (_cachedDoneByText == null || _cachedEta != widget.eta) {
        _refreshDoneByCache(widget.eta);
      }
      parts.add('done by $_cachedDoneByText');
    }

    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: AppTextStyles.caption.copyWith(color: widget.mutedColor),
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Convert an ETA Duration into a wall-clock "HH:mm" string by
  /// adding to now. The operator reads "done by 18:14" faster than
  /// "ETA 12m" — a direct mapping to their schedule.
  static String _doneByClockTime(Duration eta) {
    final at = DateTime.now().add(eta);
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// Renders [text] with a middle ellipsis (FR-013). `A001_C012_..._05072B.MOV`
/// preserves both the distinguishing prefix and the trailing suffix
/// (which carries the take number — useful for operator scanning).
///
/// LayoutBuilder + TextPainter measures the available width and
/// computes how many characters from each end fit; the middle is
/// replaced by `…`.
///
/// Stateful + memoized: progress rows rebuild on every progress tick
/// (~10 Hz). The binary-search inside [_ellipsize] runs ~log2(N) text
/// measurements; without the cache that's roughly 5 TextPainter
/// layouts per tick per active card. Cache the result keyed by
/// `(text, fontSize, maxWidth)` so the common case (same filename,
/// same card width) reuses the prior layout (Codex Phase 14 review).
class _MiddleEllipsisText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MiddleEllipsisText({required this.text, required this.style});

  @override
  State<_MiddleEllipsisText> createState() => _MiddleEllipsisTextState();
}

class _MiddleEllipsisTextState extends State<_MiddleEllipsisText> {
  String? _cachedText;
  double? _cachedFontSize;
  double? _cachedMaxWidth;
  String? _cachedResult;

  @override
  Widget build(BuildContext context) {
    final fontSize = widget.style.fontSize ?? 14.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (_cachedText == widget.text &&
            _cachedFontSize == fontSize &&
            _cachedMaxWidth == maxWidth &&
            _cachedResult != null) {
          return _staticText(_cachedResult!);
        }
        final result = _ellipsize(widget.text, widget.style, maxWidth);
        _cachedText = widget.text;
        _cachedFontSize = fontSize;
        _cachedMaxWidth = maxWidth;
        _cachedResult = result;
        return _staticText(result);
      },
    );
  }

  Widget _staticText(String value) => Text(
        value,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      );

  static String _ellipsize(String src, TextStyle style, double maxWidth) {
    if (src.isEmpty) return src;
    if (_measure(src, style) <= maxWidth) return src;

    // Binary-search the per-end character count that still fits with
    // the ellipsis between the head and tail halves.
    int lo = 1;
    int hi = src.length ~/ 2;
    int best = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final candidate =
          '${src.substring(0, mid)}…${src.substring(src.length - mid)}';
      if (_measure(candidate, style) <= maxWidth) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return '${src.substring(0, best)}…${src.substring(src.length - best)}';
  }

  static double _measure(String s, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }
}
