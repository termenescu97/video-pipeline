import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'database/database.dart';
import 'database/daos/favorite_path_dao.dart';
import 'database/daos/job_dao.dart';
import 'database/daos/job_file_dao.dart';
import 'database/daos/settings_dao.dart';
import 'utils/instance_lock.dart';
import 'services/compression_service.dart';
import 'services/drive_service.dart';
import 'services/job_queue_service.dart';
import 'services/log_service.dart';
import 'services/queue_state_notifier.dart';
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
late final LogService logService;
late final InstanceLock instanceLock;
late final QueueStateNotifier queueStateNotifier;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Window manager — set up before any UI runs.
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(1280, 720));
  await windowManager.setTitle('Copiatorul3000');

  // Single-instance lock. Fails closed if it cannot be acquired safely.
  instanceLock = InstanceLock();
  final acquired = await instanceLock.acquire();
  if (!acquired) {
    await windowManager.setSize(const Size(520, 320));
    await windowManager.setTitle('Copiatorul3000— Already Running');
    runApp(const _AlreadyRunningApp());
    return;
  }

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

  // Crash recovery: move stale in-progress jobs back to a resumable state.
  // Must run after DB init and after instance lock is held (single writer).
  await jobDao.recoverStaleJobs();

  // Logger.
  logService = LogService();
  await logService.init();
  logService.info('App started');

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
    driveService: driveService,
    logService: logService,
  );
  queueStateNotifier = QueueStateNotifier();

  runApp(const VideoPipelineApp());
}

/// Minimal app shown when a second instance attempts to launch.
/// Prevents accidental concurrent SQLite writes that would corrupt the DB.
class _AlreadyRunningApp extends StatelessWidget {
  const _AlreadyRunningApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Copiatorul3000',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Copiatorul3000 is already running',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Only one instance can run at a time to prevent database corruption.\n\n'
                  'Switch to the running window, or close it before starting a new one.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => exit(1),
                  child: const Text('Exit'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
