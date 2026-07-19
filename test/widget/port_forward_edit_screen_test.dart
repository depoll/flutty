// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/port_forward_edit_screen.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockPortForwardRepository extends Mock
    implements PortForwardRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _RecordingSshSession extends SshSession {
  _RecordingSshSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
  }) : super(
         config: const SshConnectionConfig(
           hostname: 'example.com',
           port: 22,
           username: 'user',
         ),
       );

  final List<int> starts = [];

  @override
  Future<bool> startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    starts.add(portForwardId);
    return true;
  }
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => {
    session.connectionId: SshConnectionState.connected,
  };

  @override
  List<int> getConnectionsForHost(int hostId) =>
      hostId == session.hostId ? [session.connectionId] : const [];

  @override
  SshConnectionState getState(int connectionId) =>
      connectionId == session.connectionId
      ? SshConnectionState.connected
      : SshConnectionState.disconnected;

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;
}

Host _host() => Host(
  id: 10,
  label: 'Dev box',
  hostname: 'example.com',
  username: 'user',
  port: 22,
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  sortOrder: 0,
);

void main() {
  setUpAll(() {
    registerFallbackValue(
      PortForwardsCompanion.insert(
        name: 'Fallback',
        hostId: 1,
        forwardType: 'local',
        localPort: 1,
        remoteHost: 'localhost',
        remotePort: 1,
        autoStart: const Value(false),
      ),
    );
  });

  testWidgets('auto-starts a new rule on the existing connection', (
    tester,
  ) async {
    final hostRepository = _MockHostRepository();
    final portForwardRepository = _MockPortForwardRepository();
    final session = _RecordingSshSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    when(hostRepository.getAll).thenAnswer((_) async => [_host()]);
    when(() => portForwardRepository.insert(any())).thenAnswer((_) async => 11);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: FilledButton(
              onPressed: () => context.push('/editor'),
              child: const Text('Open Editor'),
            ),
          ),
        ),
        GoRoute(
          path: '/editor',
          builder: (context, state) => const PortForwardEditScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            portForwardRepository,
          ),
          activeSessionsProvider.overrideWith(
            () => _TestActiveSessionsNotifier(session),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.text('Open Editor'));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dev box').last);
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Web preview');
    await tester.enterText(fields.at(2), '8080');
    await tester.enterText(fields.at(3), 'localhost');
    await tester.enterText(fields.at(4), '3000');
    await tester.ensureVisible(find.text('Auto-start'));
    tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(true);
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    final saveButton = find.bySubtype<FilledButton>();
    expect(saveButton, findsOneWidget);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    verify(() => portForwardRepository.insert(any())).called(1);
    expect(session.starts, [11]);
    expect(find.text('Port forward added and started'), findsOneWidget);
  });
}
