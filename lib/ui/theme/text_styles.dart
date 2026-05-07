import 'package:flutter/material.dart';

/// Five-style typography scale + a monospace variant. Numeric-heavy styles
/// apply tabular figures so live-updating numbers don't shift surrounding
/// layout.
class AppTextStyles {
  static const _tabularFigures = <FontFeature>[FontFeature.tabularFigures()];

  /// Large emphatic numerics — e.g. status-bar speed/ETA readouts.
  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.25,
    fontFeatures: _tabularFigures,
  );

  /// Screen title.
  static const TextStyle headline = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );

  /// Section header / card title.
  static const TextStyle title = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );

  /// Body copy — also numeric-aware (tabular figures) since it's used for
  /// inline stats like "23/49" and "184 MB/s".
  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
    fontFeatures: _tabularFigures,
  );

  /// Caption / supporting label.
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.15,
    fontFeatures: _tabularFigures,
  );

  /// Monospace variant for paths and SHA-256 hashes. Bundled JetBrains Mono
  /// font asset; no system-font fallback for the digit-zero glyph.
  static const TextStyle mono = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    fontFeatures: _tabularFigures,
  );
}
