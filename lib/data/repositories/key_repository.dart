import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/auth_service.dart';
import '../database/database.dart';
import '../security/secret_encryption_service.dart';
import 'like_query.dart';
import 'plaintext_cache.dart';

enum _KeySecretColumn { privateKey, passphrase }

/// Result from loading decryptable SSH keys while tolerating unreadable rows.
class SshKeyLoadResult {
  /// Creates a new [SshKeyLoadResult].
  const SshKeyLoadResult({
    required this.keys,
    required this.unreadableCount,
    this.firstUnreadableErrorType,
  });

  /// Keys whose encrypted secrets were readable.
  final List<SshKey> keys;

  /// Number of stored keys skipped because their secrets were unreadable.
  final int unreadableCount;

  /// Runtime type for the first unreadable-key error, if any.
  final String? firstUnreadableErrorType;
}

/// Repository for managing SSH keys.
class KeyRepository {
  /// Creates a new [KeyRepository].
  KeyRepository(this._db, this._secretEncryptionService);

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;
  late final _decryptCache = PlaintextCache(_secretEncryptionService);

  /// Clears cached decrypted secret plaintexts.
  void clearDecryptionCache() {
    _decryptCache.clear();
  }

  /// Number of cached decrypted secret plaintexts.
  @visibleForTesting
  int get debugDecryptionCacheSize => _decryptCache.length;

  /// Get all keys.
  Future<List<SshKey>> getAll() async {
    final keys = await _db.select(_db.sshKeys).get();
    return Future.wait(keys.map(_decryptKey));
  }

  /// Get all keys that can be decrypted, skipping unreadable stored keys.
  Future<SshKeyLoadResult> getAllDecryptable() async {
    final keys = await _db.select(_db.sshKeys).get();
    return _loadDecryptable(keys);
  }

  /// Watch all keys.
  Stream<List<SshKey>> watchAll() => _db
      .select(_db.sshKeys)
      .watch()
      .asyncMap((keys) async => (await _loadDecryptable(keys)).keys);

  /// Get a key by ID.
  Future<SshKey?> getById(int id) async {
    final key = await (_db.select(
      _db.sshKeys,
    )..where((k) => k.id.equals(id))).getSingleOrNull();
    if (key == null) {
      return null;
    }
    return _decryptKey(key);
  }

  /// Search keys by name.
  Future<List<SshKey>> search(String query) {
    final escaped = escapeSqlLikeQuery(query);
    return (_db.select(_db.sshKeys)..where(
          (k) => k.name.like('%$escaped%', escapeChar: sqlLikeEscapeCharacter),
        ))
        .get()
        .then((keys) async => (await _loadDecryptable(keys)).keys);
  }

  /// Insert a new key.
  Future<int> insert(SshKeysCompanion key) async {
    final encryptedKey = await _encryptKeyCompanion(key);
    return _db.into(_db.sshKeys).insert(encryptedKey);
  }

  /// Update an existing key.
  Future<bool> update(SshKey key) async {
    final generation = _decryptCache.generation;
    final previousStoredSecrets = await _storedSecretsForKey(key.id);
    final encryptedPrivateKey = await _secretEncryptionService.encryptRequired(
      key.privateKey,
    );
    final encryptedPassphrase = await _secretEncryptionService.encryptNullable(
      key.passphrase,
    );
    final updated = await _db
        .update(_db.sshKeys)
        .replace(
          key.copyWith(
            privateKey: encryptedPrivateKey,
            passphrase: Value(encryptedPassphrase),
          ),
        );
    if (updated) {
      _decryptCache
        ..remove(previousStoredSecrets?.privateKey)
        ..remove(previousStoredSecrets?.passphrase)
        ..remember(
          encryptedPrivateKey,
          key.privateKey,
          generation,
          isWrite: true,
        )
        ..remember(
          encryptedPassphrase,
          key.passphrase,
          generation,
          isWrite: true,
        );
    }
    return updated;
  }

  /// Delete a key.
  Future<int> delete(int id) async {
    final previousStoredSecrets = await _storedSecretsForKey(id);
    final deleted = await (_db.delete(
      _db.sshKeys,
    )..where((k) => k.id.equals(id))).go();
    if (deleted > 0) {
      _decryptCache
        ..remove(previousStoredSecrets?.privateKey)
        ..remove(previousStoredSecrets?.passphrase);
    }
    return deleted;
  }

