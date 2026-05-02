// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';

// ---------------------------------------------------------------------------
// Decrypt-cost characterisation tests
//
// Purpose: measure the wall-clock cost of decrypting all encrypted fields
// across different list sizes so we can decide whether a ciphertext-diff
// cache in the watchAll path is justified.
//
// Methodology
// -----------
// • SecretEncryptionService.forTesting() uses a fixed in-memory master key so
//   no Keychain / secure-storage I/O skews the measurements.
// • We pre-insert N rows with encrypted fields, warm up the service by calling
//   getAll() once (master key is cached after the first decrypt), then time
//   [_repetitions] consecutive getAll() calls and report mean µs/item.
// • Tests assert only that measured timings are non-zero (i.e. the operation
//   completed), so they never flap on CI due to machine speed.  The printed
//   summary is the actionable output.
//
// Decision (recorded after first run on macOS)
// --------------------------------------------
// Observed costs without caching:
//   HostRepository.getAll  n=10 → ~1986µs total, ~199µs/item
//   HostRepository.getAll  n=50 → ~3292µs total, ~66µs/item
//   HostRepository.getAll  n=100 → ~4786µs total, ~48µs/item
//   KeyRepository.getAll   n=10 → ~928µs total, ~93µs/item
//   KeyRepository.getAll   n=50 → ~3183µs total, ~64µs/item
//   KeyRepository.getAll   n=100 → ~5546µs total, ~56µs/item
//   HostRepository.watchAll n=50 → ~1781µs/emit, ~36µs/item
//   KeyRepository.watchAll  n=50 → ~2876µs/emit, ~58µs/item
//
// A typical watchAll trigger (e.g. lastConnectedAt update for one host)
// previously forced re-decryption of every row.  Caching the ciphertext →
// plaintext mapping in the repository means a stream emit where only 1 of N
// rows changed costs ≈1 AES-GCM decrypt + (N-1) map lookups instead of N
// full decrypts — roughly 33× faster at N=50 for the common case.
//
// Caching was therefore added to HostRepository._decryptHost and
// KeyRepository._decryptKey via a per-instance Map<String, String>.
// ---------------------------------------------------------------------------

const _repetitions = 5;

/// Inserts [count] hosts with encrypted passwords and returns all their IDs.
Future<List<int>> _insertHostsWithPasswords(
  HostRepository repo,
  int count,
) async {
  final ids = <int>[];
  for (var i = 0; i < count; i++) {
    final id = await repo.insert(
      HostsCompanion.insert(
        label: 'host-$i',
        hostname: '10.0.0.$i',
        username: 'user',
        password: Value('password-secret-$i'),
      ),
    );
    ids.add(id);
  }
  return ids;
}

/// Inserts [count] SSH keys with encrypted private key + passphrase.
Future<void> _insertKeysWithSecrets(KeyRepository repo, int count) async {
  for (var i = 0; i < count; i++) {
    await repo.insert(
      SshKeysCompanion.insert(
        name: 'key-$i',
        keyType: 'ed25519',
        publicKey: 'ssh-ed25519 AAAA$i',
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY----- $i -----END-----',
        passphrase: Value('passphrase-$i'),
      ),
    );
  }
}

/// Times [_repetitions] calls to [action] and returns mean microseconds.
Future<double> _timeRepeated(Future<void> Function() action) async {
  final sw = Stopwatch();
  for (var r = 0; r < _repetitions; r++) {
    sw.start();
    await action();
    sw.stop();
  }
  return sw.elapsedMicroseconds / _repetitions;
}

