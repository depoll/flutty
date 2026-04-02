// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
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
import 'package:monkeyssh/domain/services/sync_vault_file_io.dart';
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

    test(
      'treats duplicate-equivalent references as unchanged across devices',
      () async {
        final deviceA = await _createFixture();
        final deviceB = await _createFixture();
        addTearDown(deviceA.close);
        addTearDown(deviceB.close);

        final groupA1 = await _insertGroup(deviceA.db, name: 'Team');
        final groupA2 = await _insertGroup(deviceA.db, name: 'Team');
        await _insertHost(
          deviceA.hostRepository,
          label: 'Alpha',
          groupId: groupA1,
        );
        await _insertHost(
          deviceA.hostRepository,
          label: 'Beta',
          groupId: groupA2,
        );

        final groupB1 = await _insertGroup(deviceB.db, name: 'Team');
        final groupB2 = await _insertGroup(deviceB.db, name: 'Team');
        await _insertHost(
          deviceB.hostRepository,
          label: 'Alpha',
          groupId: groupB2,
        );
        await _insertHost(
          deviceB.hostRepository,
          label: 'Beta',
          groupId: groupB1,
        );

        final provisioning = await deviceA.syncService.prepareNewVault();
        final vaultFile = File('${tempDir.path}/duplicate-groups.monkeysync');
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

        final syncResult = await deviceB.syncService.syncNow();
        expect(syncResult.outcome, SyncVaultSyncOutcome.noChanges);
      },
    );

    test('keeps sync metadata inside the encrypted payload', () async {
      final device = await _createFixture();
      addTearDown(device.close);

      final provisioning = await device.syncService.prepareNewVault();
      final envelope = _decodeVaultEnvelope(provisioning.encryptedVault);

      for (final forbiddenKey in <String>[
        'checksum',
        'snapshotHash',
        'updatedAt',
        'updatedByDeviceId',
      ]) {
        expect(envelope.keys, isNot(contains(forbiddenKey)));
      }
    });

    test('rejects cyclic sync snapshot hierarchies', () async {
      final device = await _createFixture();
      addTearDown(device.close);

      final parentId = await _insertGroup(device.db, name: 'Parent');
      final childId = await _insertGroup(device.db, name: 'Child');
      await (device.db.update(device.db.groups)
            ..where((tbl) => tbl.id.equals(parentId)))
          .write(GroupsCompanion(parentId: Value(childId)));
      await (device.db.update(device.db.groups)
            ..where((tbl) => tbl.id.equals(childId)))
          .write(GroupsCompanion(parentId: Value(parentId)));

      await expectLater(
        device.syncService.prepareNewVault(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Invalid sync snapshot hierarchy',
          ),
        ),
      );
    });

    test(
      'requires relinking when the linked vault file is too large',
      () async {
        final device = await _createFixture();
        addTearDown(device.close);

        final provisioning = await device.syncService.prepareNewVault();
        final vaultFile = File('${tempDir.path}/oversized.monkeysync');
        await vaultFile.writeAsString(provisioning.encryptedVault, flush: true);
        await device.syncService.enablePreparedVault(
          vaultPath: vaultFile.path,
          provisioning: provisioning,
        );

        await vaultFile.writeAsString(
          'A' * (maxSyncVaultBytes + 1),
          flush: true,
        );

        final result = await device.syncService.syncNow();
        expect(result.outcome, SyncVaultSyncOutcome.needsRelink);
        expect(
          result.message,
          'The linked sync vault file is too large and needs to be relinked',
        );
      },
    );

    test(
      'treats malformed snapshot lists as an invalid vault payload',
      () async {
        final device = await _createFixture();
        addTearDown(device.close);

        final provisioning = await device.syncService.prepareNewVault();
        final malformedVault = await _encryptTestVault(
          recoveryKey: provisioning.recoveryKey,
          snapshot: {
            'schemaVersion': 1,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'updatedByDeviceId': 'device-a',
            'snapshotHash': 'placeholder-hash',
            'data': {
              'settings': <String, String>{},
              'groups': [123],
              'keys': <Map<String, dynamic>>[],
              'hosts': <Map<String, dynamic>>[],
              'snippetFolders': <Map<String, dynamic>>[],
              'snippets': <Map<String, dynamic>>[],
              'portForwards': <Map<String, dynamic>>[],
            },
          },
        );

        await expectLater(
          device.syncService.linkExistingVault(
            vaultPath: '${tempDir.path}/invalid.monkeysync',
            encryptedVault: malformedVault,
            recoveryKey: provisioning.recoveryKey,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid sync vault payload',
            ),
          ),
        );
      },
    );

    test(
      'treats malformed top-level snapshot collections as an invalid vault payload',
      () async {
        final device = await _createFixture();
        addTearDown(device.close);

        final provisioning = await device.syncService.prepareNewVault();
        final malformedVault = await _encryptTestVault(
          recoveryKey: provisioning.recoveryKey,
          snapshot: {
            'schemaVersion': 1,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'updatedByDeviceId': 'device-a',
            'snapshotHash': 'placeholder-hash',
            'data': {
              'settings': <String, String>{},
              'groups': 'not-a-list',
              'keys': <Map<String, dynamic>>[],
              'hosts': <Map<String, dynamic>>[],
              'snippetFolders': <Map<String, dynamic>>[],
              'snippets': <Map<String, dynamic>>[],
              'portForwards': <Map<String, dynamic>>[],
            },
          },
        );

        await expectLater(
          device.syncService.linkExistingVault(
            vaultPath: '${tempDir.path}/invalid-collections.monkeysync',
            encryptedVault: malformedVault,
            recoveryKey: provisioning.recoveryKey,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid sync vault payload',
            ),
          ),
        );
      },
    );

    test(
      'treats malformed top-level snapshot settings as an invalid vault payload',
      () async {
        final device = await _createFixture();
        addTearDown(device.close);

        final provisioning = await device.syncService.prepareNewVault();
        final malformedVault = await _encryptTestVault(
          recoveryKey: provisioning.recoveryKey,
          snapshot: {
            'schemaVersion': 1,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'updatedByDeviceId': 'device-a',
            'snapshotHash': 'placeholder-hash',
            'data': {
              'settings': 'not-a-map',
              'groups': <Map<String, dynamic>>[],
              'keys': <Map<String, dynamic>>[],
              'hosts': <Map<String, dynamic>>[],
              'snippetFolders': <Map<String, dynamic>>[],
              'snippets': <Map<String, dynamic>>[],
              'portForwards': <Map<String, dynamic>>[],
            },
          },
        );

        await expectLater(
          device.syncService.linkExistingVault(
            vaultPath: '${tempDir.path}/invalid-settings.monkeysync',
            encryptedVault: malformedVault,
            recoveryKey: provisioning.recoveryKey,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid sync vault payload',
            ),
          ),
        );
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
  int? groupId,
}) async {
  await repository.insert(
    HostsCompanion.insert(
      label: label,
      hostname: '${label.toLowerCase().replaceAll(' ', '-')}.example.com',
      username: 'root',
      groupId: Value(groupId),
    ),
  );
}

