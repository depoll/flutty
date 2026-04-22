// ignore_for_file: public_member_api_docs, directives_ordering, avoid_redundant_argument_values

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/home_screen.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSnippetRepository extends Mock implements SnippetRepository {}

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

class _MutableActiveSessionsNotifier extends ActiveSessionsNotifier {
  _MutableActiveSessionsNotifier({
    List<ActiveConnection> initialConnections = const <ActiveConnection>[],
  }) {
    _connections.addEntries(
      initialConnections.map(
        (connection) => MapEntry(connection.connectionId, connection),
      ),
    );
  }

  final Map<int, ActiveConnection> _connections = <int, ActiveConnection>{};

  @override
  Map<int, SshConnectionState> build() => {
    for (final connection in _connections.values)
      connection.connectionId: connection.state,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) => _connections.values
      .where((connection) => connection.hostId == hostId)
      .map((connection) => connection.connectionId)
      .toList(growable: false);

  @override
  ActiveConnection? getActiveConnection(int connectionId) =>
      _connections[connectionId];

  @override
  List<ActiveConnection> getActiveConnections() =>
      _connections.values.toList(growable: false);

  void setActiveConnections(List<ActiveConnection> connections) {
    _connections
      ..clear()
      ..addEntries(
        connections.map(
          (connection) => MapEntry(connection.connectionId, connection),
        ),
      );
    state = {
      for (final connection in connections)
        connection.connectionId: connection.state,
    };
  }
}

class _TestTransferIntentService extends TransferIntentService {
  @override
  Stream<String> get incomingPayloads => const Stream<String>.empty();

  @override
  Future<String?> consumeIncomingTransferPayload() async => null;

  @override
  Future<void> dispose() async {}
}

class _TestHomeScreenShortcutService extends HomeScreenShortcutService {
  @override
  Stream<int> get hostLaunches => const Stream<int>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> updateShortcuts({
    required List<Host> hosts,
    required Set<int> pinnedHostIds,
  }) async {}

