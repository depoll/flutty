// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/key_service.dart';

void main() {
  late AppDatabase db;
  late KeyRepository keyRepository;
  late KeyService keyService;
  late SecretEncryptionService encryptionService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    encryptionService = SecretEncryptionService.forTesting();
    keyRepository = KeyRepository(db, encryptionService);
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
            privateKey: 'test-open-ssh-key-material...',
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
            privateKey: 'test-open-ssh-key-material...',
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
            privateKey: 'test-open-ssh-key-material...',
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
            privateKey: 'test-open-ssh-key-material...',
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
            privateKey: 'test-open-ssh-key-material...',
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
            privateKey: 'test-open-ssh-key-material...',
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
            privateKey: 'test-open-ssh-key-material...',
          ),
        );

        final key = await keyService.getById(id);
        final exported = keyService.exportPrivateKey(key!);
        expect(exported, 'test-open-ssh-key-material...');
      });
    });

    group('watchAllKeys', () {
      test('emits updates', () async {
        await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Watched Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: 'test-open-ssh-key-material...',
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

    group('fingerprint generation via importPublicKey', () {
      test(
        'generates the correct deterministic fingerprint for a known public key',
        () async {
          // importPublicKey calls _computeFingerprint(publicKey) internally.
          // The expected value is pre-computed using the same DJB2-like hash.
          final key = await keyService.importPublicKey(
            name: 'Key A',
            publicKey: 'ssh-ed25519 AAAA1',
          );

          expect(key, isNotNull);
          expect(key!.fingerprint, 'SHA256:1E:BF:D7:47');
        },
      );

      test('different public keys produce different fingerprints', () async {
        final keyA = await keyService.importPublicKey(
          name: 'Key A',
          publicKey: 'ssh-ed25519 AAAA1',
        );
        final keyB = await keyService.importPublicKey(
          name: 'Key B',
          publicKey: 'ssh-ed25519 AAAA2',
        );

        expect(keyA!.fingerprint, 'SHA256:1E:BF:D7:47');
        expect(keyB!.fingerprint, 'SHA256:1E:BF:D7:48');
        expect(keyA.fingerprint, isNot(keyB.fingerprint));
      });

      test('fingerprint always begins with SHA256: prefix', () async {
        final key = await keyService.importPublicKey(
          name: 'Key',
          publicKey: 'ssh-ed25519 AAAA',
        );

        expect(key!.fingerprint, startsWith('SHA256:'));
      });
    });

    group('key lookup by unique fields', () {
      test('can look up a key by its public+private key pair', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Original Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAAdedup',
            privateKey: 'test-key-material-dedup',
          ),
        );

        final keys = await keyService.getAllKeys();
        final match = keys.where(
          (k) =>
              k.publicKey == 'ssh-ed25519 AAAAdedup' &&
              k.privateKey == 'test-key-material-dedup',
        );

        expect(match, hasLength(1));
        expect(match.first.id, id);
      });

      test('can look up a key by its fingerprint', () async {
        const fingerprint = 'SHA256:DE:AD:BE:EF';
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Fingerprintable Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAAfp',
            privateKey: 'test-key-material-fp',
            fingerprint: const Value(fingerprint),
          ),
        );

        final keys = await keyService.getAllKeys();
        final match = keys.where((k) => k.fingerprint == fingerprint);

        expect(match, hasLength(1));
        expect(match.first.id, id);
      });
    });
  });
}
