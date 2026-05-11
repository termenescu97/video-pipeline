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

  /// US9 (T079): default conflict-resolution behavior. Allowed values:
  ///   `'ask'`        — show the resolution dialog (current v2.3.0 default)
  ///   `'skip'`       — silently skip pre-existing files
  ///   `'rename'`     — auto-suffix _1, _2, …
  ///
  /// `'overwrite'` is REJECTED at this boundary. Constitution Principle I:
  /// silent overwrite must always require typed confirm at point of use,
  /// never as a stored default. The UI omits 'overwrite' from the
  /// dropdown; the assertion below ensures a stray DB write — or a
  /// future code path — can't smuggle it in either.
  ///
  /// `'newFolder'` is also rejected as a stored default — it requires
  /// interactive folder picking and degrades to 'ask' at runtime, so
  /// storing it would be a silently-wrong UX promise (Codex Phase 11
  /// review WARN). Operator picks newFolder per-job, never as default.
  Future<void> setDefaultConflictResolution(String resolution) {
    assert(
      const {'ask', 'skip', 'rename'}.contains(resolution),
      'Invalid defaultConflictResolution: "$resolution". Allowed: ask, skip, rename.',
    );
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(defaultConflictResolution: Value(resolution)));
  }

  /// 017B (FR-B03): persist the SourcesPanel collapse state so the
  /// operator's preference survives restart. The column itself was
  /// added in 017A's v8 migration (the UI work was deferred; this is
  /// where it's wired up).
  Future<void> setSourcesPanelCollapsed(bool collapsed) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(sourcesPanelCollapsed: Value(collapsed)));
  }
}
