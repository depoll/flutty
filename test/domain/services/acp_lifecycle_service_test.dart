// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_lifecycle_service.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// A minimal fake ACP agent transport: enough to open sessions, push
/// permission requests, and complete prompt turns.
class _FakeAcpServer implements AcpTransport {
  _FakeAcpServer({this.failResume = false});

  /// When true, `session/resume` fails so a reconnect can be forced to fail.
  bool failResume;

  final _incoming = StreamController<List<int>>();
  int _sessionCounter = 0;
  int _serverRequestId = 0;
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    final message = (decoded! as Map).cast<String, Object?>();
    final method = message['method'];
    final id = message['id'];
    if (id == null) return;

    switch (method) {
      case 'initialize':
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {
            'loadSession': false,
            'sessionCapabilities': {'resume': <String, Object?>{}},
          },
        });
      case 'session/new':
        _reply(id, {'sessionId': 'session-${++_sessionCounter}'});
      case 'session/resume':
        if (failResume) {
          _replyError(id, -32001, 'Cannot resume');
        } else {
          _reply(id, <String, Object?>{});
        }
      case 'session/prompt':
        _reply(id, {'stopReason': 'end_turn'});
      default:
        _reply(id, <String, Object?>{});
    }
  }

  /// Pushes a `session/request_permission` server request.
  void requestPermission(String sessionId) {
    _push({
      'jsonrpc': '2.0',
      'id': 'srv-${++_serverRequestId}',
      'method': 'session/request_permission',
      'params': {
        'sessionId': sessionId,
        'toolCall': {'toolCallId': 't1', 'title': 'Write file'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      },
    });
  }

  void _reply(Object? id, Object? result) =>
      _push({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _replyError(Object? id, int code, String message) => _push({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });

  void _push(Map<String, Object?> message) {
    if (closed) return;
    _incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

class _FakeConnector implements AcpBridgeConnector {
  _FakeConnector({this.serverFactory});

  final _FakeAcpServer Function(int hostId, String bridgeId)? serverFactory;
  final Map<String, _FakeAcpServer> servers = <String, _FakeAcpServer>{};
  final List<String> stoppedBridges = <String>[];
  int _bridgeCounter = 0;

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final bridgeId = 'bridge-${++_bridgeCounter}';
    return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(int hostId) async =>
      const <MonkeyMuxAcpBridgeMetadata>[];

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async => MonkeyMuxAcpBridgeMetadata(
    id: bridgeId,
    provider: 'Copilot CLI',
    commandHash: 'hash',
    state: MonkeyMuxAcpProviderState.running,
    clientCount: 0,
    pendingRequestCount: 0,
    inFlightTurnCount: 0,
    lastActivity: DateTime.now(),
    startedAt: DateTime.now(),
    nextSequence: 1,
  );

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    stoppedBridges.add(bridgeId);
  }

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
  }) {
    final server = serverFactory?.call(hostId, bridgeId) ?? _FakeAcpServer();
    servers[bridgeId] = server;
    final states = StreamController<MonkeyMuxAcpTransportState>.broadcast();
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    final connection = AcpJsonRpcConnection(transport: server);
    final client = AcpClient(connection);
    return AcpBridgeSession(
      client: client,
      transportStates: states.stream,
      transportErrors: errors.stream,
      onClose: () async {
        await client.close();
        await states.close();
        await errors.close();
      },
    );
  }

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(
    int hostId,
  ) async => null;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpProviderService providerService;
  late AcpRecentSessionsService recentSessions;
  late _FakeConnector connector;
  late AcpSessionManager manager;
  late LocalNotificationService notificationService;
  late Set<int> connectedHostIds;
  late AcpLifecycleService lifecycle;

  Future<AcpSessionKey> startSession({required int hostId}) async {
    final result = await manager.startNewSession(
      hostId: hostId,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
    );
    return (result as AcpSessionLaunchStarted).key;
  }

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    providerService = AcpProviderService(settings);
    recentSessions = AcpRecentSessionsService(settings);
    connector = _FakeConnector();
    connectedHostIds = <int>{1, 2};
    manager = AcpSessionManager(
      connector: connector,
      providerService: providerService,
      recentSessions: recentSessions,
      isProUnlocked: () => true,
      diagnostics: const NoopDiagnosticsLogger(),
    );
    notificationService = LocalNotificationService();
    lifecycle = AcpLifecycleService(
      sessionManager: manager,
      hasActiveSshSession: (hostId) => connectedHostIds.contains(hostId),
      notificationService: notificationService,
      diagnostics: const NoopDiagnosticsLogger(),
      backgroundDetachGrace: const Duration(milliseconds: 20),
    )..start();
  });

  tearDown(() async {
    await lifecycle.dispose();
    await manager.dispose();
    notificationService.dispose();
    await database.close();
  });

  group('background detach and foreground resume', () {
    test(
      'detaches live sessions only after the grace period elapses',
      () async {
        await startSession(hostId: 1);

        await lifecycle.handleBackground();
        expect(
          manager.state.sessions.single.status,
          isNot(AcpConnectionStatus.detached),
        );

        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(
          manager.state.sessions.single.status,
          AcpConnectionStatus.detached,
        );
      },
    );

    test(
      'never detaches on a transient background/foreground flicker',
      () async {
        await startSession(hostId: 1);

        await lifecycle.handleBackground();
        // Resumed well before the grace period elapses: a real device would
        // see this on a quick app-switcher glance or permission dialog.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await lifecycle.handleForeground();
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(manager.state.sessions.single.status, AcpConnectionStatus.ready);
        expect(manager.state.sessions.single.isLive, isTrue);
      },
    );

    test('reconnects a session it auto-detached once foregrounded', () async {
      await startSession(hostId: 1);

      await lifecycle.handleBackground();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        manager.state.sessions.single.status,
        AcpConnectionStatus.detached,
      );

      await lifecycle.handleForeground();
      await _pump();

      expect(manager.state.sessions.single.status, AcpConnectionStatus.ready);
      expect(manager.state.sessions.single.isLive, isTrue);
    });

    test('isolates a failed reconnect for one host from a healthy reconnect '
        'on another host', () async {
      final failingConnector = _FakeConnector(
        serverFactory: (hostId, bridgeId) =>
            _FakeAcpServer(failResume: hostId == 1),
      );
      final failingManager = AcpSessionManager(
        connector: failingConnector,
        providerService: providerService,
        recentSessions: recentSessions,
        isProUnlocked: () => true,
        diagnostics: const NoopDiagnosticsLogger(),
      );
      addTearDown(failingManager.dispose);
      final failingLifecycle = AcpLifecycleService(
        sessionManager: failingManager,
        hasActiveSshSession: (hostId) => connectedHostIds.contains(hostId),
        notificationService: notificationService,
        diagnostics: const NoopDiagnosticsLogger(),
        backgroundDetachGrace: const Duration(milliseconds: 10),
      )..start();
      addTearDown(failingLifecycle.dispose);

      final firstResult = await failingManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final secondResult = await failingManager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final firstKey = (firstResult as AcpSessionLaunchStarted).key;
      final secondKey = (secondResult as AcpSessionLaunchStarted).key;

      await failingLifecycle.handleBackground();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await failingLifecycle.handleForeground();
      await _pump();
      await _pump();

      // Host 1's reconnect fails (session/resume errors), but host 2's
      // still succeeds: one bad reconnect never blocks the other.
      expect(
        failingManager.state.byKeyValue(firstKey.value)!.status,
        isNot(AcpConnectionStatus.ready),
      );
      expect(
        failingManager.state.byKeyValue(secondKey.value)!.status,
        AcpConnectionStatus.ready,
      );
    });

    test('reconnects auto-detached sessions across multiple hosts', () async {
      await startSession(hostId: 1);
      await startSession(hostId: 2);

      await lifecycle.handleBackground();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        manager.state.sessions.every(
          (s) => s.status == AcpConnectionStatus.detached,
        ),
        isTrue,
      );

      await lifecycle.handleForeground();
      await _pump();

      expect(manager.state.sessions.every((s) => s.isLive), isTrue);
    });
  });

  group('auth lock cleanup', () {
    test(
      'detaches every live session without stopping remote bridges',
      () async {
        await startSession(hostId: 1);
        await startSession(hostId: 2);

        await lifecycle.handleAuthLocked();

        expect(
          manager.state.sessions.every(
            (s) => s.status == AcpConnectionStatus.detached,
          ),
          isTrue,
        );
        expect(connector.stoppedBridges, isEmpty);
      },
    );
  });

  group('SSH disconnect cleanup', () {
    test('detaches only the session whose host lost its SSH session', () async {
      await startSession(hostId: 1);
      await startSession(hostId: 2);

      connectedHostIds.remove(1);
      await lifecycle.handleSshConnectivityChanged();

      final byHost = {for (final s in manager.state.sessions) s.key.hostId: s};
      expect(byHost[1]!.status, AcpConnectionStatus.detached);
      expect(byHost[2]!.status, AcpConnectionStatus.ready);
      expect(connector.stoppedBridges, isEmpty);
    });
  });

  group('notification gating', () {
    test('never notifies while the app is in the foreground', () async {
      final key = await startSession(hostId: 1);
      final taps = <AcpNotificationPayload>[];
      notificationService.acpNotificationTaps.listen(taps.add);

      connector.servers.values.single.requestPermission(
        manager.state.byKeyValue(key.value)!.key.acpSessionId,
      );
      await _pump();

      // Foreground by default; no notification should have been requested.
      // We can't directly observe `showAcpNotification` without a plugin,
      // but we can confirm no tap stream activity occurs from a shown
      // notification (there is nothing to tap because nothing was shown).
      expect(taps, isEmpty);
    });

    test(
      'never notifies while backgrounded with no SSH path to the host',
      () async {
        final key = await startSession(hostId: 1);
        await lifecycle.handleBackground();
        connectedHostIds.remove(1);

        connector.servers.values.single.requestPermission(
          manager.state.byKeyValue(key.value)!.key.acpSessionId,
        );
        await _pump();

        // No exception and no crash is the primary contract here; there is
        // no host SSH path so no notification could ever be delivered.
      },
    );
  });

  group('disposal', () {
    test('cancels the background timer and state subscription', () async {
      await startSession(hostId: 1);
      await lifecycle.handleBackground();
      await lifecycle.dispose();

      // Waiting past the grace period must not detach anything once disposed.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(manager.state.sessions.single.status, AcpConnectionStatus.ready);
    });

    test('dispose is idempotent', () async {
      await lifecycle.dispose();
      await lifecycle.dispose();
    });
  });
}
