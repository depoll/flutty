// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/openssh_key_generator.dart';

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

    group('importKey', () {
      test('returns null for invalid PEM', () async {
        final result = await keyService.importKey(
          name: 'Invalid Key',
          privateKeyPem: 'not a valid key',
        );
        expect(result, isNull);
      });

      test(
        'returns null for an encrypted key with the wrong passphrase',
        () async {
          final encryptedPem = await generateOpenSshPrivateKeyPem(
            keyType: SshKeyType.ed25519,
            comment: 'unit@test',
            passphrase: 'correct-passphrase',
          );

          final result = await keyService.importKey(
            name: 'Encrypted',
            privateKeyPem: encryptedPem,
            passphrase: 'wrong-passphrase',
          );
          expect(result, isNull);
        },
      );

      test('returns null for an encrypted key with no passphrase', () async {
        final encryptedPem = await generateOpenSshPrivateKeyPem(
          keyType: SshKeyType.ed25519,
          comment: 'unit@test',
          passphrase: 'correct-passphrase',
        );

        final result = await keyService.importKey(
          name: 'Encrypted',
          privateKeyPem: encryptedPem,
        );
        expect(result, isNull);
      });
    });

    group('generateKey', () {
      test('generates and stores an Ed25519 key', () async {
        final key = await keyService.generateKey(
          name: 'Generated Ed25519',
          keyType: SshKeyType.ed25519,
        );

        expect(key, isNotNull);
        expect(key!.keyType, 'ssh-ed25519');
        expect(key.publicKey, startsWith('ssh-ed25519 '));
        expect(key.privateKey, contains('OPENSSH PRIVATE KEY'));
        expect(key.fingerprint, startsWith('SHA256:'));
        expect(SSHKeyPair.fromPem(key.privateKey), isNotEmpty);
        expect(await keyRepository.getAll(), hasLength(1));
      });

      test(
        'generates and stores an RSA key with the canonical prefix',
        () async {
          final key = await keyService.generateKey(
            name: 'Generated RSA',
            keyType: SshKeyType.rsa2048,
          );

          expect(key, isNotNull);
          expect(key!.keyType, 'ssh-rsa');
          expect(key.publicKey, startsWith('ssh-rsa '));
          expect(SSHKeyPair.fromPem(key.privateKey), isNotEmpty);
        },
      );

      test('encrypts the stored key when a passphrase is provided', () async {
        const passphrase = 'unit-test-passphrase';
        final key = await keyService.generateKey(
          name: 'Protected',
          keyType: SshKeyType.ed25519,
          passphrase: passphrase,
        );

        expect(key, isNotNull);
        // The stored private key really is encrypted with the passphrase.
        expect(
          () => SSHKeyPair.fromPem(key!.privateKey),
          throwsA(isA<SSHError>()),
        );
        expect(SSHKeyPair.fromPem(key!.privateKey, passphrase), isNotEmpty);
        expect(key.passphrase, passphrase);
      });

      test('treats an empty passphrase as unencrypted', () async {
        final key = await keyService.generateKey(
          name: 'No passphrase',
          keyType: SshKeyType.ed25519,
          passphrase: '',
        );

        expect(key, isNotNull);
        expect(SSHKeyPair.fromPem(key!.privateKey), isNotEmpty);
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

        final keys = await keyRepository.getAll();
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

        final keys = await keyRepository.getAll();
        final match = keys.where((k) => k.fingerprint == fingerprint);

        expect(match, hasLength(1));
        expect(match.first.id, id);
      });
    });
  });
}
