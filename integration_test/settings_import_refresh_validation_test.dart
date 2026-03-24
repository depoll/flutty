// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/settings_screen.dart';

import '../test/support/settings_import_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings import refreshes shared entity providers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final encryptionService = SecretEncryptionService.forTesting();
    final transferService = FakeSecureTransferService(
      db,
      KeyRepository(db, encryptionService),
      HostRepository(db, encryptionService),
      payload: TransferPayload(
        type: TransferPayloadType.fullMigration,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: const {
          'settings': <String, Object?>{},
          'hosts': <Map<String, Object?>>[],
          'keys': <Map<String, Object?>>[],
          'groups': <Map<String, Object?>>[],
          'snippets': <Map<String, Object?>>[],
          'snippetFolders': <Map<String, Object?>>[],
          'portForwards': <Map<String, Object?>>[],
          'knownHosts': <Map<String, Object?>>[],
        },
      ),
    );

    setFakeFilePickerResult(
      result: FilePickerResult([
        PlatformFile(
          name: 'migration.monkeysshx',
          size: 15,
          bytes: Uint8List.fromList(utf8.encode('encoded-payload')),
        ),
      ]),
    );

    var hostBuilds = 0;
    var keyBuilds = 0;
    var groupBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authServiceProvider.overrideWithValue(FakeAuthService()),
          authStateProvider.overrideWith(MockAuthStateNotifier.new),
          secureTransferServiceProvider.overrideWithValue(transferService),
          themeModeNotifierProvider.overrideWith(StaticThemeModeNotifier.new),
          fontSizeNotifierProvider.overrideWith(StaticFontSizeNotifier.new),
          fontFamilyNotifierProvider.overrideWith(StaticFontFamilyNotifier.new),
          cursorStyleNotifierProvider.overrideWith(
            StaticCursorStyleNotifier.new,
          ),
          bellSoundNotifierProvider.overrideWith(StaticBellSoundNotifier.new),
          terminalThemeSettingsProvider.overrideWith(
            StaticTerminalThemeSettingsNotifier.new,
          ),
          allHostsProvider.overrideWith((ref) {
            hostBuilds += 1;
            return Stream.value(<Host>[]);
          }),
          allKeysProvider.overrideWith((ref) {
            keyBuilds += 1;
            return Stream.value(<SshKey>[]);
          }),
          allGroupsProvider.overrideWith((ref) {
            groupBuilds += 1;
            return Stream.value(<Group>[]);
          }),
        ],
        child: const MaterialApp(
          home: Stack(children: [SettingsScreen(), EntityProviderProbe()]),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final initialHostBuilds = hostBuilds;
    final initialKeyBuilds = keyBuilds;
    final initialGroupBuilds = groupBuilds;

    await tester.scrollUntilVisible(
      find.text('Import migration package'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Import migration package'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    expect(transferService.importCallCount, 1);
    expect(hostBuilds, greaterThan(initialHostBuilds));
    expect(keyBuilds, greaterThan(initialKeyBuilds));
    expect(groupBuilds, greaterThan(initialGroupBuilds));
    expect(find.text('Migration import completed'), findsOneWidget);
  });
}
