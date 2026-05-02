import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/auth_service.dart';
import '../database/database.dart';
import '../security/secret_encryption_service.dart';

/// Repository for managing SSH keys.
class KeyRepository {
  /// Creates a new [KeyRepository].
  KeyRepository(this._db, this._secretEncryptionService);

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;

  static const _maxDecryptCacheEntries = 512;

  // Ciphertext-keyed cache – see HostRepository._decryptCache for rationale.
  final _decryptCache = <String, String>{};

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

  /// Watch all keys.
  Stream<List<SshKey>> watchAll() =>
      _db.select(_db.sshKeys).watch().asyncMap(_decryptKeys);

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
  Future<List<SshKey>> search(String query) => (_db.select(
    _db.sshKeys,
  )..where((k) => k.name.like('%$query%'))).get().then(_decryptKeys);

  /// Insert a new key.
  Future<int> insert(SshKeysCompanion key) async {
    final encryptedKey = await _encryptKeyCompanion(key);
    return _db.into(_db.sshKeys).insert(encryptedKey);
  }

  /// Update an existing key.
  Future<bool> update(SshKey key) async {
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
      _evictDecrypted(previousStoredSecrets?.privateKey);
      _evictDecrypted(previousStoredSecrets?.passphrase);
      _rememberEncryptedPlaintext(encryptedPrivateKey, key.privateKey);
      _rememberEncryptedPlaintext(encryptedPassphrase, key.passphrase);
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
      _evictDecrypted(previousStoredSecrets?.privateKey);
      _evictDecrypted(previousStoredSecrets?.passphrase);
    }
    return deleted;
  }

  Future<List<SshKey>> _decryptKeys(List<SshKey> keys) =>
      Future.wait(keys.map(_decryptKey));

  Future<SshKey> _decryptKey(SshKey key) async {
    final decryptedPrivateKey = await _cachedDecryptRequired(key.privateKey);
    final passphrase = key.passphrase;
    final decryptedPassphrase = passphrase != null && passphrase.isNotEmpty
        ? await _cachedDecrypt(passphrase)
        : await _secretEncryptionService.decryptNullable(passphrase);

    return key.copyWith(
      privateKey: decryptedPrivateKey,
      passphrase: Value(decryptedPassphrase),
    );
  }

  /// Returns the cached or freshly-decrypted form of [ciphertext].
  Future<String?> _cachedDecrypt(String ciphertext) async {
    final hit = _decryptCache.remove(ciphertext);
    if (hit != null) {
      _decryptCache[ciphertext] = hit;
      return hit;
    }

    final plaintext = await _secretEncryptionService.decryptNullable(
      ciphertext,
    );
    if (plaintext != null && plaintext.isNotEmpty) {
      _rememberDecrypted(ciphertext, plaintext);
    }
    return plaintext;
  }

  Future<String> _cachedDecryptRequired(String ciphertext) async =>
      (await _cachedDecrypt(ciphertext)) ?? '';

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

  void _rememberEncryptedPlaintext(String? ciphertext, String? plaintext) {
    if (ciphertext == null ||
        ciphertext.isEmpty ||
        plaintext == null ||
        plaintext.isEmpty ||
        _secretEncryptionService.isEncryptedValue(plaintext)) {
      return;
    }
    _rememberDecrypted(ciphertext, plaintext);
  }

  void _rememberDecrypted(String ciphertext, String plaintext) {
    _decryptCache.remove(ciphertext);
    _decryptCache[ciphertext] = plaintext;
    while (_decryptCache.length > _maxDecryptCacheEntries) {
      _decryptCache.remove(_decryptCache.keys.first);
    }
  }

  void _evictDecrypted(String? ciphertext) {
    if (ciphertext == null || ciphertext.isEmpty) {
      return;
    }
    _decryptCache.remove(ciphertext);
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
