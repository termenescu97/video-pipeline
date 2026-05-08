import 'package:flutter/material.dart';

import '../theme/insets.dart';

/// Loading-state placeholder used while a panel is fetching its first
/// frame of data (T105). A shimmering rounded-rect at the row height
/// the host expects.
///
/// Replaces the spartan `CircularProgressIndicator` previously shown
/// during the source scan / queue first-load / files first-load
/// windows — gives the operator a sense of WHERE the data will appear
/// (height + horizontal padding match the eventual content) instead
/// of a free-floating spinner.
///
/// [height] is the row height to mimic; pick the value that matches
/// the destination widget (e.g., 64 for JobCardQueued, 48 for
/// JobCardDone, 60 for SourcesPanel rows). Width tracks the
/// surrounding constraints.
class SkeletonRow extends StatefulWidget {
  final double height;

  /// Horizontal margin around the shimmer rect — matches the natural
  /// gutter the real card would have.
  final double horizontalMargin;

  const SkeletonRow({
    super.key,
    required this.height,
    this.horizontalMargin = Insets.s,
  });

  @override
  State<SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<SkeletonRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.horizontalMargin,
        vertical: Insets.xs,
      ),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          // Two-color gradient that slides L→R; alignment maps the
          // animation [0,1] onto [-1,1] for [Alignment.x].
          final t = _ctrl.value;
          return Container(
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: LinearGradient(
                begin: Alignment(-1 + 2 * t, 0),
                end: Alignment(1 + 2 * t, 0),
                colors: [
                  scheme.surfaceContainerHigh,
                  scheme.surfaceContainerHighest,
                  scheme.surfaceContainerHigh,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
