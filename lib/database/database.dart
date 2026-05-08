import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables.dart';
import 'daos/job_dao.dart';
import 'daos/job_file_dao.dart';
import 'daos/favorite_path_dao.dart';
import 'daos/settings_dao.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [Jobs, JobFiles, FavoritePaths, AppSettings],
  daos: [JobDao, JobFileDao, FavoritePathDao, SettingsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        // Insert default settings row.
        await into(appSettings).insert(
          AppSettingsCompanion.insert(),
        );
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          await m.addColumn(jobs, jobs.sortOrder);
        }
        if (from < 3) {
          await m.addColumn(appSettings, appSettings.firstRunCompleted);
        }
        if (from < 4) {
          await m.addColumn(appSettings, appSettings.lastUsedDestination);
          await m.addColumn(appSettings, appSettings.lastUsedOutput);
          await m.addColumn(appSettings, appSettings.operatorName);
          await m.addColumn(jobs, jobs.operatorName);
        }
        if (from < 5) {
          await m.addColumn(jobs, jobs.verificationMode);
          await m.addColumn(jobFiles, jobFiles.sourceHash);
          await m.addColumn(jobFiles, jobFiles.destinationHash);
        }
        if (from < 6) {
          // US9 (T079): operator-level Behavior defaults.
          await m.addColumn(
              appSettings, appSettings.defaultVerificationMode);
          await m.addColumn(
              appSettings, appSettings.defaultConflictResolution);
        }
        if (from < 7) {
          // 015: operator-approved overwrite gets stamped per-file at
          // preflight so the executor can honor intent absolutely
          // without losing /Z resume on cancellation/recovery. See
          // specs handoff in feature 015 plan.
          await m.addColumn(jobFiles, jobFiles.wasOverwriteApproved);
        }
      },
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationSupportDirectory();
    final file = File(p.join(dbFolder.path, 'video_pipeline.db'));
    return NativeDatabase.createInBackground(file);
  });
}
