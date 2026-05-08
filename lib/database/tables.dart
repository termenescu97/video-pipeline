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

  @override
  Set<Column> get primaryKey => {id};
}
