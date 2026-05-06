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
}
