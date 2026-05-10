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

  AppDatabase.forTesting(super.e);

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
            // trust (Codex M5). Map to `notVerified` — the size-mode
            // baseline state added in Codex round-11 to keep size-mode
            // rows distinct from SHA-256 subsystem failures
            // (`unverified`). Limited to transfer-type jobs;
            // compression rows leave verifyStatus=pending because the
            // verify axis doesn't apply to them at all (FR-017
            // hide-rule).
            await customStatement('''
              UPDATE job_files
              SET verify_status = 'notVerified'
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

            // Phase 4b (Codex round-19 P2): hash-only failures from
            // phases 3+4 are post-copy events — robocopy succeeded
            // before the verify step failed. In the v8 decoupled
            // model that's `status=completed && verifyStatus=mismatch`
            // (or `unverified`), not `status=failed`. Flip the row
            // status so:
            //  - the new Accept actions in JobCardDone reach files
            //    that need them (they read the parent job from
            //    JobStatus.completed cards),
            //  - Job.completedFiles/completedBytes count the bytes
            //    that are actually on disk,
            //  - maybeChainCompression's "no failed file rows" gate
            //    isn't blocked by rows where the copy succeeded.
            // failure_kind stays as set above so audit attribution
            // (verifyMismatch / verifyUnreliable) is preserved; the
            // legacy `verified` boolean stays 0 because no
            // cryptographic trust was established.
            await customStatement('''
              UPDATE job_files
              SET status = 'completed'
              WHERE status = 'failed'
                AND verify_status IN ('mismatch', 'unverified')
            ''');

            // Phase 5: remaining failed rows are copy errors.
            await customStatement('''
              UPDATE job_files
              SET failure_kind = 'copyError'
              WHERE status = 'failed' AND failure_kind = 'none'
            ''');

            // Phase 6: re-derive Job.completedFiles / completedBytes /
            // unverifiedFiles for every job touched by Phase 4b.
            // Without this, the Job-level mirror diverges from
            // per-row state and the new Accept paths can't recover
            // the parent (counters say 0 completed even though rows
            // are completed). Scoped to jobs containing at least one
            // mismatch/unverified row to limit blast radius on large
            // dbs, but the recompute itself is whole-job idempotent.
            await customStatement('''
              UPDATE jobs
              SET
                completed_files = (
                  SELECT COUNT(*) FROM job_files
                  WHERE job_id = jobs.id AND status = 'completed'
                ),
                completed_bytes = COALESCE((
                  SELECT SUM(file_size) FROM job_files
                  WHERE job_id = jobs.id AND status = 'completed'
                ), 0),
                unverified_files = (
                  SELECT COUNT(*) FROM job_files
                  WHERE job_id = jobs.id
                    AND verify_status = 'unverified'
                )
              WHERE id IN (
                SELECT DISTINCT job_id FROM job_files
                WHERE verify_status IN ('mismatch', 'unverified')
              )
            ''');

            // Phase 7 (Codex round-19 P2): jobs whose only failed
            // rows were hash-only failures (now flipped to
            // completed) have zero remaining `status=failed`
            // children. Lift the parent Job.status from 'failed' to
            // 'completed' for those — otherwise JobCardDone never
            // shows them and the Accept menu is unreachable. Jobs
            // with copy-error rows (Phase 5) keep status='failed'.
            // completedAt is preserved if already set; we don't
            // back-date it here.
            // 018 T017 (FR-012): clear error_message on the same rows.
            // The lifted job's status flips from 'failed' to
            // 'completed', but the previously-stored error_message
            // (e.g. "5/10 files transferred, 5 failed copy") would
            // otherwise remain on the now-completed row — UI surfaces
            // reading that field would render a stale failure message
            // on a job marked as completed (operator confusion).
            // Setting it NULL is the correct semantic: there is no
            // ongoing error to report for a job that's now considered
            // completed.
            await customStatement('''
              UPDATE jobs
              SET status = 'completed', error_message = NULL
              WHERE status = 'failed'
                AND id IN (
                  SELECT DISTINCT job_id FROM job_files
                  WHERE verify_status IN ('mismatch', 'unverified')
                )
                AND id NOT IN (
                  SELECT DISTINCT job_id FROM job_files
                  WHERE status = 'failed'
                )
            ''');
          });
        }
      },
      // 018 T001 (FR-009 + FR-010 + FR-012): connection-open hook.
      // Drift's MigrationStrategy.beforeOpen runs AFTER onCreate/onUpgrade
      // and BEFORE any DAO query lands (verified by Codex round-22 P3).
      //
      // Order of statements is load-bearing:
      //   1. NULL out any pre-existing dangling parent_job_id rows.
      //      Without this, flipping the FK pragma in step 3 would
      //      surface deferred constraint failures on the FIRST write
      //      that touches an offending row — operators who deleted a
      //      parent before the v2.5.0 release would see unfamiliar
      //      errors that look unrelated to this feature.
      //   2. NULL out stale errorMessage on jobs that the v8 migration
      //      lifted from failed → completed. Idempotent — re-runs are
      //      no-ops because of the `error_message IS NOT NULL` filter.
      //      Catches existing-v8 testers retroactively (the migration
      //      itself only fires for `from < 8` and won't re-clear).
      //   3. Enable foreign_keys enforcement. Per-connection setting
      //      (SQLite docs); MUST be set on every connection-open.
      //
      // Cleanup statements 1 + 2 are fire-and-forget no-ops at typical
      // project scale (sub-millisecond per Codex round-22 P3 SCAN
      // analysis). Step 3 is one PRAGMA write.
      beforeOpen: (details) async {
        await customStatement(
          'UPDATE jobs SET parent_job_id = NULL '
          'WHERE parent_job_id IS NOT NULL '
          'AND parent_job_id NOT IN (SELECT id FROM jobs)',
        );
        await customStatement(
          "UPDATE jobs SET error_message = NULL "
          "WHERE status = 'completed' "
          "AND id IN (SELECT DISTINCT job_id FROM job_files "
          "WHERE verify_status IN ('mismatch', 'unverified')) "
          "AND id NOT IN (SELECT DISTINCT job_id FROM job_files "
          "WHERE status = 'failed') "
          "AND error_message IS NOT NULL",
        );
        await customStatement('PRAGMA foreign_keys = ON');
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
