import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing groups.
class GroupRepository {
  /// Creates a new [GroupRepository].
  GroupRepository(this._db);

  final AppDatabase _db;

  /// Get all groups.
  Future<List<Group>> getAll() => _db.select(_db.groups).get();

  /// Watch all groups.
  Stream<List<Group>> watchAll() => _db.select(_db.groups).watch();

  /// Get root groups (no parent).
  Future<List<Group>> getRootGroups() =>
      (_db.select(_db.groups)..where((g) => g.parentId.isNull())).get();

  /// Watch root groups.
  Stream<List<Group>> watchRootGroups() =>
      (_db.select(_db.groups)..where((g) => g.parentId.isNull())).watch();

  /// Get child groups of a parent.
  Future<List<Group>> getChildren(int parentId) =>
      (_db.select(_db.groups)..where((g) => g.parentId.equals(parentId))).get();

  /// Watch child groups.
  Stream<List<Group>> watchChildren(int parentId) => (_db.select(
    _db.groups,
  )..where((g) => g.parentId.equals(parentId))).watch();

  /// Get a group by ID.
  Future<Group?> getById(int id) =>
      (_db.select(_db.groups)..where((g) => g.id.equals(id))).getSingleOrNull();

  /// Insert a new group.
  Future<int> insert(GroupsCompanion group) =>
      _db.into(_db.groups).insert(group);

  /// Update an existing group.
  Future<bool> update(Group group) => _db.update(_db.groups).replace(group);

  /// Delete a group.
  Future<int> delete(int id) =>
      (_db.delete(_db.groups)..where((g) => g.id.equals(id))).go();
}

/// Provider for [GroupRepository].
final groupRepositoryProvider = Provider<GroupRepository>(
  (ref) => GroupRepository(ref.watch(databaseProvider)),
);
