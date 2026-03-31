// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/group_repository.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/hosts_screen.dart';

void main() {
  group('normalizeSelectedGroupId', () {
    test('keeps the selected group when it still exists', () {
      final groups = [
        Group(
          id: 1,
          name: 'Production',
          sortOrder: 0,
          createdAt: DateTime(2026),
        ),
      ];

      final selectedGroupId = normalizeSelectedGroupId(
        selectedGroupId: 1,
        groups: groups,
      );

      expect(selectedGroupId, 1);
    });

    test('clears the selected group when imported data replaced group ids', () {
      final groups = [
        Group(
          id: 9,
          name: 'Production',
          sortOrder: 0,
          createdAt: DateTime(2026),
        ),
      ];

      final selectedGroupId = normalizeSelectedGroupId(
        selectedGroupId: 1,
        groups: groups,
      );

      expect(selectedGroupId, isNull);
    });
  });

  testWidgets(
    'clears stale selected groups after import-style provider invalidation',
    (tester) async {
      final fakeGroupRepository = FakeGroupRepository(
        initialGroups: [
          Group(
            id: 1,
            name: 'Production',
            sortOrder: 0,
            createdAt: DateTime(2026),
          ),
          Group(
            id: 2,
            name: 'Staging',
            sortOrder: 1,
            createdAt: DateTime(2026),
          ),
        ],
      );
      addTearDown(fakeGroupRepository.dispose);

      final harnessKey = GlobalKey<_HostsScreenHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupRepositoryProvider.overrideWithValue(fakeGroupRepository),
            allHostsProvider.overrideWith((ref) => Stream.value(<Host>[])),
          ],
          child: HostsScreenHarness(key: harnessKey),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Production').last);
      await tester.pumpAndSettle();

      fakeGroupRepository.replaceAll([
        Group(id: 2, name: 'Staging', sortOrder: 1, createdAt: DateTime(2026)),
      ]);

      harnessKey.currentState!.invalidateGroups();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Groups'));
      await tester.pumpAndSettle();

      final allHostsTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'All hosts'),
      );
      expect(allHostsTile.selected, isTrue);
      expect(find.text('Production'), findsNothing);
      expect(find.text('Staging'), findsOneWidget);
    },
  );
}

class HostsScreenHarness extends StatefulWidget {
  const HostsScreenHarness({super.key});

  @override
  State<HostsScreenHarness> createState() => _HostsScreenHarnessState();
}

class _HostsScreenHarnessState extends State<HostsScreenHarness> {
  bool _invalidateGroups = false;

  void invalidateGroups() {
    setState(() => _invalidateGroups = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidateGroups) {
      _invalidateGroups = false;
      ProviderScope.containerOf(context).invalidate(allGroupsProvider);
    }

    return const MaterialApp(home: HostsScreen());
  }
}

class FakeGroupRepository extends GroupRepository {
  factory FakeGroupRepository({required List<Group> initialGroups}) {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    return FakeGroupRepository._(database, initialGroups: initialGroups);
  }

  FakeGroupRepository._(this._database, {required List<Group> initialGroups})
    : _groups = List<Group>.unmodifiable(initialGroups),
      super(_database);

  final AppDatabase _database;
  final StreamController<List<Group>> _changes =
      StreamController<List<Group>>.broadcast();
  List<Group> _groups;

  void replaceAll(List<Group> groups) {
    _groups = List<Group>.unmodifiable(groups);
    _changes.add(_groups);
  }

  Future<void> dispose() async {
    await _changes.close();
    await _database.close();
  }

  @override
  Future<List<Group>> getAll() async => _groups;

  @override
  Stream<List<Group>> watchAll() => Stream.multi((controller) {
    controller.add(_groups);
    final subscription = _changes.stream.listen(controller.add);
    controller.onCancel = subscription.cancel;
  });
}
