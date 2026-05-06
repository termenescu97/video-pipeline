import 'package:flutter/material.dart';

@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  final Color success;
  final Color error;
  final Color warning;
  final Color active;
  final Color pending;

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
  static const _statusColors = StatusColors(
    success: Colors.green,
    error: Colors.red,
    warning: Colors.orange,
    active: Colors.blue,
    pending: Colors.grey,
  );

  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.blue,
      useMaterial3: true,
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
      extensions: const [_statusColors],
      cardTheme: const CardThemeData(
        elevation: 2,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      appBarTheme: const AppBarTheme(centerTitle: false),
    );
  }
}
