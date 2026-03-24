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
    final transferService = _FakeSecureTransferService(
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

    FilePicker.platform = _FakeFilePicker(
      result: FilePickerResult([
        PlatformFile(
          name: 'migration.monkeysshx',
          size: 15,
          bytes: Uint8List.fromList(utf8.encode('encoded-payload')),
        ),
      ]),
    );
    addTearDown(() => FilePicker.platform = _FakeFilePicker(result: null));

    var hostBuilds = 0;
    var keyBuilds = 0;
    var groupBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authServiceProvider.overrideWithValue(_FakeAuthService()),
          authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          secureTransferServiceProvider.overrideWithValue(transferService),
          themeModeNotifierProvider.overrideWith(_StaticThemeModeNotifier.new),
          fontSizeNotifierProvider.overrideWith(_StaticFontSizeNotifier.new),
          fontFamilyNotifierProvider.overrideWith(
            _StaticFontFamilyNotifier.new,
          ),
          cursorStyleNotifierProvider.overrideWith(
            _StaticCursorStyleNotifier.new,
          ),
          bellSoundNotifierProvider.overrideWith(_StaticBellSoundNotifier.new),
          terminalThemeSettingsProvider.overrideWith(
            _StaticTerminalThemeSettingsNotifier.new,
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
          home: Stack(children: [SettingsScreen(), _EntityProviderProbe()]),
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

class _EntityProviderProbe extends ConsumerWidget {
  const _EntityProviderProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref
      ..watch(allHostsProvider)
      ..watch(allKeysProvider)
      ..watch(allGroupsProvider);
    return const SizedBox.shrink();
  }
}

class _MockAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.notConfigured;
}

class _FakeAuthService extends AuthService {
  @override
  Future<bool> isAuthEnabled() async => false;

  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<bool> isBiometricAvailable() async => false;
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker({required this.result});

  final FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => result;
}

class _FakeSecureTransferService extends SecureTransferService {
  _FakeSecureTransferService(
    super.db,
    super.keyRepository,
    super.hostRepository, {
    required this.payload,
  });

  final TransferPayload payload;
  int importCallCount = 0;

  @override
  Future<TransferPayload> decryptPayload({
    required String encodedPayload,
    required String transferPassphrase,
  }) async => payload;

  @override
  MigrationPreview previewMigrationPayload(TransferPayload payload) =>
      MigrationPreview(
        settingsCount: 0,
        hostCount: (payload.data['hosts'] as List).length,
        keyCount: (payload.data['keys'] as List).length,
        groupCount: (payload.data['groups'] as List).length,
        snippetCount: (payload.data['snippets'] as List).length,
        snippetFolderCount: (payload.data['snippetFolders'] as List).length,
        portForwardCount: (payload.data['portForwards'] as List).length,
        knownHostCount: (payload.data['knownHosts'] as List).length,
      );

  @override
  Future<void> importFullMigrationPayload({
    required TransferPayload payload,
    required MigrationImportMode mode,
  }) async {
    importCallCount += 1;
  }
}

class _StaticThemeModeNotifier extends ThemeModeNotifier {
  @override
  ThemeMode build() => ThemeMode.system;
}

class _StaticFontSizeNotifier extends FontSizeNotifier {
  @override
  double build() => 14;
}

class _StaticFontFamilyNotifier extends FontFamilyNotifier {
  @override
  String build() => 'System Monospace';
}

class _StaticCursorStyleNotifier extends CursorStyleNotifier {
  @override
  String build() => 'block';
}

class _StaticBellSoundNotifier extends BellSoundNotifier {
  @override
  bool build() => true;
}

class _StaticTerminalThemeSettingsNotifier
    extends TerminalThemeSettingsNotifier {
  @override
  TerminalThemeSettings build() => const TerminalThemeSettings(
    lightThemeId: 'github-light',
    darkThemeId: 'dracula',
  );
}
