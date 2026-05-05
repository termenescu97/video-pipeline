import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'database/database.dart';

late final AppDatabase database;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize FFI for SQLite on desktop.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  database = AppDatabase();

  runApp(const VideoPipelineApp());
}
