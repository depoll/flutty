// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/terminal_port_forwards_sheet.dart';

class _MockPortForwardRepository extends Mock
    implements PortForwardRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _LiveTestSession extends SshSession {
  _LiveTestSession({
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

  final Map<int, ActiveTunnelInfo> tunnels = {};
  final changes = StreamController<void>.broadcast();
  final List<int> starts = [];
  final List<int> stops = [];

  @override
  List<ActiveTunnelInfo> get activeTunnels => tunnels.values.toList();

  @override
  Stream<void> get portForwardChanges => changes.stream;

  @override
  Future<bool> startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    starts.add(portForwardId);
    tunnels[portForwardId] = ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: localHost,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      isLocal: true,
    );
    changes.add(null);
    return true;
  }

  @override
  Future<bool> startRemoteForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String localHost,
    required int localPort,
  }) async {
    starts.add(portForwardId);
    tunnels[portForwardId] = ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: localHost,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      isLocal: false,
    );
    changes.add(null);
    return true;
  }

  @override
  Future<void> stopForward(int portForwardId) async {
    stops.add(portForwardId);
    tunnels.remove(portForwardId);
    changes.add(null);
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
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  List<int> getConnectionsForHost(int hostId) =>
      hostId == session.hostId ? [session.connectionId] : const [];
}

PortForward _portForward() => PortForward(
  id: 1,
  name: 'Web preview',
  hostId: 10,
  forwardType: 'local',
  localHost: '127.0.0.1',
  localPort: 8080,
  remoteHost: 'localhost',
  remotePort: 3000,
  autoStart: true,
  createdAt: DateTime(2026),
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
      ),
    );
  });

  testWidgets('live switch starts and stops the current session rule', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final repository = _MockPortForwardRepository();
    final insertCompleter = Completer<int>();
    final session = _LiveTestSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(session.changes.close);
    when(
      () => repository.watchByHostId(session.hostId),
    ).thenAnswer((_) => Stream.value([_portForward()]));
    when(
      () => repository.insert(any()),
    ).thenAnswer((_) => insertCompleter.future);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          portForwardRepositoryProvider.overrideWithValue(repository),
          activeSessionsProvider.overrideWith(
            () => _TestActiveSessionsNotifier(session),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => unawaited(
                  showTerminalPortForwardsSheet(
                    context: context,
                    hostId: session.hostId,
                    connectionId: session.connectionId,
                    session: session,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Port Forwards'), findsOneWidget);
    expect(find.text('Web preview'), findsOneWidget);
    expect(find.text('Stopped • Auto-start'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(session.starts, [1]);
    expect(find.text('Active now • Auto-start'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(session.stops, [1]);
    expect(find.text('Stopped • Auto-start'), findsOneWidget);

    await tester.tap(find.text('Add Forward'));
    await tester.pumpAndSettle();

    expect(find.text('Add Port Forward'), findsOneWidget);
    expect(find.text('Forward Type'), findsOneWidget);
    expect(find.text('Remote'), findsWidgets);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet).last).enableDrag,
      isFalse,
    );

    await tester.tap(find.text('Remote').first);
    await tester.pump();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Database');
    await tester.enterText(fields.at(1), '127.0.0.1');
    await tester.enterText(fields.at(2), '5432');
    await tester.enterText(fields.at(3), '0.0.0.0');
    await tester.enterText(fields.at(4), '15432');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Expose remote port forward?'), findsOneWidget);
    expect(
      find.textContaining('devices that can access the SSH host'),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Add Port Forward'), findsOneWidget);

    insertCompleter.complete(11);
    await tester.pumpAndSettle();

    expect(session.starts, [1, 11]);
    expect(find.text('Port forward added and started'), findsOneWidget);
    final inserted =
        verify(() => repository.insert(captureAny())).captured.single
            as PortForwardsCompanion;
    expect(inserted.forwardType.value, 'remote');
  });
}
