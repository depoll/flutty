// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/group_repository.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/sync_vault_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/hosts_screen.dart';

class _MockSyncVaultService extends Mock implements SyncVaultService {}

class _MockHostRepository extends Mock implements HostRepository {}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{};

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) => const [];

  @override
  ActiveConnection? getActiveConnection(int connectionId) => null;
}

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

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

  testWidgets('pull to refresh runs encrypted sync when enabled', (
    tester,
  ) async {
    final syncVaultService = _MockSyncVaultService();
    when(syncVaultService.getStatus).thenAnswer(
      (_) async => const SyncVaultStatus(enabled: true, hasRecoveryKey: true),
    );
    when(syncVaultService.syncNow).thenAnswer(
      (_) async => const SyncVaultSyncResult(
        outcome: SyncVaultSyncOutcome.noChanges,
        message: 'Encrypted sync is already up to date',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncVaultServiceProvider.overrideWithValue(syncVaultService),
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allGroupsProvider.overrideWith((ref) => Stream.value(<Group>[])),
          allHostsProvider.overrideWith(
            (ref) => Stream.value([
              Host(
                id: 1,
                label: 'Production',
                hostname: 'prod.example.com',
                port: 22,
                username: 'root',
                password: null,
                keyId: null,
                groupId: null,
                jumpHostId: null,
                isFavorite: false,
                color: null,
                notes: null,
                tags: null,
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
                lastConnectedAt: null,
                terminalThemeLightId: null,
                terminalThemeDarkId: null,
                terminalFontFamily: null,
                autoConnectCommand: null,
                autoConnectSnippetId: null,
                autoConnectRequiresConfirmation: false,
                sortOrder: 0,
              ),
            ]),
          ),
        ],
        child: const MaterialApp(home: HostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Reorder').first, findsOneWidget);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    verify(syncVaultService.getStatus).called(1);
    verify(syncVaultService.syncNow).called(1);
    expect(find.text('Encrypted sync is already up to date'), findsOneWidget);
  });

  testWidgets('reordering hosts persists the new order', (tester) async {
    final hostRepository = _MockHostRepository();
    when(() => hostRepository.reorderByIds(any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allGroupsProvider.overrideWith((ref) => Stream.value(<Group>[])),
          allHostsProvider.overrideWith(
            (ref) => Stream.value([
              Host(
                id: 1,
                label: 'Alpha',
                hostname: 'alpha.example.com',
                port: 22,
                username: 'root',
                password: null,
                keyId: null,
                groupId: null,
                jumpHostId: null,
                isFavorite: false,
                color: null,
                notes: null,
                tags: null,
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
                lastConnectedAt: null,
                terminalThemeLightId: null,
                terminalThemeDarkId: null,
                terminalFontFamily: null,
                autoConnectCommand: null,
                autoConnectSnippetId: null,
                autoConnectRequiresConfirmation: false,
                sortOrder: 0,
              ),
              Host(
                id: 2,
                label: 'Beta',
                hostname: 'beta.example.com',
                port: 22,
                username: 'root',
                password: null,
                keyId: null,
                groupId: null,
                jumpHostId: null,
                isFavorite: false,
                color: null,
                notes: null,
                tags: null,
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
                lastConnectedAt: null,
                terminalThemeLightId: null,
                terminalThemeDarkId: null,
                terminalFontFamily: null,
                autoConnectCommand: null,
                autoConnectSnippetId: null,
                autoConnectRequiresConfirmation: false,
                sortOrder: 1,
              ),
            ]),
          ),
        ],
        child: const MaterialApp(home: HostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Reorder'), findsNWidgets(2));

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorder(0, 2);
    await tester.pumpAndSettle();

    verify(() => hostRepository.reorderByIds([2, 1])).called(1);
  });
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
