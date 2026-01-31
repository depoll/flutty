import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing SSH keys.
class KeyRepository {
  /// Creates a new [KeyRepository].
  KeyRepository(this._db);

  final AppDatabase _db;

  /// Get all keys.
  Future<List<SshKey>> getAll() => _db.select(_db.sshKeys).get();

  /// Watch all keys.
  Stream<List<SshKey>> watchAll() => _db.select(_db.sshKeys).watch();

  /// Get a key by ID.
  Future<SshKey?> getById(int id) => (_db.select(
    _db.sshKeys,
  )..where((k) => k.id.equals(id))).getSingleOrNull();

  /// Search keys by name.
  Future<List<SshKey>> search(String query) =>
      (_db.select(_db.sshKeys)..where((k) => k.name.like('%$query%'))).get();

  /// Insert a new key.
  Future<int> insert(SshKeysCompanion key) => _db.into(_db.sshKeys).insert(key);

  /// Update an existing key.
  Future<bool> update(SshKey key) => _db.update(_db.sshKeys).replace(key);

  /// Delete a key.
  Future<int> delete(int id) =>
      (_db.delete(_db.sshKeys)..where((k) => k.id.equals(id))).go();
}

/// Provider for [KeyRepository].
final keyRepositoryProvider = Provider<KeyRepository>(
  (ref) => KeyRepository(ref.watch(databaseProvider)),
);
