// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late HostCliLaunchPreferencesService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = HostCliLaunchPreferencesService(SettingsService(database));
  });

  tearDown(() async {
    await database.close();
  });

  test('stores and loads host CLI launch preferences', () async {
    const preferences = HostCliLaunchPreferences(startInYoloMode: true);

    await service.setPreferencesForHost(42, preferences);
    final loaded = await service.getPreferencesForHost(42);

    expect(loaded.startInYoloMode, isTrue);
  });

  test(
    'returns default preferences when a host has no saved overrides',
    () async {
      final loaded = await service.getPreferencesForHost(7);

      expect(loaded.startInYoloMode, isFalse);
      expect(loaded.isEmpty, isTrue);
    },
  );

  test('deletes stored preferences when saved settings are empty', () async {
    await service.setPreferencesForHost(
      7,
      const HostCliLaunchPreferences(startInYoloMode: true),
    );
    await service.setPreferencesForHost(7, const HostCliLaunchPreferences());

    final loaded = await service.getPreferencesForHost(7);
    expect(loaded.startInYoloMode, isFalse);
    expect(loaded.isEmpty, isTrue);
  });
}
