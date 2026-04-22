import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/host_cli_launch_preferences.dart';
import 'settings_service.dart';

/// Persists host-scoped coding CLI launch preferences in app settings.
class HostCliLaunchPreferencesService {
  /// Creates a new [HostCliLaunchPreferencesService].
  HostCliLaunchPreferencesService(this._settings);

  final SettingsService _settings;

  /// Loads the saved launch preferences for [hostId].
  Future<HostCliLaunchPreferences> getPreferencesForHost(int hostId) async {
    final preferences = await _readPreferenceMap();
    final value = preferences[hostId.toString()];
    if (value is! Map<String, dynamic>) {
      return const HostCliLaunchPreferences();
    }
    return HostCliLaunchPreferences.fromJson(value);
  }

  /// Saves [preferences] for [hostId].
  Future<void> setPreferencesForHost(
    int hostId,
    HostCliLaunchPreferences preferences,
  ) async {
    if (preferences.isEmpty) {
      await deletePreferencesForHost(hostId);
      return;
    }

    final savedPreferences = await _readPreferenceMap();
    savedPreferences[hostId.toString()] = preferences.toJson();
    await _settings.setJson(
      SettingKeys.hostCliLaunchPreferences,
      savedPreferences,
    );
  }

  /// Removes any saved launch preferences for [hostId].
  Future<void> deletePreferencesForHost(int hostId) async {
    final savedPreferences = await _readPreferenceMap();
    savedPreferences.remove(hostId.toString());
    if (savedPreferences.isEmpty) {
      await _settings.delete(SettingKeys.hostCliLaunchPreferences);
      return;
    }
    await _settings.setJson(
      SettingKeys.hostCliLaunchPreferences,
      savedPreferences,
    );
  }

  Future<Map<String, dynamic>> _readPreferenceMap() async =>
      await _settings.getJson(SettingKeys.hostCliLaunchPreferences) ?? {};
}

/// Provider for [HostCliLaunchPreferencesService].
final hostCliLaunchPreferencesServiceProvider =
    Provider<HostCliLaunchPreferencesService>(
      (ref) =>
          HostCliLaunchPreferencesService(ref.watch(settingsServiceProvider)),
    );
