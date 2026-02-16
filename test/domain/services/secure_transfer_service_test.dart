// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';

void main() {
  late AppDatabase db;
  late KeyRepository keyRepository;
  late SecureTransferService transferService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    keyRepository = KeyRepository(db);
    transferService = SecureTransferService(db, keyRepository);
  });

  tearDown(() async {
    await db.close();
  });

  group('SecureTransferService', () {
    test('encrypts and decrypts host payload roundtrip', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Production',
              hostname: 'prod.example.com',
              username: 'root',
              password: const Value('secret'),
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
    });

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
        final keyId = await db
            .into(db.sshKeys)
            .insert(
              SshKeysCompanion.insert(
                name: 'Main Key',
                keyType: 'ed25519',
                publicKey: 'ssh-ed25519 AAAA',
                privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----abc',
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
        await db
            .into(db.snippets)
            .insert(
              SnippetsCompanion.insert(
                name: 'List files',
                command: 'ls -la',
                folderId: Value(childSnippetFolderId),
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
        final groups = await db.select(db.groups).get();
        final snippetFolders = await db.select(db.snippetFolders).get();
        final portForwards = await db.select(db.portForwards).get();

        expect(extraSetting, isNull);
        expect(hosts, hasLength(2));
        expect(groups, hasLength(2));
        expect(snippetFolders, hasLength(2));
        expect(portForwards, hasLength(1));
      },
    );
  });
}
