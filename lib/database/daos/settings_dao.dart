import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'settings_dao.g.dart';

@DriftAccessor(tables: [AppSettings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  /// Watch the settings (singleton row).
  Stream<AppSetting> watchSettings() {
    return select(appSettings).watchSingle();
  }

  /// Get current settings.
  Future<AppSetting> getSettings() {
    return select(appSettings).getSingle();
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

  /// Update last update check timestamp.
  Future<void> setLastUpdateCheck(DateTime timestamp) {
    return (update(appSettings)..where((t) => t.id.equals(1)))
        .write(AppSettingsCompanion(lastUpdateCheck: Value(timestamp)));
  }
}
