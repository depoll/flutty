// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
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

Host _buildHost({
  required int id,
  required String label,
  required int sortOrder,
}) => Host(
  id: id,
  label: label,
  hostname: '$label.example.com',
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
  sortOrder: sortOrder,
);

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  testWidgets('shows imported hosts after the provider updates', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final hostsController = StreamController<List<Host>>();
    addTearDown(hostsController.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
        ],
        child: const MaterialApp(home: HostsScreen()),
      ),
    );

    hostsController.add(const <Host>[]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No hosts yet'), findsOneWidget);

    hostsController.add([
      _buildHost(id: 1, label: 'Imported host', sortOrder: 0),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Imported host'), findsOneWidget);
  });

  testWidgets('pull to refresh runs encrypted sync when enabled', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

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
          databaseProvider.overrideWithValue(db),
          syncVaultServiceProvider.overrideWithValue(syncVaultService),
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith(
            (ref) => Stream.value([
              _buildHost(id: 1, label: 'Production', sortOrder: 0),
            ]),
          ),
        ],
        child: const MaterialApp(home: HostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    verify(syncVaultService.getStatus).called(1);
    verify(syncVaultService.syncNow).called(1);
    expect(find.text('Encrypted sync is already up to date'), findsOneWidget);
  });

  testWidgets('reordering hosts persists the new order', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final hostRepository = _MockHostRepository();
    when(() => hostRepository.reorderByIds(any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith(
            (ref) => Stream.value([
              _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              _buildHost(id: 2, label: 'Beta', sortOrder: 1),
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
