// ignore_for_file: public_member_api_docs, directives_ordering, avoid_redundant_argument_values

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/providers/host_row_providers.dart';
import 'package:monkeyssh/presentation/screens/home_screen.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSnippetRepository extends Mock implements SnippetRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockTmuxService extends Mock implements TmuxService {}

class _MockAgentSessionDiscoveryService extends Mock
    implements AgentSessionDiscoveryService {}

class _MockMonetizationService extends Mock implements MonetizationService {}

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
    List<SshSession> initialSessions = const <SshSession>[],
  }) {
    _connections.addEntries(
      initialConnections.map(
        (connection) => MapEntry(connection.connectionId, connection),
      ),
    );
    _sessions.addEntries(
      initialSessions.map((session) => MapEntry(session.connectionId, session)),
    );
  }

  final Map<int, ActiveConnection> _connections = <int, ActiveConnection>{};
  final Map<int, SshSession> _sessions = <int, SshSession>{};

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
  SshSession? getSession(int connectionId) => _sessions[connectionId];

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

  void setSessions(List<SshSession> sessions) {
    _sessions
      ..clear()
      ..addEntries(
        sessions.map((session) => MapEntry(session.connectionId, session)),
      );
    state = {...state};
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
  String? autoConnectCommand,
  String? tmuxSessionName,
  String? tmuxExtraFlags,
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
  autoConnectCommand: autoConnectCommand,
  autoConnectSnippetId: null,
  autoConnectRequiresConfirmation: false,
  tmuxSessionName: tmuxSessionName,
  tmuxWorkingDirectory: null,
  tmuxExtraFlags: tmuxExtraFlags,
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

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
    registerFallbackValue(MonetizationFeature.agentLaunchPresets);
  });

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
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => Stream.value(const <SnippetFolder>[]));
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

  group('HomeScreen empty states', () {
    testWidgets('hosts empty state offers first-run actions', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
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

      expect(find.text('No hosts yet'), findsOneWidget);
      expect(find.text('Import config'), findsNothing);
      expect(find.text('Paste SSH URL'), findsOneWidget);
      expect(find.text('Try local test host'), findsNothing);
    });

    testWidgets('connections empty state explains where sessions appear', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
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

      await tester.tap(find.text('Connections').first);
      await tester.pump();

      expect(find.text('No active connections'), findsOneWidget);
      expect(
        find.textContaining('Connections appear here while terminals are open'),
        findsOneWidget,
      );
    });
  });

  testWidgets('context menu triggers expose semantics labels', (tester) async {
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
            widget.properties.label == 'Host actions' &&
            (widget.properties.button ?? false) &&
            widget.properties.onTap != null,
      ),
      findsOneWidget,
    );
  });

  testWidgets('updates the tmux badge when host session info loads later', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tmuxService = _MockTmuxService();
    final sshClient = _MockSshClient();
    final hostsController = StreamController<List<Host>>.broadcast();
    addTearDown(hostsController.close);

    final session = SshSession(
      connectionId: 7,
      hostId: 1,
      client: sshClient,
      config: const SshConnectionConfig(
        hostname: 'alpha.example.com',
        port: 22,
        username: 'root',
      ),
    );
    final sessionsNotifier = _MutableActiveSessionsNotifier(
      initialConnections: [_buildActiveConnection(connectionId: 7, hostId: 1)],
      initialSessions: [session],
    );

    when(() => tmuxService.isTmuxActive(session)).thenAnswer((_) async => true);
    when(
      () => tmuxService.currentSessionName(session),
    ).thenAnswer((_) async => 'wrong-session');
    when(
      () => tmuxService.hasSession(session, 'correct-session'),
    ).thenAnswer((_) async => true);
    when(
      () => tmuxService.watchWindowChanges(session, any()),
    ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
    when(() => tmuxService.listWindows(session, any())).thenAnswer(
      (_) async => const <TmuxWindow>[
        TmuxWindow(index: 0, name: 'editor', isActive: true),
      ],
    );

    hostsController.add(<Host>[]);

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(() => sessionsNotifier),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
          tmuxServiceProvider.overrideWithValue(tmuxService),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Connections').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('wrong-session · 1 windows'), findsOneWidget);

    hostsController.add([
      _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'correct-session',
      ),
    ]);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('correct-session · 1 windows'), findsOneWidget);
    expect(find.text('wrong-session · 1 windows'), findsNothing);
  });

  testWidgets(
    'ignores stale tmux retries after host session info loads later',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final tmuxService = _MockTmuxService();
      final sshClient = _MockSshClient();
      final hostsController = StreamController<List<Host>>.broadcast();
      addTearDown(hostsController.close);

      final delayedWindows = Completer<List<TmuxWindow>>();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'alpha.example.com',
          port: 22,
          username: 'root',
        ),
      );
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(connectionId: 7, hostId: 1),
        ],
        initialSessions: [session],
      );

      when(
        () => tmuxService.isTmuxActive(session),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.currentSessionName(session),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.hasSession(session, 'correct-session'),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.watchWindowChanges(session, any()),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, 'correct-session'),
      ).thenAnswer((_) => delayedWindows.future);

      hostsController.add(<Host>[]);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith((ref) => hostsController.stream),
            tmuxServiceProvider.overrideWithValue(tmuxService),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Connections').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      hostsController.add([
        _buildHost(
          id: 1,
          label: 'Alpha',
          sortOrder: 0,
          tmuxSessionName: 'correct-session',
        ),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pump(const Duration(seconds: 2));

      delayedWindows.complete(const <TmuxWindow>[
        TmuxWindow(index: 0, name: 'editor', isActive: true),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('correct-session · 1 windows'), findsOneWidget);
    },
  );

  testWidgets('refreshes tmux badge when host extra flags change', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tmuxService = _MockTmuxService();
    final sshClient = _MockSshClient();
    final hostsController = StreamController<List<Host>>.broadcast();
    addTearDown(hostsController.close);

    final session = SshSession(
      connectionId: 7,
      hostId: 1,
      client: sshClient,
      config: const SshConnectionConfig(
        hostname: 'alpha.example.com',
        port: 22,
        username: 'root',
      ),
    );
    final sessionsNotifier = _MutableActiveSessionsNotifier(
      initialConnections: [_buildActiveConnection(connectionId: 7, hostId: 1)],
      initialSessions: [session],
    );

    const oldFlags = '-S /tmp/old.sock';
    const newFlags = '-S /tmp/new.sock';
    when(
      () => tmuxService.hasSession(session, 'work', extraFlags: oldFlags),
    ).thenAnswer((_) async => true);
    when(
      () =>
          tmuxService.watchWindowChanges(session, 'work', extraFlags: oldFlags),
    ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
    when(
      () => tmuxService.listWindows(session, 'work', extraFlags: oldFlags),
    ).thenAnswer(
      (_) async => const <TmuxWindow>[
        TmuxWindow(index: 0, name: 'old-server', isActive: true),
      ],
    );
    when(
      () => tmuxService.hasSession(session, 'work', extraFlags: newFlags),
    ).thenAnswer((_) async => true);
    when(
      () =>
          tmuxService.watchWindowChanges(session, 'work', extraFlags: newFlags),
    ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
    when(
      () => tmuxService.listWindows(session, 'work', extraFlags: newFlags),
    ).thenAnswer(
      (_) async => const <TmuxWindow>[
        TmuxWindow(index: 0, name: 'new-server', isActive: true),
      ],
    );

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(() => sessionsNotifier),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
          tmuxServiceProvider.overrideWithValue(tmuxService),
        ],
      ),
    );
    await tester.pump();
    hostsController.add([
      _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'work',
        tmuxExtraFlags: oldFlags,
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Connections').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('work · 1 windows'), findsOneWidget);
    await tester.tap(find.text('work · 1 windows'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('old-server'), findsOneWidget);

    hostsController.add([
      _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'work',
        tmuxExtraFlags: newFlags,
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('new-server'), findsOneWidget);
    expect(find.text('old-server'), findsNothing);
    verify(
      () => tmuxService.listWindows(session, 'work', extraFlags: oldFlags),
    ).called(1);
    verify(
      () => tmuxService.listWindows(session, 'work', extraFlags: newFlags),
    ).called(1);
  });

  testWidgets(
    'home tmux badge uses latest host yolo preference when resuming a session',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settingsService = SettingsService(db);
      final cliLaunchPreferencesService = HostCliLaunchPreferencesService(
        settingsService,
      );
      final tmuxService = _MockTmuxService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final monetizationService = _MockMonetizationService();
      final sshClient = _MockSshClient();

      final host = _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'work',
      );
      final session = SshSession(
        connectionId: 7,
        hostId: host.id,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'alpha.example.com',
          port: 22,
          username: 'root',
        ),
      );
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(connectionId: 7, hostId: host.id),
        ],
        initialSessions: [session],
      );
      const codexSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'codex-session',
        workingDirectory: '/home/demo/project',
        summary: 'Resume codex work',
      );

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(
        () => monetizationService.states,
      ).thenAnswer((_) => Stream.value(_proMonetizationState));
      when(
        monetizationService.initialize,
      ).thenAnswer((_) => Future<void>.value());
      when(
        () => monetizationService.canUseFeature(any()),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.watchWindowChanges(session, 'work'),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(() => tmuxService.listWindows(session, 'work')).thenAnswer(
        (_) async => const <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
        ],
      );
      when(
        () => tmuxService.createWindow(
          session,
          'work',
          command: any(named: 'command'),
          name: any(named: 'name'),
          workingDirectory: any(named: 'workingDirectory'),
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer((invocation) {
        final toolName = invocation.namedArguments[#toolName] as String?;
        return Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(
            sessions: toolName == 'Codex'
                ? const <ToolSessionInfo>[codexSession]
                : const <ToolSessionInfo>[],
            attemptedTools: toolName == null ? const <String>[] : [toolName],
          ),
        );
      });
      when(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).thenReturn("codex --yolo resume 'codex-session'");

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            settingsServiceProvider.overrideWithValue(settingsService),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith((ref) => Stream.value([host])),
            tmuxServiceProvider.overrideWithValue(tmuxService),
            agentSessionDiscoveryServiceProvider.overrideWithValue(
              discoveryService,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Connections').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('work · 1 windows'), findsOneWidget);

      await cliLaunchPreferencesService.setPreferencesForHost(
        host.id,
        const HostCliLaunchPreferences(startInYoloMode: true),
      );

      await tester.tap(find.text('work · 1 windows'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('AI Sessions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Codex'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Resume codex work'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      verify(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).called(1);
      verify(
        () => tmuxService.createWindow(
          session,
          'work',
          command: "codex --yolo resume 'codex-session'",
          name: 'Codex',
          workingDirectory: '/home/demo/project',
          extraFlags: null,
        ),
      ).called(1);
    },
  );

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

  group('HostRowData value equality', () {
    test('equal when all fields are identical', () {
      const a = HostRowData(
        connectionIds: [1, 2],
        isConnected: true,
        isConnectionStarting: false,
        connectionAttemptMessage: null,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: true,
      );
      const b = HostRowData(
        connectionIds: [1, 2],
        isConnected: true,
        isConnectionStarting: false,
        connectionAttemptMessage: null,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: true,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('unequal when isConnected differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when connectionIds differ', () {
      const a = HostRowData(
        connectionIds: [1],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [2],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when connectionAttemptMessage differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: true,
        connectionAttemptMessage: 'Connecting…',
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: true,
        connectionAttemptMessage: 'Authenticating…',
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when isPinnedToHomeScreen differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: true,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('connectionCount reflects connectionIds length', () {
      const data = HostRowData(
        connectionIds: [10, 20, 30],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(data.connectionCount, 3);
    });
  });

  group('hostRowDataProvider per-host isolation', () {
    testWidgets(
      'host row shows connected indicator when its connection is active',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(
              connectionId: 1,
              hostId: 1,
              state: SshConnectionState.connected,
            ),
          ],
        );

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
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

        // Host 1 has a connection, shown with a count badge.
        expect(find.text('1'), findsOneWidget);
        // Host 2 has no connection badge.
        expect(find.text('2'), findsNothing);
      },
    );

    testWidgets(
      'adding a connection to host B does not remove host A connection badge',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(
              connectionId: 1,
              hostId: 1,
              state: SshConnectionState.connected,
            ),
          ],
        );

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
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

        expect(find.text('1'), findsOneWidget);

        // Add a connection for host 2. Host 1's badge must still be present.
        sessionsNotifier.setActiveConnections([
          _buildActiveConnection(
            connectionId: 1,
            hostId: 1,
            state: SshConnectionState.connected,
          ),
          _buildActiveConnection(
            connectionId: 2,
            hostId: 2,
            state: SshConnectionState.connected,
          ),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Both hosts should now show a connection count badge.
        expect(find.text('1'), findsNWidgets(2));
      },
    );
  });
}
