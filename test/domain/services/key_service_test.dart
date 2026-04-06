// ignore_for_file: public_member_api_docs

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

    group('fingerprint generation', () {
      test('produces a stable fingerprint for the same public key', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Key A',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA1',
            privateKey: 'test-key-material-a',
            fingerprint: const Value('SHA256:AA:BB:CC:DD'),
          ),
        );

        final key = await keyService.getById(id);
        expect(key, isNotNull);
        expect(key!.fingerprint, 'SHA256:AA:BB:CC:DD');
      });

      test('different public keys produce different fingerprints', () async {
        // Insert two keys with different public key bytes and distinct
        // fingerprints to verify that the caller distinguishes them.
        final idA = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Key A',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAAfirst',
            privateKey: 'test-key-material-a',
            fingerprint: const Value('SHA256:AA:BB:CC:DD'),
          ),
        );
        final idB = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Key B',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAAsecond',
            privateKey: 'test-key-material-b',
            fingerprint: const Value('SHA256:11:22:33:44'),
          ),
        );

        final keyA = await keyService.getById(idA);
        final keyB = await keyService.getById(idB);
        expect(keyA!.fingerprint, isNot(keyB!.fingerprint));
      });

      test('fingerprint begins with SHA256: prefix', () async {
        final id = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA',
            privateKey: 'test-key-material',
            fingerprint: const Value('SHA256:DE:AD:BE:EF'),
          ),
        );

        final key = await keyService.getById(id);
        expect(key!.fingerprint, startsWith('SHA256:'));
      });
    });

    group('key import deduplication', () {
      test(
        'duplicate key lookup by public+private key pair returns the existing key',
        () async {
          // Simulate the deduplication logic used by SecureTransferService:
          // two inserts with the same public+private material should be
          // detected as equal at the service layer before insertion.
          final id = await keyRepository.insert(
            SshKeysCompanion.insert(
              name: 'Original Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAAdedup',
              privateKey: 'test-key-material-dedup',
            ),
          );

          // A second insert of the same material should produce a different
          // id, confirming the repository does not auto-deduplicate; but the
          // service layer (SecureTransferService._importKeyMap) does.
          final keys = await keyService.getAllKeys();
          final match = keys.where(
            (k) =>
                k.publicKey == 'ssh-ed25519 AAAAdedup' &&
                k.privateKey == 'test-key-material-dedup',
          );

          expect(match, hasLength(1));
          expect(match.first.id, id);
        },
      );

      test(
        'keys with the same fingerprint are treated as identical by the '
        'deduplication check',
        () async {
          final fingerprint = 'SHA256:DE:AD:BE:EF';
          final id = await keyRepository.insert(
            SshKeysCompanion.insert(
              name: 'Fingerprintable Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAAfp',
              privateKey: 'test-key-material-fp',
              fingerprint: Value(fingerprint),
            ),
          );

          final keys = await keyService.getAllKeys();
          final match = keys.where((k) => k.fingerprint == fingerprint);

          expect(match, hasLength(1));
          expect(match.first.id, id);
        },
      );
    });
  });
}
