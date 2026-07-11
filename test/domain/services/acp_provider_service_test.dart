// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpProviderService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    service = AcpProviderService(settings);
  });

  tearDown(() async {
    await database.close();
  });

  test('builtinProviders returns Copilot CLI and OpenCode', () {
    expect(service.builtinProviders, acpBuiltinProviders);
  });

  test('listCustomProviders is empty when nothing is stored', () async {
    expect(await service.listCustomProviders(), isEmpty);
  });

  group('malformed storage', () {
    test('returns an empty list for invalid JSON', () async {
      await settings.setString(
        SettingKeys.acpCustomProviders,
        '{not valid json',
      );
      expect(await service.listCustomProviders(), isEmpty);
    });

    test('returns an empty list when the JSON is not a list', () async {
      await settings.setJson(SettingKeys.acpCustomProviders, {'foo': 'bar'});
      expect(await service.listCustomProviders(), isEmpty);
    });

    test('skips malformed entries but keeps valid ones', () async {
      final valid = AcpCustomProviderDefinition.create(
        id: 'valid-agent',
        label: 'Valid Agent',
        launchCommand: const AcpLaunchCommand(executable: 'valid-agent'),
      );
      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([
          valid.toJson(),
          {'id': 'broken'},
          'not-a-map',
        ]),
      );

      final loaded = await service.listCustomProviders();
      expect(loaded, hasLength(1));
      expect(loaded.single, valid);
    });
  });

  group('CRUD and order', () {
    test('saveCustomProvider appends new entries in insertion order', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: const AcpLaunchCommand(executable: 'first'),
      );
      final second = AcpCustomProviderDefinition.create(
        id: 'second',
        label: 'Second',
        launchCommand: const AcpLaunchCommand(executable: 'second'),
      );

      await service.saveCustomProvider(first);
      await service.saveCustomProvider(second);

      final loaded = await service.listCustomProviders();
      expect(loaded.map((d) => d.id).toList(), ['first', 'second']);
    });

    test('saveCustomProvider updates an existing entry in place', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: const AcpLaunchCommand(executable: 'first'),
      );
      final second = AcpCustomProviderDefinition.create(
        id: 'second',
        label: 'Second',
        launchCommand: const AcpLaunchCommand(executable: 'second'),
      );
      await service.saveCustomProvider(first);
      await service.saveCustomProvider(second);

      final renamedFirst = first.update(label: 'First Renamed');
      await service.saveCustomProvider(renamedFirst);

      final loaded = await service.listCustomProviders();
      expect(loaded.map((d) => d.id).toList(), ['first', 'second']);
      expect(loaded.first.label, 'First Renamed');
    });

    test('getCustomProvider returns a matching entry or null', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: const AcpLaunchCommand(executable: 'first'),
      );
      await service.saveCustomProvider(first);

      expect(await service.getCustomProvider('first'), first);
      expect(await service.getCustomProvider('missing'), isNull);
    });

    test('removeCustomProvider deletes only the matching entry', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: const AcpLaunchCommand(executable: 'first'),
      );
      final second = AcpCustomProviderDefinition.create(
        id: 'second',
        label: 'Second',
        launchCommand: const AcpLaunchCommand(executable: 'second'),
      );
      await service.saveCustomProvider(first);
      await service.saveCustomProvider(second);

      await service.removeCustomProvider('first');

      final loaded = await service.listCustomProviders();
      expect(loaded.map((d) => d.id).toList(), ['second']);
    });

    test(
      'removeCustomProvider clears storage once the list is empty',
      () async {
        final first = AcpCustomProviderDefinition.create(
          id: 'first',
          label: 'First',
          launchCommand: const AcpLaunchCommand(executable: 'first'),
        );
        await service.saveCustomProvider(first);
        await service.removeCustomProvider('first');

        expect(
          await settings.getString(SettingKeys.acpCustomProviders),
          isNull,
        );
      },
    );

    test('removeCustomProvider is a no-op for an unknown ID', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: const AcpLaunchCommand(executable: 'first'),
      );
      await service.saveCustomProvider(first);
      await service.removeCustomProvider('missing');

      expect(await service.listCustomProviders(), [first]);
    });
  });

  group('listAllProviders', () {
    test('lists built-ins before persisted custom providers', () async {
      final custom = AcpCustomProviderDefinition.create(
        id: 'custom-agent',
        label: 'Custom Agent',
        launchCommand: const AcpLaunchCommand(executable: 'custom-agent'),
      );
      await service.saveCustomProvider(custom);

      final all = await service.listAllProviders();
      expect(all, hasLength(acpBuiltinProviders.length + 1));
      expect(
        all.take(acpBuiltinProviders.length).map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );
      expect(all.last.id, custom.id);
      expect(all.last.isCustom, isTrue);
    });
  });
}
