// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/sync_vault_document_service.dart';
import 'package:monkeyssh/domain/services/sync_vault_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../support/settings_import_test_helpers.dart';

class _MockSyncVaultService extends Mock implements SyncVaultService {}

void main() {
  group('SettingsScreen', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'MonkeySSH',
        packageName: 'xyz.depollsoft.monkeyssh',
        version: '0.1.1',
        buildNumber: '123',
        buildSignature: '',
      );
    });

    testWidgets('displays all sections', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Sync'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Terminal'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Terminal'), findsOneWidget);

      // Scroll to find About section
      await tester.scrollUntilVisible(
        find.text('About'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('displays theme option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System default'), findsOneWidget);
    });

    testWidgets('displays font size option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Font size'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Font size'), findsOneWidget);
      expect(find.text('14 pt'), findsOneWidget);
    });

    testWidgets('displays font family option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Font family'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Font family'), findsOneWidget);
      expect(find.text('System Monospace'), findsOneWidget);
    });

    testWidgets('displays cursor style option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Cursor style'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Cursor style'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
    });

    testWidgets('displays bell sound toggle', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Bell sound'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Bell sound'), findsOneWidget);
      expect(find.text('Play sound on terminal bell'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('displays terminal path link toggles', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Clickable file paths'), findsOneWidget);
      expect(
        find.text('Tap terminal file paths to open them in SFTP'),
        findsOneWidget,
      );
      expect(find.text('Path link underlines'), findsOneWidget);
      expect(
        find.text('Underline clickable terminal file paths'),
        findsOneWidget,
      );
    });

    testWidgets('displays about section with version', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      // Scroll to find About section
      await tester.scrollUntilVisible(
        find.text('App version'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('App version'), findsOneWidget);
      expect(find.text('0.1.1 (123)'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Licenses'), findsOneWidget);
    });

    testWidgets('displays preview metadata when available', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appMetadataProvider.overrideWith(
              (ref) async => const AppMetadata(
                version: '0.1.1',
                buildNumber: '123',
                pullRequestNumber: '175',
                pullRequestTitle: 'Show PR metadata in settings',
              ),
            ),
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Preview build'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Preview build'), findsOneWidget);
      expect(
        find.text('PR #175: Show PR metadata in settings'),
        findsOneWidget,
      );
    });

    testWidgets('displays security options', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Change PIN'), findsOneWidget);
      expect(find.text('Biometric authentication'), findsOneWidget);
      expect(find.text('Auto-lock timeout'), findsOneWidget);
    });

    testWidgets('displays encrypted sync setup actions', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Create encrypted sync vault'), findsOneWidget);
      expect(find.text('Connect to existing vault'), findsOneWidget);
    });

    testWidgets('shows a QR code when displaying the recovery key', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final syncVaultService = _MockSyncVaultService();
      addTearDown(db.close);
      when(
        syncVaultService.getRecoveryKey,
      ).thenAnswer((_) async => 'RECOVERY-KEY-1234');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultServiceProvider.overrideWithValue(syncVaultService),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: true, hasRecoveryKey: true),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Show recovery key'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final showRecoveryKeyTile = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .firstWhere(
            (tile) => (tile.title as Text?)?.data == 'Show recovery key',
          );
      showRecoveryKeyTile.onTap?.call();
      await tester.pumpAndSettle();

      expect(find.text('Sync recovery key'), findsOneWidget);
      expect(find.text('RECOVERY-KEY-1234'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('offers QR scanning when connecting an existing vault on iOS', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        final documentService = FakeSyncVaultDocumentService(
          pickedDocument: const PickedSyncVaultDocument(
            contents: 'encrypted-vault',
            path: '/provider/vault.monkeysync',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              authServiceProvider.overrideWithValue(FakeAuthService()),
              authStateProvider.overrideWith(MockAuthStateNotifier.new),
              syncVaultDocumentServiceProvider.overrideWithValue(
                documentService,
              ),
              syncVaultStatusProvider.overrideWith(
                (ref) async => const SyncVaultStatus(
                  enabled: false,
                  hasRecoveryKey: false,
                ),
              ),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );

        await tester.pumpAndSettle();

        final connectVaultTile = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .firstWhere(
              (tile) =>
                  (tile.title as Text?)?.data == 'Connect to existing vault',
            );
        connectVaultTile.onTap?.call();
        await tester.pumpAndSettle();

        expect(find.text('Enter recovery key'), findsOneWidget);
        expect(find.text('Scan QR code'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('shows generic encrypted sync status error message', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) => Future<SyncVaultStatus>.error(StateError('boom')),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.text('Could not load sync status. Try reopening Settings.'),
        findsOneWidget,
      );
      expect(find.textContaining('boom'), findsNothing);
    });

    testWidgets('has scrollable ListView', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            syncVaultStatusProvider.overrideWith(
              (ref) async =>
                  const SyncVaultStatus(enabled: false, hasRecoveryKey: false),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('import migration invalidates shared entity providers', (
      tester,
    ) async {
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
            fontFamilyNotifierProvider.overrideWith(
              StaticFontFamilyNotifier.new,
            ),
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

      final importMigrationFinder = find.text('Import migration package');
      await tester.scrollUntilVisible(
        importMigrationFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final importTile = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .firstWhere(
            (tile) => (tile.title as Text?)?.data == 'Import migration package',
          );
      importTile.onTap?.call();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, '1234');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      expect(transferService.importCallCount, 1);
      expect(hostBuilds, greaterThan(initialHostBuilds));
      expect(keyBuilds, greaterThan(initialKeyBuilds));
      expect(groupBuilds, greaterThan(initialGroupBuilds));
    });
  });
}
