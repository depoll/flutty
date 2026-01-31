import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing host entities.
class HostRepository {
  /// Creates a new [HostRepository].
  HostRepository(this._db);

  final AppDatabase _db;

  /// Get all hosts.
  Future<List<Host>> getAll() => _db.select(_db.hosts).get();

  /// Watch all hosts.
  Stream<List<Host>> watchAll() => _db.select(_db.hosts).watch();

  /// Get hosts by group.
  Future<List<Host>> getByGroup(int? groupId) {
    if (groupId == null) {
      return (_db.select(_db.hosts)..where((h) => h.groupId.isNull())).get();
    }
    return (_db.select(
      _db.hosts,
    )..where((h) => h.groupId.equals(groupId))).get();
  }

  /// Watch hosts by group.
  Stream<List<Host>> watchByGroup(int? groupId) {
    if (groupId == null) {
      return (_db.select(_db.hosts)..where((h) => h.groupId.isNull())).watch();
    }
    return (_db.select(
      _db.hosts,
    )..where((h) => h.groupId.equals(groupId))).watch();
  }

  /// Get favorite hosts.
  Future<List<Host>> getFavorites() =>
      (_db.select(_db.hosts)..where((h) => h.isFavorite.equals(true))).get();

  /// Watch favorite hosts.
  Stream<List<Host>> watchFavorites() =>
      (_db.select(_db.hosts)..where((h) => h.isFavorite.equals(true))).watch();

  /// Get a host by ID.
  Future<Host?> getById(int id) =>
      (_db.select(_db.hosts)..where((h) => h.id.equals(id))).getSingleOrNull();

  /// Search hosts by label or hostname.
  Future<List<Host>> search(String query) =>
      (_db.select(_db.hosts)..where(
            (h) =>
                h.label.like('%$query%') |
                h.hostname.like('%$query%') |
                h.tags.like('%$query%'),
          ))
          .get();

  /// Insert a new host.
  Future<int> insert(HostsCompanion host) => _db.into(_db.hosts).insert(host);

  /// Update an existing host.
  Future<bool> update(Host host) => _db.update(_db.hosts).replace(host);

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
}

/// Provider for [HostRepository].
final hostRepositoryProvider = Provider<HostRepository>(
  (ref) => HostRepository(ref.watch(databaseProvider)),
);