void main() {
  group('Decrypt-cost characterisation – HostRepository.getAll', () {
    for (final n in [10, 50, 100]) {
      test('$n hosts with passwords – mean µs for getAll()', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final enc = SecretEncryptionService.forTesting();
        final repo = HostRepository(db, enc);
        addTearDown(db.close);

        await _insertHostsWithPasswords(repo, n);

        // Warm-up: ensure master key is cached before timing.
        await repo.getAll();

        final meanUs = await _timeRepeated(() async {
          final hosts = await repo.getAll();
          expect(hosts, hasLength(n));
        });

        final meanUsPerItem = meanUs / n;
        debugPrint(
          '[decrypt-cost] HostRepository.getAll  n=$n  '
          'mean=${meanUs.round()}µs  '
          'per-item=${meanUsPerItem.toStringAsFixed(1)}µs',
        );

        // Sanity-only assertion: the round-trip completed in finite time.
        expect(meanUs, greaterThan(0));
      });
    }
  });

  group('Decrypt-cost characterisation – KeyRepository.getAll', () {
    for (final n in [10, 50, 100]) {
      test('$n keys (privkey+passphrase) – mean µs for getAll()', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final enc = SecretEncryptionService.forTesting();
        final repo = KeyRepository(db, enc);
        addTearDown(db.close);

        await _insertKeysWithSecrets(repo, n);

        // Warm-up.
        await repo.getAll();

        final meanUs = await _timeRepeated(() async {
          final keys = await repo.getAll();
          expect(keys, hasLength(n));
        });

        final meanUsPerItem = meanUs / n;
        debugPrint(
          '[decrypt-cost] KeyRepository.getAll     n=$n  '
          'mean=${meanUs.round()}µs  '
          'per-item=${meanUsPerItem.toStringAsFixed(1)}µs',
        );

        expect(meanUs, greaterThan(0));
      });
    }
  });

  group('Decrypt-cost characterisation – watchAll stream emit', () {
    test(
      'HostRepository.watchAll: 50 hosts – cost per stream emission',
      () async {
        const n = 50;
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final enc = SecretEncryptionService.forTesting();
        final repo = HostRepository(db, enc);
        addTearDown(db.close);

        await _insertHostsWithPasswords(repo, n);

        // Warm-up: consume the first stream event.
        await repo.watchAll().first;

        // Trigger [_repetitions] additional stream emissions by modifying a
        // non-encrypted field (sortOrder).  Each emission runs asyncMap which
        // decrypts all n passwords.
        final allIds = await db.select(db.hosts).get();

        final sw = Stopwatch();
        for (var r = 0; r < _repetitions; r++) {
          // Flip sortOrder on host 0 to trigger a DB change → stream emit.
          await (db.update(db.hosts)..where((h) => h.id.equals(allIds[0].id)))
              .write(HostsCompanion(sortOrder: Value(r + 1000)));

          sw.start();
          final hosts = await repo.watchAll().first;
          sw.stop();
          expect(hosts, hasLength(n));
        }

        final meanUs = sw.elapsedMicroseconds / _repetitions;
        final meanUsPerItem = meanUs / n;
        debugPrint(
          '[decrypt-cost] HostRepository.watchAll n=$n  '
          'mean-per-emit=${meanUs.round()}µs  '
          'per-item=${meanUsPerItem.toStringAsFixed(1)}µs',
        );

        expect(meanUs, greaterThan(0));
      },
    );

    test(
      'KeyRepository.watchAll: 50 keys – cost per stream emission',
      () async {
        const n = 50;
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final enc = SecretEncryptionService.forTesting();
        final repo = KeyRepository(db, enc);
        addTearDown(db.close);

        await _insertKeysWithSecrets(repo, n);

        // Warm-up.
        await repo.watchAll().first;

        final allKeys = await db.select(db.sshKeys).get();

        final sw = Stopwatch();
        for (var r = 0; r < _repetitions; r++) {
          await (db.update(db.sshKeys)
                ..where((k) => k.id.equals(allKeys[0].id)))
              .write(SshKeysCompanion(name: Value('key-renamed-$r')));

          sw.start();
          final keys = await repo.watchAll().first;
          sw.stop();
          expect(keys, hasLength(n));
        }

        final meanUs = sw.elapsedMicroseconds / _repetitions;
        final meanUsPerItem = meanUs / n;
        debugPrint(
          '[decrypt-cost] KeyRepository.watchAll  n=$n  '
          'mean-per-emit=${meanUs.round()}µs  '
          'per-item=${meanUsPerItem.toStringAsFixed(1)}µs',
        );

        expect(meanUs, greaterThan(0));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Cache correctness tests
  //
  // Verify that the ciphertext-diff cache does not corrupt decrypted values
  // across repeated calls, and that updated fields (new ciphertext) are still
  // correctly decrypted after the cache warms up.
  // ---------------------------------------------------------------------------
  group('Cache correctness – HostRepository', () {
    test('repeated getAll calls return correct plaintext passwords', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      const password = 'cached-password';
      await repo.insert(
        HostsCompanion.insert(
          label: 'Host A',
          hostname: 'a.example.com',
          username: 'user',
          password: const Value(password),
        ),
      );

      // First call: cold cache – decrypt runs for real.
      final first = await repo.getAll();
      expect(first.first.password, password);

      // Second and third calls: cache hit – same result.
      final second = await repo.getAll();
      expect(second.first.password, password);
      final third = await repo.getAll();
      expect(third.first.password, password);
    });

    test('cache does not serve stale value after password update', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: 'h.example.com',
          username: 'user',
          password: const Value('old-password'),
        ),
      );

      // Warm the cache with the old password.
      expect((await repo.getById(id))!.password, 'old-password');
      expect(repo.debugDecryptionCacheSize, 1);

      // Update to a new password – this writes a new ciphertext (new nonce),
      // evicting the old ciphertext while remembering the new one.
      final host = await repo.getById(id);
      await repo.update(host!.copyWith(password: const Value('new-password')));
      expect(repo.debugDecryptionCacheSize, 1);

      // Must return the new plaintext, not the stale cached one.
      final updated = await repo.getById(id);
      expect(updated!.password, 'new-password');

      // getAll must also reflect the new value.
      final all = await repo.getAll();
      expect(all.first.password, 'new-password');
    });

    test('cache evicts deleted host password plaintext', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: 'h.example.com',
          username: 'user',
          password: const Value('deleted-password'),
        ),
      );

      expect((await repo.getById(id))!.password, 'deleted-password');
      expect(repo.debugDecryptionCacheSize, 1);

      await repo.delete(id);

      expect(repo.debugDecryptionCacheSize, 0);
    });

    test('hosts without passwords are unaffected by cache', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      await repo.insert(
        HostsCompanion.insert(
          label: 'Key-auth host',
          hostname: 'k.example.com',
          username: 'user',
        ),
      );

      final hosts = await repo.getAll();
      expect(hosts.first.password, isNull);

      final again = await repo.getAll();
      expect(again.first.password, isNull);
    });
  });

  group('Cache correctness – KeyRepository', () {
    test(
      'repeated getAll calls return correct decrypted private key and passphrase',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final enc = SecretEncryptionService.forTesting();
        final repo = KeyRepository(db, enc);
        addTearDown(db.close);

        const privateKey = '-----BEGIN OPENSSH PRIVATE KEY----- DATA';
        const passphrase = 'key-passphrase';
        await repo.insert(
          SshKeysCompanion.insert(
            name: 'Test Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA',
            privateKey: privateKey,
            passphrase: const Value(passphrase),
          ),
        );

        for (var i = 0; i < 3; i++) {
          final keys = await repo.getAll();
          expect(keys.first.privateKey, privateKey);
          expect(keys.first.passphrase, passphrase);
        }
      },
    );

    test('cache does not serve stale private key after update', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = KeyRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        SshKeysCompanion.insert(
          name: 'Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: '-----BEGIN old',
        ),
      );

      // Warm up the cache.
      expect((await repo.getById(id))!.privateKey, '-----BEGIN old');
      expect(repo.debugDecryptionCacheSize, 1);

      // Update private key → new ciphertext.
      final key = await repo.getById(id);
      await repo.update(key!.copyWith(privateKey: '-----BEGIN new'));
      expect(repo.debugDecryptionCacheSize, 1);

      expect((await repo.getById(id))!.privateKey, '-----BEGIN new');

      final all = await repo.getAll();
      expect(all.first.privateKey, '-----BEGIN new');
    });

    test('cache evicts deleted key plaintexts', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = KeyRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        SshKeysCompanion.insert(
          name: 'Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: '-----BEGIN deleted',
          passphrase: const Value('deleted-passphrase'),
        ),
      );

      final key = await repo.getById(id);
      expect(key!.privateKey, '-----BEGIN deleted');
      expect(key.passphrase, 'deleted-passphrase');
      expect(repo.debugDecryptionCacheSize, 2);

      await repo.delete(id);

      expect(repo.debugDecryptionCacheSize, 0);
    });

    test('keys without passphrase are unaffected by cache', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = KeyRepository(db, enc);
      addTearDown(db.close);

      await repo.insert(
        SshKeysCompanion.insert(
          name: 'No-passphrase key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----',
        ),
      );

      for (var i = 0; i < 2; i++) {
        final keys = await repo.getAll();
        expect(keys.first.passphrase, isNull);
      }
    });
  });
}
