import 'package:flutter/material.dart';

import 'text_styles.dart';

@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  final Color success;
  final Color error;
  final Color warning;
  final Color active;
  final Color pending;

  // Dot-color getters used by the StatusBar state dot (FR-003a).
  // Mapped onto the existing semantic slots so we don't duplicate constants.
  Color get dotIdle => pending;
  Color get dotActive => active;
  Color get dotRecentDone => success;
  Color get dotAttention => error;
  Color get dotWarning => warning;

  const StatusColors({
    required this.success,
    required this.error,
    required this.warning,
    required this.active,
    required this.pending,
  });

  @override
  StatusColors copyWith({
    Color? success,
    Color? error,
    Color? warning,
    Color? active,
    Color? pending,
  }) {
    return StatusColors(
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      active: active ?? this.active,
      pending: pending ?? this.pending,
    );
  }

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      active: Color.lerp(active, other.active, t)!,
      pending: Color.lerp(pending, other.pending, t)!,
    );
  }
}

class AppTheme {
  // Material 3 + seeded blue color scheme is preserved (FR-042).
  // Dark mode is intentionally NOT extended in this feature; the existing
  // dark getter stays in place for future work.
  static const _statusColors = StatusColors(
    success: Colors.green,
    error: Colors.red,
    warning: Colors.orange,
    active: Colors.blue,
    pending: Colors.grey,
  );

  static const TextTheme _textTheme = TextTheme(
    displayLarge: AppTextStyles.display,
    displayMedium: AppTextStyles.display,
    displaySmall: AppTextStyles.display,
    headlineLarge: AppTextStyles.headline,
    headlineMedium: AppTextStyles.headline,
    headlineSmall: AppTextStyles.headline,
    titleLarge: AppTextStyles.title,
    titleMedium: AppTextStyles.title,
    titleSmall: AppTextStyles.title,
    bodyLarge: AppTextStyles.body,
    bodyMedium: AppTextStyles.body,
    bodySmall: AppTextStyles.caption,
    labelLarge: AppTextStyles.body,
    labelMedium: AppTextStyles.caption,
    labelSmall: AppTextStyles.caption,
  );

  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.blue,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      textTheme: _textTheme,
      extensions: const [_statusColors],
      cardTheme: const CardThemeData(
        elevation: 2,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      appBarTheme: const AppBarTheme(centerTitle: false),
    );
  }

  static ThemeData get light {
    return ThemeData(
      brightness: Brightness.light,
      colorSchemeSeed: Colors.blue,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      textTheme: _textTheme,
      extensions: const [_statusColors],
      cardTheme: const CardThemeData(
        elevation: 2,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      appBarTheme: const AppBarTheme(centerTitle: false),
    );
  }
}
