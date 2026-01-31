// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutty/data/database/database.dart';
import 'package:flutty/data/repositories/snippet_repository.dart';

void main() {
  late AppDatabase db;
  late SnippetRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = SnippetRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SnippetRepository - Snippets', () {
    test('getAll returns empty list initially', () async {
      final snippets = await repository.getAll();
      expect(snippets, isEmpty);
    });

    test('insert creates a new snippet', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'List Files', command: 'ls -la'),
      );

      expect(id, greaterThan(0));

      final snippets = await repository.getAll();
      expect(snippets, hasLength(1));
      expect(snippets.first.name, 'List Files');
      expect(snippets.first.command, 'ls -la');
      expect(snippets.first.usageCount, 0);
    });

    test('getById returns snippet when exists', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'Disk Usage', command: 'df -h'),
      );

      final snippet = await repository.getById(id);

      expect(snippet, isNotNull);
      expect(snippet!.id, id);
      expect(snippet.name, 'Disk Usage');
    });

    test('getById returns null when not exists', () async {
      final snippet = await repository.getById(999);
      expect(snippet, isNull);
    });

    test('update modifies existing snippet', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'Original', command: 'ls'),
      );

      final snippet = await repository.getById(id);
      final success = await repository.update(
        snippet!.copyWith(name: 'Updated', command: 'ls -la'),
      );

      expect(success, isTrue);

      final updated = await repository.getById(id);
      expect(updated!.name, 'Updated');
      expect(updated.command, 'ls -la');
    });

    test('delete removes snippet', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'To Delete', command: 'rm -rf /'),
      );

      final deleted = await repository.delete(id);
      expect(deleted, 1);

      final snippet = await repository.getById(id);
      expect(snippet, isNull);
    });

    test('delete returns 0 when snippet not exists', () async {
      final deleted = await repository.delete(999);
      expect(deleted, 0);
    });

    test('incrementUsage increases usage count', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'Test Snippet', command: 'echo hello'),
      );

      var snippet = await repository.getById(id);
      expect(snippet!.usageCount, 0);
      expect(snippet.lastUsedAt, isNull);

      await repository.incrementUsage(id);

      snippet = await repository.getById(id);
      expect(snippet!.usageCount, 1);
      expect(snippet.lastUsedAt, isNotNull);

      await repository.incrementUsage(id);

      snippet = await repository.getById(id);
      expect(snippet!.usageCount, 2);
    });

    test('incrementUsage returns false when snippet not exists', () async {
      final result = await repository.incrementUsage(999);
      expect(result, isFalse);
    });

    test('search finds snippets by name', () async {
      await repository.insert(
        SnippetsCompanion.insert(
          name: 'Docker Logs',
          command: 'docker logs -f',
        ),
      );
      await repository.insert(
        SnippetsCompanion.insert(name: 'Git Status', command: 'git status'),
      );

      final results = await repository.search('Docker');
      expect(results, hasLength(1));
      expect(results.first.name, 'Docker Logs');
    });

    test('search finds snippets by command', () async {
      await repository.insert(
        SnippetsCompanion.insert(name: 'Logs', command: 'docker logs -f'),
      );
      await repository.insert(
        SnippetsCompanion.insert(name: 'Status', command: 'git status'),
      );

      final results = await repository.search('git');
      expect(results, hasLength(1));
      expect(results.first.name, 'Status');
    });

    test('search finds snippets by description', () async {
      await repository.insert(
        SnippetsCompanion.insert(
          name: 'Cleanup',
          command: 'rm -rf /tmp/*',
          description: const Value('Remove temporary files'),
        ),
      );

      final results = await repository.search('temporary');
      expect(results, hasLength(1));
      expect(results.first.name, 'Cleanup');
    });

    test('getFrequent returns snippets ordered by usage count', () async {
      final id1 = await repository.insert(
        SnippetsCompanion.insert(name: 'Snippet 1', command: 'cmd1'),
      );
      final id2 = await repository.insert(
        SnippetsCompanion.insert(name: 'Snippet 2', command: 'cmd2'),
      );
      final id3 = await repository.insert(
        SnippetsCompanion.insert(name: 'Snippet 3', command: 'cmd3'),
      );

      // Use snippets different amounts
      await repository.incrementUsage(id1);
      await repository.incrementUsage(id2);
      await repository.incrementUsage(id2);
      await repository.incrementUsage(id3);
      await repository.incrementUsage(id3);
      await repository.incrementUsage(id3);

      final frequent = await repository.getFrequent(limit: 3);
      expect(frequent, hasLength(3));
      expect(frequent[0].name, 'Snippet 3'); // 3 uses
      expect(frequent[1].name, 'Snippet 2'); // 2 uses
      expect(frequent[2].name, 'Snippet 1'); // 1 use
    });

    test('getFrequent respects limit', () async {
      for (var i = 0; i < 5; i++) {
        await repository.insert(
          SnippetsCompanion.insert(name: 'Snippet $i', command: 'cmd$i'),
        );
      }

      final frequent = await repository.getFrequent(limit: 2);
      expect(frequent, hasLength(2));
    });

    test('getByFolder returns snippets with null folderId', () async {
      await repository.insert(
        SnippetsCompanion.insert(name: 'Root Snippet', command: 'ls'),
      );

      final snippets = await repository.getByFolder(null);
      expect(snippets, hasLength(1));
      expect(snippets.first.name, 'Root Snippet');
    });

    test('getByFolder returns snippets with specific folderId', () async {
      final folderId = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Test Folder'),
      );

      await repository.insert(
        SnippetsCompanion.insert(
          name: 'Folder Snippet',
          command: 'ls',
          folderId: Value(folderId),
        ),
      );
      await repository.insert(
        SnippetsCompanion.insert(name: 'Root Snippet', command: 'pwd'),
      );

      final snippets = await repository.getByFolder(folderId);
      expect(snippets, hasLength(1));
      expect(snippets.first.name, 'Folder Snippet');
    });

    test('watchAll emits updates', () async {
      await repository.insert(
        SnippetsCompanion.insert(name: 'New Snippet', command: 'test'),
      );

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchByFolder emits for null folder', () async {
      await repository.insert(
        SnippetsCompanion.insert(name: 'Root Snippet', command: 'ls'),
      );

      final stream = repository.watchByFolder(null);
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchByFolder emits for specific folder', () async {
      final folderId = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Test Folder'),
      );

      await repository.insert(
        SnippetsCompanion.insert(
          name: 'Folder Snippet',
          command: 'ls',
          folderId: Value(folderId),
        ),
      );

      final stream = repository.watchByFolder(folderId);
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });
  });

  group('SnippetRepository - Folders', () {
    test('getAllFolders returns empty list initially', () async {
      final folders = await repository.getAllFolders();
      expect(folders, isEmpty);
    });

    test('insertFolder creates a new folder', () async {
      final id = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'My Folder'),
      );

      expect(id, greaterThan(0));

      final folders = await repository.getAllFolders();
      expect(folders, hasLength(1));
      expect(folders.first.name, 'My Folder');
    });

    test('updateFolder modifies existing folder', () async {
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Original Folder'),
      );

      final folders = await repository.getAllFolders();
      final folder = folders.first;
      final success = await repository.updateFolder(
        folder.copyWith(name: 'Updated Folder'),
      );

      expect(success, isTrue);

      final updated = await repository.getAllFolders();
      expect(updated.first.name, 'Updated Folder');
    });

    test('deleteFolder removes folder', () async {
      final id = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'To Delete'),
      );

      final deleted = await repository.deleteFolder(id);
      expect(deleted, 1);

      final folders = await repository.getAllFolders();
      expect(folders, isEmpty);
    });

    test('deleteFolder returns 0 when folder not exists', () async {
      final deleted = await repository.deleteFolder(999);
      expect(deleted, 0);
    });

    test('watchAllFolders emits updates', () async {
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'New Folder'),
      );

      final stream = repository.watchAllFolders();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('nested folders work with parentId', () async {
      final parentId = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Parent'),
      );
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(
          name: 'Child',
          parentId: Value(parentId),
        ),
      );

      final folders = await repository.getAllFolders();
      expect(folders, hasLength(2));

      final child = folders.firstWhere((f) => f.name == 'Child');
      expect(child.parentId, parentId);
    });
  });
}
