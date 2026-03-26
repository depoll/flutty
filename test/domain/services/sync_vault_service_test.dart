// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/sync_vault_service.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  group('SyncVaultService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('monkeyssh-sync-vault');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'downloads remote vault into another device and excludes device-local data',
      () async {
        final deviceA = await _createFixture();
        final deviceB = await _createFixture();
        addTearDown(deviceA.close);
        addTearDown(deviceB.close);

        await deviceA.settings.setString(SettingKeys.themeMode, 'dark');
        await deviceA.settings.setInt(SettingKeys.autoLockTimeout, 30);
        await deviceA.db
            .into(deviceA.db.knownHosts)
            .insert(
              KnownHostsCompanion.insert(
                hostname: 'prod.example.com',
                port: 22,
                keyType: 'ssh-ed25519',
                fingerprint: 'SHA256:test',
                hostKey: 'ssh-ed25519 AAAA',
              ),
            );
        await _insertHost(deviceA.hostRepository, label: 'Production');

        final provisioning = await deviceA.syncService.prepareNewVault();
        final vaultFile = File('${tempDir.path}/primary.monkeysync');
        await vaultFile.writeAsString(provisioning.encryptedVault, flush: true);
        await deviceA.syncService.enablePreparedVault(
          vaultPath: vaultFile.path,
          provisioning: provisioning,
        );

        expect(
          await deviceA.syncService.getRecoveryKey(),
          provisioning.recoveryKey,
        );

        await deviceB.syncService.linkExistingVault(
          vaultPath: vaultFile.path,
          encryptedVault: await vaultFile.readAsString(),
          recoveryKey: provisioning.recoveryKey,
        );
        final result = await deviceB.syncService.syncNow();

        expect(result.outcome, SyncVaultSyncOutcome.downloadedRemote);
        expect(
          (await deviceB.hostRepository.getAll()).map((host) => host.label),
          ['Production'],
        );
        expect(await deviceB.settings.getString(SettingKeys.themeMode), 'dark');
        expect(
          await deviceB.settings.getInt(SettingKeys.autoLockTimeout),
          isNull,
        );
        expect(await deviceB.db.select(deviceB.db.knownHosts).get(), isEmpty);
      },
    );

    test(
      'reports conflicts and can resolve them in favor of the vault',
      () async {
        final deviceA = await _createFixture();
        final deviceB = await _createFixture();
        addTearDown(deviceA.close);
        addTearDown(deviceB.close);

        await _insertHost(deviceA.hostRepository, label: 'Server A');
        final provisioning = await deviceA.syncService.prepareNewVault();
        final vaultFile = File('${tempDir.path}/shared.monkeysync');
        await vaultFile.writeAsString(provisioning.encryptedVault, flush: true);
        await deviceA.syncService.enablePreparedVault(
          vaultPath: vaultFile.path,
          provisioning: provisioning,
        );

        await deviceB.syncService.linkExistingVault(
          vaultPath: vaultFile.path,
          encryptedVault: await vaultFile.readAsString(),
          recoveryKey: provisioning.recoveryKey,
        );
        final initialDownload = await deviceB.syncService.syncNow();
        expect(initialDownload.outcome, SyncVaultSyncOutcome.downloadedRemote);

        await _insertHost(deviceA.hostRepository, label: 'Server A2');
        final uploadResult = await deviceA.syncService.syncNow();
        expect(uploadResult.outcome, SyncVaultSyncOutcome.uploadedLocal);

        await _insertHost(deviceB.hostRepository, label: 'Server B2');
        final conflict = await deviceB.syncService.syncNow();
        expect(conflict.outcome, SyncVaultSyncOutcome.conflict);
        expect(conflict.localPreview?.hostCount, 2);
        expect(conflict.remotePreview?.hostCount, 2);

        final resolved = await deviceB.syncService.syncNow(
          resolution: SyncVaultConflictResolution.downloadRemote,
        );
        expect(resolved.outcome, SyncVaultSyncOutcome.downloadedRemote);

        final labels = (await deviceB.hostRepository.getAll())
            .map((host) => host.label)
            .toSet();
        expect(labels, {'Server A', 'Server A2'});
      },
    );

    test(
      'does not report changes after downloading identical vault data',
      () async {
        final deviceA = await _createFixture();
        final deviceB = await _createFixture();
        addTearDown(deviceA.close);
        addTearDown(deviceB.close);

        await _insertHost(deviceA.hostRepository, label: 'Server A');
        final provisioning = await deviceA.syncService.prepareNewVault();
        final vaultFile = File('${tempDir.path}/no-churn.monkeysync');
        await vaultFile.writeAsString(provisioning.encryptedVault, flush: true);
        await deviceA.syncService.enablePreparedVault(
          vaultPath: vaultFile.path,
          provisioning: provisioning,
        );

        await deviceB.syncService.linkExistingVault(
          vaultPath: vaultFile.path,
          encryptedVault: await vaultFile.readAsString(),
          recoveryKey: provisioning.recoveryKey,
        );

        final initialDownload = await deviceB.syncService.syncNow();
        expect(initialDownload.outcome, SyncVaultSyncOutcome.downloadedRemote);

        final secondSync = await deviceB.syncService.syncNow();
        expect(secondSync.outcome, SyncVaultSyncOutcome.noChanges);
      },
    );
  });
}

Future<_SyncFixture> _createFixture() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final encryptionService = SecretEncryptionService.forTesting();
  final hostRepository = HostRepository(db, encryptionService);
  final keyRepository = KeyRepository(db, encryptionService);
  final settings = SettingsService(db);
  final transferService = SecureTransferService(
    db,
    keyRepository,
    hostRepository,
  );
  final storage = MockFlutterSecureStorage();
  final secureState = <String, String>{};

  when(() => storage.read(key: any(named: 'key'))).thenAnswer(
    (invocation) async =>
        secureState[invocation.namedArguments[#key] as String],
  );
  when(
    () => storage.write(
      key: any(named: 'key'),
      value: any(named: 'value'),
    ),
  ).thenAnswer((invocation) async {
    secureState[invocation.namedArguments[#key] as String] =
        invocation.namedArguments[#value] as String;
  });
  when(() => storage.delete(key: any(named: 'key'))).thenAnswer((
    invocation,
  ) async {
    secureState.remove(invocation.namedArguments[#key] as String);
  });

  return _SyncFixture(
    db: db,
    settings: settings,
    hostRepository: hostRepository,
    syncService: SyncVaultService(settings, transferService, storage: storage),
  );
}

Future<void> _insertHost(
  HostRepository repository, {
  required String label,
}) async {
  await repository.insert(
    HostsCompanion.insert(
      label: label,
      hostname: '${label.toLowerCase().replaceAll(' ', '-')}.example.com',
      username: 'root',
    ),
  );
}

class _SyncFixture {
  const _SyncFixture({
    required this.db,
    required this.settings,
    required this.hostRepository,
    required this.syncService,
  });

  final AppDatabase db;
  final SettingsService settings;
  final HostRepository hostRepository;
  final SyncVaultService syncService;

  Future<void> close() => db.close();
}
