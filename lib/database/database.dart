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

  AppDatabase.forTesting(QueryExecutor e) : super(e);

  @override
  int get schemaVersion => 8;

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
        if (from < 8) {
          // 017: schema v8 — verify-status decoupling, parent-job link
          // for chained compression Slack (FR-019), and Sources panel
          // collapse persistence (consumed by feature 018).
          //
          // Wrap column adds + backfill in a transaction so a mid-
          // migration crash leaves the DB at v7 cleanly. Drift writes
          // schemaVersion only after onUpgrade returns successfully.
          await transaction(() async {
            // Phase 1: column adds.
            await m.addColumn(jobFiles, jobFiles.verifyStatus);
            await m.addColumn(jobFiles, jobFiles.failureKind);
            await m.addColumn(jobFiles, jobFiles.forceDestDeleteApproved);
            await m.addColumn(jobs, jobs.unverifiedFiles);
            await m.addColumn(jobs, jobs.parentJobId);
            await m.addColumn(appSettings, appSettings.sourcesPanelCollapsed);

            // Phase 2: backfill verifyStatus for completed rows.
            // Cryptographic trust requires SHA-256 mode + verified=true.
            await customStatement('''
              UPDATE job_files
              SET verify_status = 'verified'
              WHERE status = 'completed'
                AND verified = 1
                AND job_id IN (
                  SELECT id FROM jobs WHERE verification_mode = 'sha256'
                )
            ''');
            // Size-only verification does NOT establish cryptographic
            // trust (Codex M5). Map to unverified — but ONLY for
            // transfer-type jobs. Compression jobs also have
            // verification_mode='size' (default) and verified=true,
            // but the verify axis doesn't apply to them at all
            // (FR-017 hide-rule). Backfilling them as unverified
            // would inflate jobs.unverified_files and surface
            // misleading warnings on history compression jobs.
            // Codex round-3 P2 #1 fix.
            await customStatement('''
              UPDATE job_files
              SET verify_status = 'unverified'
              WHERE status = 'completed'
                AND verified = 1
                AND job_id IN (
                  SELECT id FROM jobs
                  WHERE verification_mode = 'size'
                    AND type IN ('transfer', 'transferAndCompress')
                )
            ''');
            // status=completed + verified=false: rare (recovery edge);
            // leave at default 'pending' so next access re-verifies.

            // Phase 3: backfill mismatch from narrow errorMessage patterns.
            // Codex H2: '%SHA-256%' alone is too broad. Match only the
            // actual mismatch text emitted by job_queue_service.dart:503/506.
            await customStatement('''
              UPDATE job_files
              SET verify_status = 'mismatch',
                  failure_kind = 'verifyMismatch'
              WHERE status = 'failed'
                AND (
                  error_message LIKE '%SHA-256 hash mismatch%' OR
                  error_message LIKE '%SHA-256 MISMATCH%' OR
                  error_message LIKE '%hash mismatch%'
                )
            ''');

            // Phase 4: backfill unverified subsystem failures from the
            // actual subsystem-failure messages emitted by
            //   job_queue_service.dart:490 'SHA-256 verification failed: could not compute hash'
            //   transfer_service.dart:117  'computeFileHash exit=…'
            //   transfer_service.dart:126  'computeFileHash returned malformed output'
            //   transfer_service.dart:137  'computeFileHash threw for'
            await customStatement('''
              UPDATE job_files
              SET verify_status = 'unverified',
                  failure_kind = 'verifyUnreliable'
              WHERE status = 'failed'
                AND failure_kind = 'none'
                AND (
                  error_message LIKE '%could not compute hash%' OR
                  error_message LIKE '%hash computation failed%' OR
                  error_message LIKE '%computeFileHash exit=%' OR
                  error_message LIKE '%computeFileHash returned malformed output%' OR
                  error_message LIKE '%computeFileHash threw%'
                )
            ''');

            // Phase 5: remaining failed rows are copy errors.
            await customStatement('''
              UPDATE job_files
              SET failure_kind = 'copyError'
              WHERE status = 'failed' AND failure_kind = 'none'
            ''');

            // Phase 6: re-derive Job.unverifiedFiles from per-row state.
            await customStatement('''
              UPDATE jobs
              SET unverified_files = (
                SELECT COUNT(*) FROM job_files
                WHERE job_files.job_id = jobs.id
                  AND job_files.verify_status = 'unverified'
              )
            ''');
          });
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
