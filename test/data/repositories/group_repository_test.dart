// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutty/data/database/database.dart';
import 'package:flutty/data/repositories/group_repository.dart';

void main() {
  late AppDatabase db;
  late GroupRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = GroupRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('GroupRepository', () {
    test('getAll returns empty list initially', () async {
      final groups = await repository.getAll();
      expect(groups, isEmpty);
    });

    test('insert creates a new group', () async {
      final id = await repository.insert(
        GroupsCompanion.insert(name: 'Production'),
      );

      expect(id, greaterThan(0));

      final groups = await repository.getAll();
      expect(groups, hasLength(1));
      expect(groups.first.name, 'Production');
    });

    test('getById returns group when exists', () async {
      final id = await repository.insert(
        GroupsCompanion.insert(name: 'Development'),
      );

      final group = await repository.getById(id);

      expect(group, isNotNull);
      expect(group!.id, id);
      expect(group.name, 'Development');
    });

    test('getById returns null when not exists', () async {
      final group = await repository.getById(999);
      expect(group, isNull);
    });

    test('update modifies existing group', () async {
      final id = await repository.insert(
        GroupsCompanion.insert(name: 'Original'),
      );

      final group = await repository.getById(id);
      final success = await repository.update(group!.copyWith(name: 'Updated'));

      expect(success, isTrue);

      final updated = await repository.getById(id);
      expect(updated!.name, 'Updated');
    });

    test('delete removes group', () async {
      final id = await repository.insert(
        GroupsCompanion.insert(name: 'To Delete'),
      );

      final deleted = await repository.delete(id);
      expect(deleted, 1);

      final group = await repository.getById(id);
      expect(group, isNull);
    });

    test('delete returns 0 when group not exists', () async {
      final deleted = await repository.delete(999);
      expect(deleted, 0);
    });

    test('getRootGroups returns groups without parent', () async {
      await repository.insert(GroupsCompanion.insert(name: 'Root Group'));

      final roots = await repository.getRootGroups();
      expect(roots, hasLength(1));
      expect(roots.first.name, 'Root Group');
      expect(roots.first.parentId, isNull);
    });

    test('getChildren returns child groups', () async {
      final parentId = await repository.insert(
        GroupsCompanion.insert(name: 'Parent'),
      );
      await repository.insert(
        GroupsCompanion.insert(name: 'Child 1', parentId: Value(parentId)),
      );
      await repository.insert(
        GroupsCompanion.insert(name: 'Child 2', parentId: Value(parentId)),
      );

      final children = await repository.getChildren(parentId);
      expect(children, hasLength(2));
    });

    test('getChildren returns empty for group with no children', () async {
      final id = await repository.insert(
        GroupsCompanion.insert(name: 'Leaf Group'),
      );

      final children = await repository.getChildren(id);
      expect(children, isEmpty);
    });

    test('nested groups maintain hierarchy', () async {
      final level1 = await repository.insert(
        GroupsCompanion.insert(name: 'Level 1'),
      );
      final level2 = await repository.insert(
        GroupsCompanion.insert(name: 'Level 2', parentId: Value(level1)),
      );
      await repository.insert(
        GroupsCompanion.insert(name: 'Level 3', parentId: Value(level2)),
      );

      final roots = await repository.getRootGroups();
      expect(roots, hasLength(1));
      expect(roots.first.name, 'Level 1');

      final level1Children = await repository.getChildren(level1);
      expect(level1Children, hasLength(1));
      expect(level1Children.first.name, 'Level 2');

      final level2Children = await repository.getChildren(level2);
      expect(level2Children, hasLength(1));
      expect(level2Children.first.name, 'Level 3');
    });

    test('watchAll emits updates', () async {
      await repository.insert(GroupsCompanion.insert(name: 'New Group'));

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchRootGroups emits updates', () async {
      await repository.insert(GroupsCompanion.insert(name: 'Root Group'));

      final stream = repository.watchRootGroups();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchChildren emits updates', () async {
      final parentId = await repository.insert(
        GroupsCompanion.insert(name: 'Parent'),
      );
      await repository.insert(
        GroupsCompanion.insert(name: 'Child', parentId: Value(parentId)),
      );

      final stream = repository.watchChildren(parentId);
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('insert multiple groups', () async {
      await repository.insert(GroupsCompanion.insert(name: 'Group 1'));
      await repository.insert(GroupsCompanion.insert(name: 'Group 2'));
      await repository.insert(GroupsCompanion.insert(name: 'Group 3'));

      final groups = await repository.getAll();
      expect(groups, hasLength(3));
    });

    test('update returns false when group not exists', () async {
      final fakeGroup = Group(
        id: 999,
        name: 'Fake Group',
        sortOrder: 0,
        createdAt: DateTime.now(),
      );

      final success = await repository.update(fakeGroup);
      expect(success, isFalse);
    });
  });
}
