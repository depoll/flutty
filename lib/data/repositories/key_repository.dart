import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../security/secret_encryption_service.dart';

/// Repository for managing SSH keys.
class KeyRepository {
  /// Creates a new [KeyRepository].
  KeyRepository(this._db, this._secretEncryptionService);

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;

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
    final encryptedPrivateKey = await _secretEncryptionService.encryptRequired(
      key.privateKey,
    );
    final encryptedPassphrase = await _secretEncryptionService.encryptNullable(
      key.passphrase,
    );
    return _db
        .update(_db.sshKeys)
        .replace(
          key.copyWith(
            privateKey: encryptedPrivateKey,
            passphrase: Value(encryptedPassphrase),
          ),
        );
  }

  /// Delete a key.
  Future<int> delete(int id) =>
      (_db.delete(_db.sshKeys)..where((k) => k.id.equals(id))).go();

  Future<List<SshKey>> _decryptKeys(List<SshKey> keys) =>
      Future.wait(keys.map(_decryptKey));

  Future<SshKey> _decryptKey(SshKey key) async {
    final decryptedPrivateKey = await _secretEncryptionService.decryptRequired(
      key.privateKey,
    );
    final decryptedPassphrase = await _secretEncryptionService.decryptNullable(
      key.passphrase,
    );

    return key.copyWith(
      privateKey: decryptedPrivateKey,
      passphrase: Value(decryptedPassphrase),
    );
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
final keyRepositoryProvider = Provider<KeyRepository>(
  (ref) => KeyRepository(
    ref.watch(databaseProvider),
    ref.watch(secretEncryptionServiceProvider),
  ),
);