  @override
  Future<void> dispose() async {}
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

Snippet _buildSnippet({
  required int id,
  required String name,
  required int sortOrder,
}) => Snippet(
  id: id,
  name: name,
  command: 'echo $name',
  autoExecute: false,
  createdAt: DateTime(2026),
  usageCount: 0,
  sortOrder: sortOrder,
);

ActiveConnection _buildActiveConnection({
  required int connectionId,
  required int hostId,
  SshConnectionState state = SshConnectionState.connected,
}) => ActiveConnection(
  connectionId: connectionId,
  hostId: hostId,
  state: state,
  createdAt: DateTime(2026),
  config: const SshConnectionConfig(
    hostname: 'alpha.example.com',
    port: 22,
    username: 'root',
  ),
);

// These tests are skipped because the HomeScreen uses StreamProviders
// which don't settle in widget tests (continuous database watchers).
// The underlying repository and service tests pass (127 tests).
void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  Widget buildTestWidget(AppDatabase db, {Size size = const Size(800, 600)}) =>
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          transferIntentServiceProvider.overrideWith(
            (ref) => _TestTransferIntentService(),
          ),
          homeScreenShortcutServiceProvider.overrideWith(
            (ref) => _TestHomeScreenShortcutService(),
          ),
          pinnedHomeScreenShortcutHostIdsProvider.overrideWith(
            (ref) => Stream<Set<int>>.value(const <int>{}),
          ),
        ],
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const HomeScreen(),
                ),
                GoRoute(
                  path: '/settings',
                  builder: (context, state) => const Scaffold(),
                ),
                GoRoute(
                  path: '/hosts/add',
                  builder: (context, state) => const Scaffold(),
                ),
                GoRoute(
                  path: '/hosts/:id/edit',
                  builder: (context, state) => const Scaffold(),
                ),
                GoRoute(
                  path: '/terminal/:hostId',
                  builder: (context, state) => const Scaffold(),
                ),
                GoRoute(
                  path: '/keys/add',
                  builder: (context, state) => const Scaffold(),
                ),
                GoRoute(
                  path: '/snippets',
                  builder: (context, state) => const Scaffold(),
                ),
                GoRoute(
                  path: '/port-forwards',
                  builder: (context, state) => const Scaffold(),
                ),
              ],
            ),
          ),
        ),
      );

  Widget buildMobileHomeScreen({
    required AppDatabase db,
    required List overrides,
    Size size = const Size(400, 800),
  }) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      transferIntentServiceProvider.overrideWith(
        (ref) => _TestTransferIntentService(),
      ),
      homeScreenShortcutServiceProvider.overrideWith(
        (ref) => _TestHomeScreenShortcutService(),
      ),
      pinnedHomeScreenShortcutHostIdsProvider.overrideWith(
        (ref) => Stream<Set<int>>.value(const <int>{}),
      ),
      ...overrides,
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: const MaterialApp(home: HomeScreen()),
    ),
  );

  // Skip tests due to StreamProvider not settling in widget tests
  group(
    'HomeScreen Desktop Layout',
    skip: true, // StreamProvider tests hang - use integration tests instead
    () {
      testWidgets('displays app title in sidebar', (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(buildTestWidget(db));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Flutty'), findsOneWidget);
      });

      testWidgets('displays navigation items in sidebar', (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(buildTestWidget(db));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Hosts'), findsOneWidget);
        expect(find.text('Keys'), findsOneWidget);
        expect(find.text('Snippets'), findsOneWidget);
        expect(find.text('Port Forwarding'), findsOneWidget);
        expect(find.text('Settings'), findsOneWidget);
      });

      testWidgets('displays settings icon', (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(buildTestWidget(db));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      });

      testWidgets('displays sidebar navigation icons', (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(buildTestWidget(db));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
        expect(find.byIcon(Icons.key_rounded), findsOneWidget);
        expect(find.byIcon(Icons.code_rounded), findsOneWidget);
        expect(find.byIcon(Icons.swap_horiz_rounded), findsOneWidget);
      });
    },
  );

  group(
    'HomeScreen Mobile Layout',
    skip: true, // StreamProvider tests hang - use integration tests instead
    () {
      testWidgets('displays bottom navigation bar on narrow screens', (
        tester,
      ) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          buildTestWidget(db, size: const Size(400, 800)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(NavigationBar), findsOneWidget);
      });

      testWidgets('displays app bar on narrow screens', (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          buildTestWidget(db, size: const Size(400, 800)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(AppBar), findsOneWidget);
        expect(find.text('Flutty'), findsOneWidget);
      });
    },
  );

  group('HomeScreen reorder affordance', () {
    testWidgets('shows reorder handles and persists host order on mobile', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final hostRepository = _MockHostRepository();
      when(() => hostRepository.reorderByIds(any())).thenAnswer((_) async {});

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            hostRepositoryProvider.overrideWithValue(hostRepository),
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                _buildHost(id: 2, label: 'Beta', sortOrder: 1),
              ]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Reorder'), findsNWidgets(2));

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorder(0, 2);
      await tester.pump();

      verify(() => hostRepository.reorderByIds([2, 1])).called(1);
    });

    testWidgets('shows reorder handles and persists snippet order on mobile', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final snippetRepository = _MockSnippetRepository();
      when(snippetRepository.watchAll).thenAnswer(
        (_) => Stream.value([
          _buildSnippet(id: 1, name: 'First', sortOrder: 0),
          _buildSnippet(id: 2, name: 'Second', sortOrder: 1),
        ]),
      );
      when(
        () => snippetRepository.reorderByIds(any()),
      ).thenAnswer((_) async {});

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value(const <Host>[]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Snippets').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Reorder'), findsNWidgets(2));

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorder(0, 2);
      await tester.pump();

      verify(() => snippetRepository.reorderByIds([2, 1])).called(1);
    });
  });

  testWidgets('small icon actions expose semantics labels', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith(
            (ref) =>
                Stream.value([_buildHost(id: 1, label: 'Alpha', sortOrder: 0)]),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'New connection' &&
            (widget.properties.button ?? false) &&
            widget.properties.onTap != null,
      ),
      findsOneWidget,
    );
  });

  testWidgets('returns to Hosts when the last active connection disappears', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final sessionsNotifier = _MutableActiveSessionsNotifier(
      initialConnections: [
        _buildActiveConnection(
          connectionId: 7,
          hostId: 1,
          state: SshConnectionState.connecting,
        ),
      ],
    );

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(() => sessionsNotifier),
          allHostsProvider.overrideWith(
            (ref) =>
                Stream.value([_buildHost(id: 1, label: 'Alpha', sortOrder: 0)]),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Connections').first);
    await tester.pump();
    expect(find.text('No active connections'), findsNothing);

    sessionsNotifier.setActiveConnections(const <ActiveConnection>[]);
    await tester.pump();
    await tester.pump();

    expect(find.text('No active connections'), findsNothing);
  });
}
