import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing port forwards.
class PortForwardRepository {
  /// Creates a new [PortForwardRepository].
  PortForwardRepository(this._db);

  final AppDatabase _db;

  /// Get all port forwards.
  Future<List<PortForward>> getAll() => _db.select(_db.portForwards).get();

  /// Watch all port forwards.
  Stream<List<PortForward>> watchAll() => _db.select(_db.portForwards).watch();

  /// Get port forwards by host ID.
  Future<List<PortForward>> getByHostId(int hostId) => (_db.select(
    _db.portForwards,
  )..where((p) => p.hostId.equals(hostId))).get();

  /// Watch port forwards by host ID.
  Stream<List<PortForward>> watchByHostId(int hostId) => (_db.select(
    _db.portForwards,
  )..where((p) => p.hostId.equals(hostId))).watch();

  /// Get a port forward by ID.
  Future<PortForward?> getById(int id) => (_db.select(
    _db.portForwards,
  )..where((p) => p.id.equals(id))).getSingleOrNull();

  /// Insert a new port forward.
  Future<int> insert(PortForwardsCompanion portForward) =>
      _db.into(_db.portForwards).insert(portForward);

  /// Update an existing port forward.
  Future<bool> update(PortForward portForward) =>
      _db.update(_db.portForwards).replace(portForward);

  /// Delete a port forward.
  Future<int> delete(int id) =>
      (_db.delete(_db.portForwards)..where((p) => p.id.equals(id))).go();
}

/// Provider for [PortForwardRepository].
final portForwardRepositoryProvider = Provider<PortForwardRepository>(
  (ref) => PortForwardRepository(ref.watch(databaseProvider)),
);
