import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../security/secret_encryption_service.dart';

/// Repository for managing host entities.
class HostRepository {
  /// Creates a new [HostRepository].
  HostRepository(this._db, this._secretEncryptionService);

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;

  /// Get all hosts.
  Future<List<Host>> getAll() async {
    final hosts = await _db.select(_db.hosts).get();
    return Future.wait(hosts.map(_decryptHost));
  }

  /// Watch all hosts.
  Stream<List<Host>> watchAll() =>
      _db.select(_db.hosts).watch().asyncMap(_decryptHosts);

  /// Get hosts by group.
  Future<List<Host>> getByGroup(int? groupId) {
    if (groupId == null) {
      return (_db.select(
        _db.hosts,
      )..where((h) => h.groupId.isNull())).get().then(_decryptHosts);
    }
    return (_db.select(
      _db.hosts,
    )..where((h) => h.groupId.equals(groupId))).get().then(_decryptHosts);
  }

  /// Watch hosts by group.
  Stream<List<Host>> watchByGroup(int? groupId) {
    if (groupId == null) {
      return (_db.select(
        _db.hosts,
      )..where((h) => h.groupId.isNull())).watch().asyncMap(_decryptHosts);
    }
    return (_db.select(
      _db.hosts,
    )..where((h) => h.groupId.equals(groupId))).watch().asyncMap(_decryptHosts);
  }

  /// Get favorite hosts.
  Future<List<Host>> getFavorites() => (_db.select(
    _db.hosts,
  )..where((h) => h.isFavorite.equals(true))).get().then(_decryptHosts);

  /// Watch favorite hosts.
  Stream<List<Host>> watchFavorites() => (_db.select(
    _db.hosts,
  )..where((h) => h.isFavorite.equals(true))).watch().asyncMap(_decryptHosts);

  /// Get a host by ID.
  Future<Host?> getById(int id) async {
    final host = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    if (host == null) {
      return null;
    }
    return _decryptHost(host);
  }

  /// Search hosts by label or hostname.
  Future<List<Host>> search(String query) =>
      (_db.select(_db.hosts)..where(
            (h) =>
                h.label.like('%$query%') |
                h.hostname.like('%$query%') |
                h.tags.like('%$query%'),
          ))
          .get()
          .then(_decryptHosts);

  /// Insert a new host.
  Future<int> insert(HostsCompanion host) async {
    final encryptedHost = await _encryptHostCompanion(host);
    return _db.into(_db.hosts).insert(encryptedHost);
  }

  /// Update an existing host.
  Future<bool> update(Host host) async {
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      host.password,
    );
    return _db
        .update(_db.hosts)
        .replace(host.copyWith(password: Value(encryptedPassword)));
  }

  /// Delete a host.
  Future<int> delete(int id) =>
      (_db.delete(_db.hosts)..where((h) => h.id.equals(id))).go();

  /// Toggle favorite status.
  Future<bool> toggleFavorite(int id) async {
    final host = await getById(id);
    if (host == null) return false;
    return update(host.copyWith(isFavorite: !host.isFavorite));
  }

  /// Update last connected timestamp.
  Future<bool> updateLastConnected(int id) async {
    final host = await getById(id);
    if (host == null) return false;
    return update(host.copyWith(lastConnectedAt: Value(DateTime.now())));
  }

  Future<List<Host>> _decryptHosts(List<Host> hosts) =>
      Future.wait(hosts.map(_decryptHost));

  Future<Host> _decryptHost(Host host) async {
    final storedPassword = host.password;
    if (storedPassword == null || storedPassword.isEmpty) {
      return host;
    }

    final decryptedPassword = await _secretEncryptionService.decryptNullable(
      storedPassword,
    );
    return host.copyWith(password: Value(decryptedPassword));
  }

  Future<HostsCompanion> _encryptHostCompanion(HostsCompanion host) async {
    if (!host.password.present || host.password.value == null) {
      return host;
    }
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      host.password.value,
    );
    return host.copyWith(password: Value(encryptedPassword));
  }
}

/// Provider for [HostRepository].
final hostRepositoryProvider = Provider<HostRepository>(
  (ref) => HostRepository(
    ref.watch(databaseProvider),
    ref.watch(secretEncryptionServiceProvider),
  ),
);