Future<int> _insertGroup(AppDatabase db, {required String name}) =>
    db.into(db.groups).insert(GroupsCompanion.insert(name: name));

Map<String, dynamic> _decodeVaultEnvelope(String encryptedVault) {
  final encodedEnvelope = encryptedVault.startsWith('MSYNC1:')
      ? encryptedVault.substring('MSYNC1:'.length)
      : encryptedVault;
  return Map<String, dynamic>.from(
    jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(encodedEnvelope))),
        )
        as Map,
  );
}

Future<String> _encryptTestVault({
  required String recoveryKey,
  required Map<String, dynamic> snapshot,
}) async {
  final normalizedRecoveryKey = recoveryKey.trim().toUpperCase();
  final recoveryHex = normalizedRecoveryKey
      .replaceFirst(RegExp('^MSYNC1-?'), '')
      .replaceAll('-', '');
  final recoverySeed = <int>[
    for (var i = 0; i < recoveryHex.length; i += 2)
      int.parse(recoveryHex.substring(i, i + 2), radix: 16),
  ];
  final payloadBytes = utf8.encode(jsonEncode(snapshot));
  final secretKey = SecretKey((await Sha256().hash(recoverySeed)).bytes);
  final algorithm = AesGcm.with256bits();
  final nonce = List<int>.generate(12, (index) => index + 1, growable: false);
  final encryptedBox = await algorithm.encrypt(
    payloadBytes,
    secretKey: secretKey,
    nonce: nonce,
  );
  final envelope = <String, dynamic>{
    'v': 1,
    'alg': 'AES-GCM-256',
    'nonce': base64Url.encode(nonce),
    'ciphertext': base64Url.encode(encryptedBox.cipherText),
    'mac': base64Url.encode(encryptedBox.mac.bytes),
  };
  return 'MSYNC1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
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
