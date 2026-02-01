// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';

void main() {
  late AppDatabase db;
  late KeyRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = KeyRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('KeyRepository', () {
    test('getAll returns empty list initially', () async {
      final keys = await repository.getAll();
      expect(keys, isEmpty);
    });

    test('insert creates a new key', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'My Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        ),
      );

      expect(id, greaterThan(0));

      final keys = await repository.getAll();
      expect(keys, hasLength(1));
      expect(keys.first.name, 'My Key');
      expect(keys.first.keyType, 'ed25519');
    });

    test('getById returns key when exists', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'Test Key',
          keyType: 'rsa',
          publicKey: 'ssh-rsa AAAA...',
          privateKey: '-----BEGIN RSA PRIVATE KEY-----...',
        ),
      );

      final key = await repository.getById(id);

      expect(key, isNotNull);
      expect(key!.id, id);
      expect(key.name, 'Test Key');
      expect(key.keyType, 'rsa');
    });

    test('getById returns null when not exists', () async {
      final key = await repository.getById(999);
      expect(key, isNull);
    });

    test('update modifies existing key', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'Original Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        ),
      );

      final key = await repository.getById(id);
      final success = await repository.update(
        key!.copyWith(name: 'Updated Key'),
      );

      expect(success, isTrue);

      final updated = await repository.getById(id);
      expect(updated!.name, 'Updated Key');
    });

    test('delete removes key', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'To Delete',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        ),
      );

      final deleted = await repository.delete(id);
      expect(deleted, 1);

      final key = await repository.getById(id);
      expect(key, isNull);
    });

    test('delete returns 0 when key not exists', () async {
      final deleted = await repository.delete(999);
      expect(deleted, 0);
    });

    test('search finds keys by name', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Production Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA1...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----1...',
        ),
      );
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Development Key',
          keyType: 'rsa',
          publicKey: 'ssh-rsa AAAA2...',
          privateKey: '-----BEGIN RSA PRIVATE KEY-----2...',
        ),
      );

      final results = await repository.search('Production');
      expect(results, hasLength(1));
      expect(results.first.name, 'Production Key');
    });

    test('search returns empty when no match', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Test Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        ),
      );

      final results = await repository.search('NonExistent');
      expect(results, isEmpty);
    });

    test('search is case insensitive with LIKE', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'My Server Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        ),
      );

      final results = await repository.search('server');
      expect(results, hasLength(1));
    });

    test('watchAll emits updates when keys change', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'New Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        ),
      );

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('insert multiple keys', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key 1',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA1...',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----1...',
        ),
      );
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key 2',
          keyType: 'rsa',
          publicKey: 'ssh-rsa AAAA2...',
          privateKey: '-----BEGIN RSA PRIVATE KEY-----2...',
        ),
      );
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key 3',
          keyType: 'ecdsa',
          publicKey: 'ecdsa-sha2-nistp256 AAAA3...',
          privateKey: '-----BEGIN EC PRIVATE KEY-----3...',
        ),
      );

      final keys = await repository.getAll();
      expect(keys, hasLength(3));
    });

    test('update returns false when key not exists', () async {
      final fakeKey = SshKey(
        id: 999,
        name: 'Fake Key',
        keyType: 'ed25519',
        publicKey: 'ssh-ed25519 AAAA...',
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
        createdAt: DateTime.now(),
      );

      final success = await repository.update(fakeKey);
      expect(success, isFalse);
    });
  });
}