  Future<SshKeyLoadResult> _loadDecryptable(List<SshKey> keys) async {
    final generation = _decryptCache.generation;
    final decryptedKeys = <SshKey>[];
    var unreadableCount = 0;
    String? firstUnreadableErrorType;

    for (final key in keys) {
      try {
        decryptedKeys.add(await _decryptKey(key, generation: generation));
      } on Exception catch (error) {
        unreadableCount++;
        firstUnreadableErrorType ??= error.runtimeType.toString();
      }
    }

    return SshKeyLoadResult(
      keys: List.unmodifiable(decryptedKeys),
      unreadableCount: unreadableCount,
      firstUnreadableErrorType: firstUnreadableErrorType,
    );
  }

  Future<SshKey> _decryptKey(SshKey key, {int? generation}) async {
    generation ??= _decryptCache.generation;
    final decryptedPrivateKey =
        await _decryptOrMigrateKeySecret(
          key.id,
          key.privateKey,
          _KeySecretColumn.privateKey,
          generation,
        ) ??
        '';
    final passphrase = key.passphrase;
    final decryptedPassphrase = passphrase != null && passphrase.isNotEmpty
        ? await _decryptOrMigrateKeySecret(
            key.id,
            passphrase,
            _KeySecretColumn.passphrase,
            generation,
          )
        : await _secretEncryptionService.decryptNullable(passphrase);

    return key.copyWith(
      privateKey: decryptedPrivateKey,
      passphrase: Value(decryptedPassphrase),
    );
  }

  Future<String?> _decryptOrMigrateKeySecret(
    int keyId,
    String storedSecret,
    _KeySecretColumn column,
    int generation,
  ) async {
    if (_secretEncryptionService.isValidEncryptedEnvelope(storedSecret)) {
      return _decryptCache.decrypt(storedSecret, generation);
    }

    final encryptedSecret = await _secretEncryptionService.encryptNullable(
      storedSecret,
    );
    if (encryptedSecret != null && encryptedSecret != storedSecret) {
      await (_db.update(_db.sshKeys)..where(
            (k) =>
                k.id.equals(keyId) &
                (switch (column) {
                  _KeySecretColumn.privateKey => k.privateKey.equals(
                    storedSecret,
                  ),
                  _KeySecretColumn.passphrase => k.passphrase.equals(
                    storedSecret,
                  ),
                }),
          ))
          .write(switch (column) {
            _KeySecretColumn.privateKey => SshKeysCompanion(
              privateKey: Value(encryptedSecret),
            ),
            _KeySecretColumn.passphrase => SshKeysCompanion(
              passphrase: Value(encryptedSecret),
            ),
          });
      _decryptCache.remember(encryptedSecret, storedSecret, generation);
    }
    return storedSecret;
  }

  Future<({String? passphrase, String privateKey})?> _storedSecretsForKey(
    int id,
  ) async {
    final row = await (_db.select(
      _db.sshKeys,
    )..where((k) => k.id.equals(id))).getSingleOrNull();
    if (row == null) {
      return null;
    }
    return (privateKey: row.privateKey, passphrase: row.passphrase);
  }

  Future<SshKeysCompanion> _encryptKeyCompanion(SshKeysCompanion key) async {
    final encryptedPrivateKey = key.privateKey.present
        ? await _secretEncryptionService.encryptRequired(key.privateKey.value)
        : '';

    if (!key.privateKey.present) {
      throw ArgumentError('SSH key privateKey must be present');
    }

    if (!key.passphrase.present) {
      return key.copyWith(privateKey: Value(encryptedPrivateKey));
    }

    final encryptedPassphrase = await _secretEncryptionService.encryptNullable(
      key.passphrase.value,
    );
    return key.copyWith(
      privateKey: Value(encryptedPrivateKey),
      passphrase: Value(encryptedPassphrase),
    );
  }
}

/// Provider for [KeyRepository].
final keyRepositoryProvider = Provider<KeyRepository>((ref) {
  final repository = KeyRepository(
    ref.watch(databaseProvider),
    ref.watch(secretEncryptionServiceProvider),
  );
  ref.listen<AuthState>(authStateProvider, (_, next) {
    if (next == AuthState.locked) {
      repository.clearDecryptionCache();
    }
  });
  return repository;
});
