import 'package:flutter/material.dart';

import 'ui/theme/app_theme.dart';
import 'ui/screens/home_screen.dart';

class VideoPipelineApp extends StatelessWidget {
  const VideoPipelineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Pipeline',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
