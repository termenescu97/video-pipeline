import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'database/database.dart';
import 'database/daos/favorite_path_dao.dart';
import 'database/daos/job_dao.dart';
import 'database/daos/job_file_dao.dart';
import 'database/daos/settings_dao.dart';
import 'services/compression_service.dart';
import 'services/drive_service.dart';
import 'services/job_queue_service.dart';
import 'services/slack_service.dart';
import 'services/transfer_service.dart';

// Database.
late final AppDatabase database;

// DAOs.
late final JobDao jobDao;
late final JobFileDao jobFileDao;
late final FavoritePathDao favoritePathDao;
late final SettingsDao settingsDao;

// Services.
late final DriveService driveService;
late final TransferService transferService;
late final CompressionService compressionService;
late final SlackService slackService;
late final JobQueueService jobQueueService;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize FFI for SQLite on desktop.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Database.
  database = AppDatabase();

  // DAOs.
  jobDao = JobDao(database);
  jobFileDao = JobFileDao(database);
  favoritePathDao = FavoritePathDao(database);
  settingsDao = SettingsDao(database);

  // Services.
  driveService = DriveService();
  transferService = TransferService();
  compressionService = CompressionService();
  slackService = SlackService(settingsDao: settingsDao);
  jobQueueService = JobQueueService(
    jobDao: jobDao,
    jobFileDao: jobFileDao,
    slackService: slackService,
    transferService: transferService,
    compressionService: compressionService,
  );

  runApp(const VideoPipelineApp());
}
