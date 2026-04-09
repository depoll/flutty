// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';

void main() {
  late AppDatabase db;
  late HostRepository hostRepository;
  late KeyRepository keyRepository;
  late SecretEncryptionService encryptionService;
  late SecureTransferService transferService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    encryptionService = SecretEncryptionService.forTesting();
    hostRepository = HostRepository(db, encryptionService);
    keyRepository = KeyRepository(db, encryptionService);
    transferService = SecureTransferService(db, keyRepository, hostRepository);
  });

  tearDown(() async {
    await db.close();
  });

  group('SecureTransferService', () {
    test('encrypts and decrypts host payload roundtrip', () async {
      final snippetId = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: 'Attach tmux',
              command: 'tmux new -As MonkeySSH',
            ),
          );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Production',
              hostname: 'prod.example.com',
              username: 'root',
              password: const Value('secret'),
              autoConnectCommand: const Value('tmux new -As MonkeySSH'),
              autoConnectSnippetId: Value(snippetId),
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();

      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );
      final decrypted = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: '1234',
      );

      expect(decrypted.type, TransferPayloadType.host);
      final hostData = Map<String, dynamic>.from(decrypted.data['host'] as Map);
      expect(hostData['label'], 'Production');
      expect(hostData['hostname'], 'prod.example.com');
      expect(hostData['autoConnectCommand'], 'tmux new -As MonkeySSH');
      expect(hostData['autoConnectSnippetId'], isNull);
    });

    test(
      'includes referenced key data when requested for host export',
      () async {
        final keyId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Deploy Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA',
            privateKey: 'test-open-ssh-key-materialxyz',
          ),
        );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Production',
                hostname: 'prod.example.com',
                username: 'root',
                keyId: Value(keyId),
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((h) => h.id.equals(hostId))).getSingle();

        final encodedPayload = await transferService.createHostPayload(
          host: host,
          transferPassphrase: '1234',
          includeReferencedKey: true,
        );
        final decrypted = await transferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: '1234',
        );

        final hostData = Map<String, dynamic>.from(
          decrypted.data['host'] as Map,
        );
        final referencedKey = decrypted.data['referencedKey'];
        expect(hostData['keyId'], keyId);
        expect(referencedKey, isA<Map>());
        expect((referencedKey as Map)['name'], 'Deploy Key');
      },
    );

    test(
      'importKeyPayload encrypts imported private material at rest',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.key,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'key': {
              'name': 'Imported Key',
              'keyType': 'ed25519',
              'publicKey': 'ssh-ed25519 AAAA',
              'privateKey': 'test-open-ssh-key-materialabc',
              'passphrase': 'pass',
            },
          },
        );

        final imported = await transferService.importKeyPayload(payload);
        expect(imported.privateKey, 'test-open-ssh-key-materialabc');
        expect(imported.passphrase, 'pass');

        final stored = await (db.select(
          db.sshKeys,
        )..where((k) => k.id.equals(imported.id))).getSingle();
        expect(stored.privateKey, startsWith('ENCv1:'));
        expect(stored.passphrase, startsWith('ENCv1:'));
      },
    );

    test('importHostPayload encrypts imported password at rest', () async {
      final payload = TransferPayload(
        type: TransferPayloadType.host,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'host': {
            'label': 'Imported Host',
            'hostname': 'imported.example.com',
            'port': 22,
            'username': 'root',
            'password': 'host-pass',
            'isFavorite': false,
          },
        },
      );

      final imported = await transferService.importHostPayload(payload);
      expect(imported.password, 'host-pass');
      expect(imported.autoConnectRequiresConfirmation, isFalse);

      final stored = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(imported.id))).getSingle();
      expect(stored.password, startsWith('ENCv1:'));
    });

    test(
      'marks imported auto-connect commands for review before first run',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.host,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'host': {
              'label': 'Imported Host',
              'hostname': 'imported.example.com',
              'port': 22,
              'username': 'root',
              'autoConnectCommand': '  tmux attach  ',
            },
          },
        );

        final imported = await transferService.importHostPayload(payload);

        expect(imported.autoConnectCommand, 'tmux attach');
        expect(imported.autoConnectRequiresConfirmation, isTrue);
      },
    );

    test(
      'rejects imported auto-connect commands with hidden control characters',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.host,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'host': {
              'label': 'Imported Host',
              'hostname': 'imported.example.com',
              'port': 22,
              'username': 'root',
              'autoConnectCommand': 'tmux attach\x00rm -rf /',
            },
          },
        );

        await expectLater(
          transferService.importHostPayload(payload),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects imported auto-connect snippets with hidden control characters',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.fullMigration,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'snippets': [
              {'id': 5, 'name': 'Auto connect', 'command': 'printf "ok"\x00'},
            ],
            'hosts': [
              {
                'id': 1,
                'label': 'Imported Host',
                'hostname': 'imported.example.com',
                'port': 22,
                'username': 'root',
                'autoConnectSnippetId': 5,
              },
            ],
          },
        );

        await expectLater(
          transferService.importFullMigrationPayload(
            payload: payload,
            mode: MigrationImportMode.merge,
          ),
          throwsFormatException,
        );
      },
    );

    test('rejects invalid passphrase', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Host',
              hostname: 'example.com',
              username: 'user',
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();
      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: 'correct',
      );

      await expectLater(
        transferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: 'wrong',
        ),
        throwsFormatException,
      );
    });

    test('rejects envelope with invalid component lengths', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Host',
              hostname: 'example.com',
              username: 'user',
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();
      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );

      final compact = encodedPayload.substring('MSSH1:'.length);
      final envelope = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(compact))))
            as Map,
      );
      envelope['salt'] = base64Url.encode(const [1, 2, 3]);
      final tampered =
          'MSSH1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';

      await expectLater(
        transferService.decryptPayload(
          encodedPayload: tampered,
          transferPassphrase: '1234',
        ),
        throwsFormatException,
      );
    });

    test('rejects envelope with non-string encoded components', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Host',
              hostname: 'example.com',
              username: 'user',
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();
      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );

      final compact = encodedPayload.substring('MSSH1:'.length);
      final envelope = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(compact))))
            as Map,
      );
      envelope['salt'] = 42;
      final tampered =
          'MSSH1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';

      await expectLater(
        transferService.decryptPayload(
          encodedPayload: tampered,
          transferPassphrase: '1234',
        ),
        throwsFormatException,
      );
    });

    test('rejects envelope with invalid iteration count', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Host',
              hostname: 'example.com',
              username: 'user',
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();
      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );

      final compact = encodedPayload.substring('MSSH1:'.length);
      final envelope = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(compact))))
            as Map,
      );
      envelope['iter'] = 0;
      final tampered =
          'MSSH1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';

      await expectLater(
        transferService.decryptPayload(
          encodedPayload: tampered,
          transferPassphrase: '1234',
        ),
        throwsFormatException,
      );
    });

    test('rejects envelope with excessive iteration count', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Host',
              hostname: 'example.com',
              username: 'user',
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();
      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );

      final compact = encodedPayload.substring('MSSH1:'.length);
      final envelope = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(compact))))
            as Map,
      );
      envelope['iter'] = 1000001;
      final tampered =
          'MSSH1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';

      await expectLater(
        transferService.decryptPayload(
          encodedPayload: tampered,
          transferPassphrase: '1234',
        ),
        throwsFormatException,
      );
    });

    test('fails migration when host references missing key mapping', () async {
      final payload = TransferPayload(
        type: TransferPayloadType.fullMigration,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'keys': <Map<String, dynamic>>[],
          'groups': <Map<String, dynamic>>[],
          'hosts': [
            {
              'id': 1,
              'label': 'Host',
              'hostname': 'example.com',
              'username': 'root',
              'keyId': 999,
            },
          ],
        },
      );

      await expectLater(
        transferService.importFullMigrationPayload(
          payload: payload,
          mode: MigrationImportMode.merge,
        ),
        throwsFormatException,
      );
    });

    test(
      'fails migration when port forward references missing host mapping',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.fullMigration,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'hosts': <Map<String, dynamic>>[],
            'portForwards': [
              {
                'name': 'pf',
                'hostId': 999,
                'forwardType': 'local',
                'localPort': 10022,
                'remoteHost': '127.0.0.1',
                'remotePort': 22,
              },
            ],
          },
        );

        await expectLater(
          transferService.importFullMigrationPayload(
            payload: payload,
            mode: MigrationImportMode.merge,
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'imports full migration in replace mode with self references',
      () async {
        final parentGroupId = await db
            .into(db.groups)
            .insert(GroupsCompanion.insert(name: 'Parent Group'));
        final childGroupId = await db
            .into(db.groups)
            .insert(
              GroupsCompanion.insert(
                name: 'Child Group',
                parentId: Value(parentGroupId),
              ),
            );
        final keyId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Main Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA',
            privateKey: 'test-open-ssh-key-materialabc',
          ),
        );

        final hostAId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'A',
                hostname: 'a.example.com',
                username: 'root',
                keyId: Value(keyId),
                groupId: Value(childGroupId),
              ),
            );
        await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'B',
                hostname: 'b.example.com',
                username: 'root',
                jumpHostId: Value(hostAId),
              ),
            );

        final parentSnippetFolderId = await db
            .into(db.snippetFolders)
            .insert(SnippetFoldersCompanion.insert(name: 'Parent Folder'));
        final childSnippetFolderId = await db
            .into(db.snippetFolders)
            .insert(
              SnippetFoldersCompanion.insert(
                name: 'Child Folder',
                parentId: Value(parentSnippetFolderId),
              ),
            );
        final snippetId = await db
            .into(db.snippets)
            .insert(
              SnippetsCompanion.insert(
                name: 'List files',
                command: 'ls -la',
                folderId: Value(childSnippetFolderId),
              ),
            );
        await (db.update(
          db.hosts,
        )..where((tbl) => tbl.id.equals(hostAId))).write(
          HostsCompanion(
            autoConnectCommand: const Value('ls -la'),
            autoConnectSnippetId: Value(snippetId),
          ),
        );
        await db
            .into(db.portForwards)
            .insert(
              PortForwardsCompanion.insert(
                name: 'pf',
                hostId: hostAId,
                forwardType: 'local',
                localPort: 10022,
                remoteHost: '127.0.0.1',
                remotePort: 22,
              ),
            );
        await db
            .into(db.knownHosts)
            .insert(
              KnownHostsCompanion.insert(
                hostname: 'example.com',
                port: 22,
                keyType: 'ssh-ed25519',
                fingerprint: 'abc',
                hostKey: 'ssh-ed25519 AAAA',
              ),
            );
        await db
            .into(db.settings)
            .insert(SettingsCompanion.insert(key: 'theme_mode', value: 'dark'));

        final migrationPayload = await transferService
            .createFullMigrationPayload(transferPassphrase: '1234');

        await db
            .into(db.settings)
            .insertOnConflictUpdate(
              SettingsCompanion.insert(key: 'extra', value: '1'),
            );

        final decrypted = await transferService.decryptPayload(
          encodedPayload: migrationPayload,
          transferPassphrase: '1234',
        );
        await transferService.importFullMigrationPayload(
          payload: decrypted,
          mode: MigrationImportMode.replace,
        );

        final extraSetting = await (db.select(
          db.settings,
        )..where((s) => s.key.equals('extra'))).getSingleOrNull();
        final hosts = await db.select(db.hosts).get();
        final hostA = hosts.firstWhere((host) => host.label == 'A');
        final importedSnippet = await (db.select(
          db.snippets,
        )..where((snippet) => snippet.name.equals('List files'))).getSingle();
        final groups = await db.select(db.groups).get();
        final snippetFolders = await db.select(db.snippetFolders).get();
        final portForwards = await db.select(db.portForwards).get();

        expect(extraSetting, isNull);
        expect(hosts, hasLength(2));
        expect(hostA.autoConnectCommand, 'ls -la');
        expect(hostA.autoConnectSnippetId, importedSnippet.id);
        expect(hostA.autoConnectRequiresConfirmation, isTrue);
        expect(groups, hasLength(2));
        expect(snippetFolders, hasLength(2));
        expect(portForwards, hasLength(1));
      },
    );

    test(
      'imports full migration in merge mode and preserves extra data',
      () async {
        await db
            .into(db.settings)
            .insert(SettingsCompanion.insert(key: 'theme_mode', value: 'dark'));

        final migrationPayload = await transferService
            .createFullMigrationPayload(transferPassphrase: '1234');

        await db
            .into(db.settings)
            .insertOnConflictUpdate(
              SettingsCompanion.insert(key: 'extra', value: '1'),
            );

        final decrypted = await transferService.decryptPayload(
          encodedPayload: migrationPayload,
          transferPassphrase: '1234',
        );
        await transferService.importFullMigrationPayload(
          payload: decrypted,
          mode: MigrationImportMode.merge,
        );

        final extraSetting = await (db.select(
          db.settings,
        )..where((s) => s.key.equals('extra'))).getSingleOrNull();
        final themeSetting = await (db.select(
          db.settings,
        )..where((s) => s.key.equals('theme_mode'))).getSingleOrNull();

        expect(extraSetting, isNot(equals(null)));
        expect(themeSetting?.value, 'dark');
      },
    );

    test(
      'importMigrationData preserves epoch-millisecond host timestamps',
      () async {
        final createdAt = DateTime.utc(2026, 4, 9, 4);
        final updatedAt = DateTime.utc(2026, 4, 9, 4, 0, 5);
        await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Timestamped Host',
            hostname: 'timestamps.example.com',
            username: 'root',
            createdAt: Value(createdAt),
            updatedAt: Value(updatedAt),
          ),
        );

        final migrationData = await transferService.createMigrationData(
          includeKnownHosts: false,
        );

        final importedDb = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(importedDb.close);
        final importedEncryptionService = SecretEncryptionService.forTesting();
        final importedTransferService = SecureTransferService(
          importedDb,
          KeyRepository(importedDb, importedEncryptionService),
          HostRepository(importedDb, importedEncryptionService),
        );

        await importedTransferService.importMigrationData(
          data: migrationData,
          mode: MigrationImportMode.replace,
          includeKnownHosts: false,
        );

        final importedHost = await importedDb
            .select(importedDb.hosts)
            .getSingle();
        expect(importedHost.createdAt.toUtc(), createdAt);
        expect(importedHost.updatedAt.toUtc(), updatedAt);
      },
    );

    test(
      'merge import replaces an older known-host entry with newer trust data',
      () async {
        final existingFirstSeen = DateTime.utc(2024);
        final existingLastSeen = DateTime.utc(2024, 1, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        final importedFirstSeen = DateTime.utc(2024, 2);
        final importedLastSeen = DateTime.utc(2024, 2, 2);
        final importedKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [9, 8, 7, 6],
          firstSeen: importedFirstSeen,
          lastSeen: importedLastSeen,
        );

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [importedKnownHost.toJson()],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.hostKey, importedKnownHost.hostKey);
        expect(storedKnownHost.fingerprint, importedKnownHost.fingerprint);
        expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
      },
    );

    test(
      'merge import preserves a newer local known-host entry when import is older',
      () async {
        final existingFirstSeen = DateTime.utc(2024, 2);
        final existingLastSeen = DateTime.utc(2024, 2, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [9, 8, 7, 6],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        final importedKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: DateTime.utc(2024),
          lastSeen: DateTime.utc(2024, 1, 2),
        );

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [importedKnownHost.toJson()],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.hostKey, existingKnownHost.hostKey);
        expect(storedKnownHost.fingerprint, existingKnownHost.fingerprint);
        expect(storedKnownHost.firstSeen.toUtc(), existingFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), existingLastSeen);
      },
    );

    test('imports fingerprint-only legacy known-host rows', () async {
      const importedFingerprint = 'SHA256:legacyFingerprintOnlyRow';
      final importedFirstSeen = DateTime.utc(2024, 3);
      final importedLastSeen = DateTime.utc(2024, 3, 2);

      await transferService.importFullMigrationPayload(
        payload: TransferPayload(
          type: TransferPayloadType.fullMigration,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'knownHosts': [
              {
                'hostname': 'legacy.example.com',
                'port': 2222,
                'keyType': 'ssh-ed25519',
                'fingerprint': importedFingerprint,
                'hostKey': '',
                'firstSeen': importedFirstSeen.toIso8601String(),
                'lastSeen': importedLastSeen.toIso8601String(),
              },
            ],
          },
        ),
        mode: MigrationImportMode.merge,
      );

      final storedKnownHost =
          await (db.select(db.knownHosts)..where(
                (knownHost) => knownHost.hostname.equals('legacy.example.com'),
              ))
              .getSingle();
      expect(storedKnownHost.port, 2222);
      expect(storedKnownHost.keyType, 'ssh-ed25519');
      expect(storedKnownHost.fingerprint, importedFingerprint);
      expect(storedKnownHost.hostKey, isEmpty);
      expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
      expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
    });

    test(
      'merge import falls back to fingerprint-only trust for malformed host keys',
      () async {
        final existingFirstSeen = DateTime.utc(2024);
        final existingLastSeen = DateTime.utc(2024, 1, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        const importedFingerprint = 'SHA256:malformedImportedHostKey';
        final importedFirstSeen = DateTime.utc(2024, 2);
        final importedLastSeen = DateTime.utc(2024, 2, 2);

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [
                {
                  'hostname': 'shared.example.com',
                  'port': 22,
                  'keyType': 'ssh-ed25519',
                  'fingerprint': importedFingerprint,
                  'hostKey': 'not base64',
                  'firstSeen': importedFirstSeen.toIso8601String(),
                  'lastSeen': importedLastSeen.toIso8601String(),
                },
              ],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.keyType, 'ssh-ed25519');
        expect(storedKnownHost.fingerprint, importedFingerprint);
        expect(storedKnownHost.hostKey, isEmpty);
        expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
      },
    );

    test(
      'merge import falls back to fingerprint-only trust for non-host-key base64 blobs',
      () async {
        final existingFirstSeen = DateTime.utc(2024);
        final existingLastSeen = DateTime.utc(2024, 1, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        const importedFingerprint = 'SHA256:decodableButNotHostKey';
        final importedFirstSeen = DateTime.utc(2024, 2);
        final importedLastSeen = DateTime.utc(2024, 2, 2);

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [
                {
                  'hostname': 'shared.example.com',
                  'port': 22,
                  'keyType': 'ssh-ed25519',
                  'fingerprint': importedFingerprint,
                  'hostKey': base64.encode(utf8.encode('not-an-ssh-host-key')),
                  'firstSeen': importedFirstSeen.toIso8601String(),
                  'lastSeen': importedLastSeen.toIso8601String(),
                },
              ],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.keyType, 'ssh-ed25519');
        expect(storedKnownHost.fingerprint, importedFingerprint);
        expect(storedKnownHost.hostKey, isEmpty);
        expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
      },
    );

    test('encrypts and imports key payload roundtrip', () async {
      final keyId = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Deploy Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAA',
              privateKey: 'test-open-ssh-key-materialxyz',
              passphrase: const Value('key-passphrase'),
            ),
          );
      final key = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(keyId))).getSingle();

      final encodedPayload = await transferService.createKeyPayload(
        key: key,
        transferPassphrase: '1234',
      );

      await db.delete(db.sshKeys).go();

      final decrypted = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: '1234',
      );
      final importedKey = await transferService.importKeyPayload(decrypted);

      expect(importedKey.name, 'Deploy Key');
      expect(importedKey.privateKey, contains('test-open-ssh-key-material'));
      expect(importedKey.passphrase, 'key-passphrase');
    });

    test(
      'importKeyPayload deduplicates by fingerprint and returns the existing key',
      () async {
        const fingerprint = 'SHA256:DE:AD:BE:EF:00:11:22:33';
        final existingId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Existing Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAAexisting',
            privateKey: 'test-open-ssh-key-existing',
            fingerprint: const Value(fingerprint),
          ),
        );

        // Import a payload that shares the same fingerprint.
        final payload = TransferPayload(
          type: TransferPayloadType.key,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'key': {
              'name': 'Re-imported Key',
              'keyType': 'ed25519',
              'publicKey': 'ssh-ed25519 AAAAdifferent',
              'privateKey': 'test-open-ssh-key-different',
              'fingerprint': fingerprint,
            },
          },
        );

        final imported = await transferService.importKeyPayload(payload);

        // Should return the existing key, not create a new one.
        expect(imported.id, existingId);
        expect(imported.name, 'Existing Key');

        final allKeys = await db.select(db.sshKeys).get();
        expect(allKeys, hasLength(1));
      },
    );

    test('importKeyPayload deduplicates by public+private key pair when no '
        'fingerprint is present', () async {
      const publicKey = 'ssh-ed25519 AAAAsharedpubkey';
      const privateKey = 'test-open-ssh-key-sharedprivkey';

      final existingId = await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Existing Key',
          keyType: 'ed25519',
          publicKey: publicKey,
          privateKey: privateKey,
        ),
      );

      final payload = TransferPayload(
        type: TransferPayloadType.key,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'key': {
            'name': 'Duplicate Key',
            'keyType': 'ed25519',
            'publicKey': publicKey,
            'privateKey': privateKey,
          },
        },
      );

      final imported = await transferService.importKeyPayload(payload);

      expect(imported.id, existingId);

      final allKeys = await db.select(db.sshKeys).get();
      expect(allKeys, hasLength(1));
    });

    test('importKeyPayload inserts a new key when neither fingerprint nor '
        'key material matches an existing entry', () async {
      await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Unrelated Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAAunrelated',
          privateKey: 'test-open-ssh-key-unrelated',
          fingerprint: const Value('SHA256:un:re:la:te:d0'),
        ),
      );

      final payload = TransferPayload(
        type: TransferPayloadType.key,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'key': {
            'name': 'Brand New Key',
            'keyType': 'ed25519',
            'publicKey': 'ssh-ed25519 AAAAnewkey',
            'privateKey': 'test-open-ssh-key-newkey',
            'fingerprint': 'SHA256:ne:wk:ey:00:01',
          },
        },
      );

      final imported = await transferService.importKeyPayload(payload);

      expect(imported.name, 'Brand New Key');

      final allKeys = await db.select(db.sshKeys).get();
      expect(allKeys, hasLength(2));
    });

    test(
      'rejects invalid auto-connect snippet reference in migration',
      () async {
        final snippetId = await db
            .into(db.snippets)
            .insert(
              SnippetsCompanion.insert(name: 'List files', command: 'ls -la'),
            );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'A',
                hostname: 'a.example.com',
                username: 'root',
                autoConnectCommand: const Value('ls -la'),
                autoConnectSnippetId: Value(snippetId),
              ),
            );

        final migrationPayload = await transferService
            .createFullMigrationPayload(transferPassphrase: '1234');
        final decrypted = await transferService.decryptPayload(
          encodedPayload: migrationPayload,
          transferPassphrase: '1234',
        );

        final rawHosts = List<Map<String, dynamic>>.from(
          (decrypted.data['hosts'] as List).cast<Map>(),
        );
        final hostIndex = rawHosts.indexWhere((host) => host['id'] == hostId);
        rawHosts[hostIndex] = {
          ...rawHosts[hostIndex],
          'autoConnectSnippetId': snippetId + 999,
        };

        final tamperedPayload = TransferPayload(
          type: decrypted.type,
          schemaVersion: decrypted.schemaVersion,
          createdAt: decrypted.createdAt,
          data: {...decrypted.data, 'hosts': rawHosts},
        );

        await expectLater(
          transferService.importFullMigrationPayload(
            payload: tamperedPayload,
            mode: MigrationImportMode.merge,
          ),
          throwsFormatException,
        );
      },
    );
  });
}

