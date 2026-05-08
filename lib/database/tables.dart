import 'package:drift/drift.dart';

/// Job type enum stored as text in the database.
enum JobType { transfer, compression, transferAndCompress }

/// Job status enum stored as text in the database.
enum JobStatus { queued, inProgress, completed, failed, paused }

/// File status within a job.
enum FileStatus { pending, inProgress, completed, failed, skipped }

/// Favorite path type — what this path is typically used for.
enum FavoritePathType { source, destination, output }

/// Verification mode for file transfers.
enum VerificationMode { size, sha256 }

/// 017 (v8): granular per-file verify outcome, independent of [FileStatus].
/// `pending` = verification has not run or is in progress.
/// `verified` = SHA-256 ran and source/dest hashes matched (cryptographic trust).
/// `mismatch` = SHA-256 ran but bytes differ (real corruption — hard fail; FR-005 forces re-copy on Retry).
/// `unverified` = verification subsystem itself failed (PS broken, etc.) OR
///                size-only verification passed (no cryptographic trust per Codex M5).
enum VerifyStatus { pending, verified, mismatch, unverified }

/// 017 (v8): retry routing for failures. Distinguishes copy-side errors
/// from verify-side outcomes so Retry can take the right action
/// (e.g. forceDestDelete=true for verifyMismatch per FR-005 / Codex H2).
enum FailureKind { none, copyError, verifyMismatch, verifyUnreliable }

/// Central unit of work in the queue.
class Jobs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get type => textEnum<JobType>()();
  TextColumn get status => textEnum<JobStatus>()();
  TextColumn get sourcePath => text()();
  TextColumn get destinationPath => text()();
  TextColumn get compressionOutputPath => text().nullable()();
  TextColumn get presetName => text().nullable()();
  BoolColumn get autoChain => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get totalFiles => integer().withDefault(const Constant(0))();
  IntColumn get completedFiles => integer().withDefault(const Constant(0))();
  IntColumn get totalBytes => integer().withDefault(const Constant(0))();
  IntColumn get completedBytes => integer().withDefault(const Constant(0))();
  TextColumn get operatorName => text().nullable()();
  TextColumn get verificationMode =>
      textEnum<VerificationMode>().withDefault(Constant(VerificationMode.size.name))();

  /// 017 (v8): mirror of count of JobFile rows where verifyStatus = unverified.
  /// Re-derived from JobFile rows by recoverStaleJobs (FR-007 / FR-018).
  IntColumn get unverifiedFiles =>
      integer().withDefault(const Constant(0))();

  /// 017 (v8): set ONLY by `_createChainedCompressionJob` at chain time.
  /// Points back to the parent transferAndCompress job so the chained
  /// compression's Slack notification (FR-019) can query the parent's
  /// transfer-phase verify counts. Null for directly-created jobs.
  /// Survives parent's status changes; gracefully degrades on missing
  /// parent (Codex round-3 architectural decision).
  IntColumn get parentJobId =>
      integer().nullable().references(Jobs, #id)();
}

/// Tracks individual file status within a job.
class JobFiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get jobId => integer().references(Jobs, #id)();
  TextColumn get sourceFilePath => text()();
  TextColumn get destinationFilePath => text()();
  TextColumn get fileName => text()();
  IntColumn get fileSize => integer()();
  TextColumn get status => textEnum<FileStatus>()();
  BoolColumn get verified => boolean().withDefault(const Constant(false))();
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get sourceHash => text().nullable()();
  TextColumn get destinationHash => text().nullable()();

  /// 015 (v7): operator explicitly approved overwrite for THIS file at
  /// conflict-preflight time. The executor honors this flag absolutely:
  /// dest is deleted before robocopy regardless of size, so /XN/XC/XO
  /// can be always-on without losing operator-approved overwrites.
  /// Default `false` means "no preflight conflict on this path" — the
  /// safe default. Set to `true` only by `_applyResolution` when the
  /// operator chose `Overwrite` AND the file's dest already existed.
  BoolColumn get wasOverwriteApproved =>
      boolean().withDefault(const Constant(false))();

  /// 017 (v8): granular verify-side state, independent of [status]
  /// (which tracks copy state). The pre-existing [verified] boolean
  /// remains for backward-compat with feature 014 UI readers; new
  /// code reads this enum for the verified/mismatch/unverified split.
  /// Default 'pending' — set by markFileVerified / markFileVerifyMismatch
  /// / markFileUnverified after the SHA-256 hash check completes.
  TextColumn get verifyStatus => textEnum<VerifyStatus>()
      .withDefault(Constant(VerifyStatus.pending.name))();

  /// 017 (v8): retry routing for failures. Set when the file enters
  /// a failure state (`status='failed'` or `verifyStatus='mismatch'`).
  /// `verifyMismatch` triggers `forceDestDelete=true` on operator Retry
  /// to close the same-size-corrupt-dest infinite loop (Codex H2).
  TextColumn get failureKind => textEnum<FailureKind>()
      .withDefault(Constant(FailureKind.none.name))();
}

/// User-saved folder paths for quick reuse.
class FavoritePaths extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text()();
  TextColumn get label => text()();
  TextColumn get type => textEnum<FavoritePathType>()();
  DateTimeColumn get lastUsedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
}

/// Global app configuration (singleton row).
class AppSettings extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get slackWebhookUrl => text().withDefault(const Constant(''))();
  BoolColumn get checkUpdatesOnLaunch =>
      boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastUpdateCheck => dateTime().nullable()();
  TextColumn get currentVersion =>
      text().withDefault(const Constant('1.0.0'))();
  BoolColumn get firstRunCompleted =>
      boolean().withDefault(const Constant(false))();
  TextColumn get lastUsedDestination =>
      text().withDefault(const Constant(''))();
  TextColumn get lastUsedOutput =>
      text().withDefault(const Constant(''))();
  TextColumn get operatorName =>
      text().withDefault(const Constant(''))();

  // US9 (T079): operator-level defaults that persist across sessions.
  // Schema v6 — added in feature 014. Defaults match the v2.3.0
  // hardcoded behavior so an upgrade is invisible until the operator
  // changes them in Settings → Behavior.
  TextColumn get defaultVerificationMode =>
      text().withDefault(const Constant('size'))();
  TextColumn get defaultConflictResolution =>
      text().withDefault(const Constant('ask'))();

  /// 017 (v8): persists the Sources panel collapsed/expanded state
  /// across app restarts. Consumed by feature 018 (UX restructuring);
  /// piggybacks on this migration to avoid a second schema bump.
  BoolColumn get sourcesPanelCollapsed =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
