// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/domain/services/key_service.dart';

void main() {
  late AppDatabase db;
  late KeyRepository keyRepository;
  late KeyService keyService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    keyRepository = KeyRepository(db);
    keyService = KeyService(keyRepository);
  });

  tearDown(() async {
    await db.close();
  });

  group('KeyService', () {
    group('SshKeyType enum', () {
      test('has expected values', () {
        expect(SshKeyType.values, hasLength(3));
        expect(SshKeyType.ed25519, isNotNull);
        expect(SshKeyType.rsa2048, isNotNull);
        expect(SshKeyType.rsa4096, isNotNull);
      });
    });

    group('getAllKeys', () {
      test('returns empty list initially', () async {
        final keys = await keyService.getAllKeys();
        expect(keys, isEmpty);
      });

      test('returns keys after insert', () async {
        await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Test Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final keys = await keyService.getAllKeys();
        expect(keys, hasLength(1));
      });
    });

    group('getById', () {
      test('returns key when exists', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'My Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final key = await keyService.getById(id);
        expect(key, isNotNull);
        expect(key!.name, 'My Key');
      });

      test('returns null when not exists', () async {
        final key = await keyService.getById(999);
        expect(key, isNull);
      });
    });

    group('deleteKey', () {
      test('deletes key', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'To Delete',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        await keyService.deleteKey(id);

        final key = await keyService.getById(id);
        expect(key, isNull);
      });
    });

    group('exportPublicKey', () {
      test('returns public key without comment', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Test',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final key = await keyService.getById(id);
        final exported = keyService.exportPublicKey(key!);
        expect(exported, 'ssh-ed25519 AAAA...');
      });

      test('returns public key with comment', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Test',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final key = await keyService.getById(id);
        final exported = keyService.exportPublicKey(key!, comment: 'user@host');
        expect(exported, 'ssh-ed25519 AAAA... user@host');
      });

      test('ignores empty comment', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Test',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final key = await keyService.getById(id);
        final exported = keyService.exportPublicKey(key!, comment: '');
        expect(exported, 'ssh-ed25519 AAAA...');
      });
    });

    group('exportPrivateKey', () {
      test('returns private key', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Test',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final key = await keyService.getById(id);
        final exported = keyService.exportPrivateKey(key!);
        expect(exported, '-----BEGIN OPENSSH PRIVATE KEY-----...');
      });
    });

    group('watchAllKeys', () {
      test('emits updates', () async {
        await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Watched Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
          ),
        );

        final stream = keyService.watchAllKeys();
        final firstValue = await stream.first;
        expect(firstValue, hasLength(1));
      });
    });

    group('validatePrivateKey', () {
      test('returns false for invalid PEM', () {
        final result = keyService.validatePrivateKey('not a valid key');
        expect(result, isFalse);
      });

      test('returns false for empty string', () {
        final result = keyService.validatePrivateKey('');
        expect(result, isFalse);
      });
    });

    group('importKey', () {
      test('returns null for invalid PEM', () async {
        final result = await keyService.importKey(
          name: 'Invalid Key',
          privateKeyPem: 'not a valid key',
        );
        expect(result, isNull);
      });
    });
  });
}
