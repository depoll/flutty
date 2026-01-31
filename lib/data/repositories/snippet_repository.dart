import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing snippets.
class SnippetRepository {
  /// Creates a new [SnippetRepository].
  SnippetRepository(this._db);

  final AppDatabase _db;

  /// Get all snippets.
  Future<List<Snippet>> getAll() => _db.select(_db.snippets).get();

  /// Watch all snippets.
  Stream<List<Snippet>> watchAll() => _db.select(_db.snippets).watch();

  /// Get snippets by folder.
  Future<List<Snippet>> getByFolder(int? folderId) {
    if (folderId == null) {
      return (_db.select(
        _db.snippets,
      )..where((s) => s.folderId.isNull())).get();
    }
    return (_db.select(
      _db.snippets,
    )..where((s) => s.folderId.equals(folderId))).get();
  }

  /// Watch snippets by folder.
  Stream<List<Snippet>> watchByFolder(int? folderId) {
    if (folderId == null) {
      return (_db.select(
        _db.snippets,
      )..where((s) => s.folderId.isNull())).watch();
    }
    return (_db.select(
      _db.snippets,
    )..where((s) => s.folderId.equals(folderId))).watch();
  }

  /// Get frequently used snippets.
  Future<List<Snippet>> getFrequent({int limit = 10}) =>
      (_db.select(_db.snippets)
            ..orderBy([(s) => OrderingTerm.desc(s.usageCount)])
            ..limit(limit))
          .get();

  /// Search snippets.
  Future<List<Snippet>> search(String query) =>
      (_db.select(_db.snippets)..where(
            (s) =>
                s.name.like('%$query%') |
                s.command.like('%$query%') |
                s.description.like('%$query%'),
          ))
          .get();

  /// Get a snippet by ID.
  Future<Snippet?> getById(int id) => (_db.select(
    _db.snippets,
  )..where((s) => s.id.equals(id))).getSingleOrNull();

  /// Insert a new snippet.
  Future<int> insert(SnippetsCompanion snippet) =>
      _db.into(_db.snippets).insert(snippet);

  /// Update an existing snippet.
  Future<bool> update(Snippet snippet) =>
      _db.update(_db.snippets).replace(snippet);

  /// Delete a snippet.
  Future<int> delete(int id) =>
      (_db.delete(_db.snippets)..where((s) => s.id.equals(id))).go();

  /// Increment usage count.
  Future<bool> incrementUsage(int id) async {
    final snippet = await getById(id);
    if (snippet == null) return false;
    return update(
      snippet.copyWith(
        usageCount: snippet.usageCount + 1,
        lastUsedAt: Value(DateTime.now()),
      ),
    );
  }

  // Snippet folders

  /// Get all folders.
  Future<List<SnippetFolder>> getAllFolders() =>
      _db.select(_db.snippetFolders).get();

  /// Watch all folders.
  Stream<List<SnippetFolder>> watchAllFolders() =>
      _db.select(_db.snippetFolders).watch();

  /// Insert a folder.
  Future<int> insertFolder(SnippetFoldersCompanion folder) =>
      _db.into(_db.snippetFolders).insert(folder);

  /// Update a folder.
  Future<bool> updateFolder(SnippetFolder folder) =>
      _db.update(_db.snippetFolders).replace(folder);

  /// Delete a folder.
  Future<int> deleteFolder(int id) =>
      (_db.delete(_db.snippetFolders)..where((f) => f.id.equals(id))).go();
}

/// Provider for [SnippetRepository].
final snippetRepositoryProvider = Provider<SnippetRepository>(
  (ref) => SnippetRepository(ref.watch(databaseProvider)),
);