_KnownHostFixture _knownHostRecord({
  required String hostname,
  required List<int> keyData,
  required DateTime firstSeen,
  required DateTime lastSeen,
  int port = 22,
  String keyType = 'ssh-ed25519',
}) {
  final hostKeyBytes = _ed25519HostKeyBlob(keyData);
  final hostKey = base64.encode(hostKeyBytes);
  return _KnownHostFixture(
    hostname: hostname,
    port: port,
    keyType: keyType,
    fingerprint: formatSshHostKeyFingerprint(hostKeyBytes),
    hostKey: hostKey,
    firstSeen: firstSeen,
    lastSeen: lastSeen,
  );
}

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final writer = BytesBuilder(copy: false)
    ..add(_sshString(utf8.encode('ssh-ed25519')))
    ..add(_sshString(keyData));
  return writer.takeBytes();
}

Uint8List _sshString(List<int> bytes) =>
    Uint8List.fromList([..._uint32(bytes.length), ...bytes]);

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

class _KnownHostFixture {
  const _KnownHostFixture({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.hostKey,
    required this.firstSeen,
    required this.lastSeen,
  });

  final String hostname;
  final int port;
  final String keyType;
  final String fingerprint;
  final String hostKey;
  final DateTime firstSeen;
  final DateTime lastSeen;

  KnownHostsCompanion toCompanion() => KnownHostsCompanion.insert(
    hostname: hostname,
    port: port,
    keyType: keyType,
    fingerprint: fingerprint,
    hostKey: hostKey,
    firstSeen: Value(firstSeen),
    lastSeen: Value(lastSeen),
  );

  Map<String, dynamic> toJson() => {
    'hostname': hostname,
    'port': port,
    'keyType': keyType,
    'fingerprint': fingerprint,
    'hostKey': hostKey,
    'firstSeen': firstSeen.toIso8601String(),
    'lastSeen': lastSeen.toIso8601String(),
  };
}
