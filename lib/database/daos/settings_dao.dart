import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'settings_dao.g.dart';

@DriftAccessor(tables: [AppSettings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  /// Watch the settings (singleton row). Returns null if no row exists.
  Stream<AppSetting?> watchSettings() {
    return select(appSettings).watchSingleOrNull();
  }

  /// Get current settings. Returns null if no row exists.
  Future<AppSetting?> getSettings() {
    return select(appSettings).getSingleOrNull();
  }

  /// Update Slack webhook URL.
  Future<void> setSlackWebhookUrl(String url) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(slackWebhookUrl: Value(url)));
  }

  /// Update whether to check for updates on launch.
  Future<void> setCheckUpdatesOnLaunch(bool check) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(checkUpdatesOnLaunch: Value(check)));
  }

  /// Update last-used destination path.
  Future<void> setLastUsedDestination(String path) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(lastUsedDestination: Value(path)));
  }

  /// Update last-used compression output path.
  Future<void> setLastUsedOutput(String path) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(lastUsedOutput: Value(path)));
  }

  /// Update operator name.
  Future<void> setOperatorName(String name) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(operatorName: Value(name)));
  }

  /// Mark first-run onboarding as completed.
  Future<void> setFirstRunCompleted(bool completed) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(firstRunCompleted: Value(completed)));
  }

  /// Update last update check timestamp.
  Future<void> setLastUpdateCheck(DateTime timestamp) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(lastUpdateCheck: Value(timestamp)));
  }

  /// US9 (T079): default verification mode for new jobs. Stored as a
  /// short string (`'size'` / `'sha256'`) to keep the schema enum-free
  /// — the create-job form translates it back into [VerificationMode].
  Future<void> setDefaultVerificationMode(String mode) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(defaultVerificationMode: Value(mode)));
  }

  /// US9 (T079): default conflict-resolution behavior. Values:
  ///   `'ask'`        — show the resolution dialog (current v2.3.0 default)
  ///   `'skip'`       — silently skip pre-existing files
  ///   `'rename'`     — auto-suffix _1, _2, …
  ///   `'newFolder'`  — prompt only for a new destination
  ///   `'overwrite'`  — overwrite without prompt (RESERVED — never the
  ///                    default; should still require a typed confirm
  ///                    when saving this value, per Constitution
  ///                    Principle I)
  Future<void> setDefaultConflictResolution(String resolution) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(defaultConflictResolution: Value(resolution)));
  }
}
