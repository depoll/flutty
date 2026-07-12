// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// In-memory ACP agent that responds to a real [AcpClient] over NDJSON bytes
/// and can push server-initiated notifications and permission requests.
class _FakeAcpServer implements AcpTransport {
  _FakeAcpServer({
    this.supportsResume = true,
    this.supportsLoad = true,
    this.authMethods = const <Map<String, Object?>>[],
  });

  final bool supportsResume;
  final bool supportsLoad;
  final List<Map<String, Object?>> authMethods;

  final _incoming = StreamController<List<int>>();
  final List<String> methods = <String>[];
  final List<String> cancelledSessions = <String>[];
  final Map<Object, Object?> permissionResponses = <Object, Object?>{};
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

    if (method == null && id != null) {
      // A client response to one of our server requests.
      permissionResponses[id] = message['result'] ?? message['error'];
      return;
    }
    if (method is String) methods.add(method);

    if (id == null) {
      if (method == 'session/cancel') {
        final params = (message['params']! as Map).cast<String, Object?>();
        cancelledSessions.add(params['sessionId']! as String);
      }
      return;
    }

    switch (method) {
      case 'initialize':
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {
            'loadSession': supportsLoad,
            'sessionCapabilities': {
              if (supportsResume) 'resume': <String, Object?>{},
              'fork': <String, Object?>{},
              'close': <String, Object?>{},
              'delete': <String, Object?>{},
            },
          },
          if (authMethods.isNotEmpty) 'authMethods': authMethods,
        });
      case 'session/new':
        if (authMethods.isNotEmpty) {
          _replyError(id, -32000, 'Authentication required');
        } else {
          _reply(id, {'sessionId': 'session-${++_sessionCounter}'});
        }
      case 'session/fork':
        final sessionId = 'fork-${++_sessionCounter}';
        _reply(id, {'sessionId': sessionId});
      case 'session/resume':
      case 'session/load':
        _reply(id, <String, Object?>{});
      case 'session/prompt':
        _reply(id, {'stopReason': 'end_turn'});
      case 'session/set_config_option':
        _reply(id, {
          'configOptions': [
            {
              'type': 'boolean',
              'id': 'reasoning',
              'name': 'Reasoning',
              'value': true,
            },
          ],
        });
      case 'session/close':
      case 'session/delete':
        _reply(id, <String, Object?>{});
      default:
        _reply(id, <String, Object?>{});
    }
  }

  void pushUpdate(String sessionId, Map<String, Object?> update) {
    _push({
      'jsonrpc': '2.0',
      'method': 'session/update',
      'params': {'sessionId': sessionId, 'update': update},
    });
  }

  /// Sends a permission request and returns the server request id.
  Object requestPermission(String sessionId, String toolCallId) {
    final id = 'srv-${++_serverRequestId}';
    _push({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/request_permission',
      'params': {
        'sessionId': sessionId,
        'toolCall': {'toolCallId': toolCallId, 'title': 'Write file'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
        ],
      },
    });
    return id;
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

/// Fake connector that records bridge lifecycle calls and wires each bridge to
/// a controllable [_FakeAcpServer].
class _FakeConnector implements AcpBridgeConnector {
  _FakeConnector({this.serverFactory});

  final _FakeAcpServer Function(int hostId, String bridgeId)? serverFactory;

  final List<String> startedBridges = <String>[];
  final List<String> stoppedBridges = <String>[];
  final Map<String, _FakeAcpServer> servers = <String, _FakeAcpServer>{};
  final Map<String, StreamController<MonkeyMuxAcpTransportState>>
  transportStateControllers =
      <String, StreamController<MonkeyMuxAcpTransportState>>{};
  final Map<String, StreamController<MonkeyMuxAcpBridgeException>>
  transportErrorControllers =
      <String, StreamController<MonkeyMuxAcpBridgeException>>{};
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
    startedBridges.add(bridgeId);
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

  StreamController<MonkeyMuxAcpTransportState> statesFor(String bridgeId) =>
      transportStateControllers[bridgeId]!;

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
    transportStateControllers[bridgeId] = states;
    transportErrorControllers[bridgeId] = errors;
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
}

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpProviderService providerService;
  late AcpRecentSessionsService recentSessions;
  late _FakeConnector connector;
  late AcpSessionManager manager;
  var isPro = false;

  AcpSessionManager buildManager() => AcpSessionManager(
    connector: connector,
    providerService: providerService,
    recentSessions: recentSessions,
    isProUnlocked: () => isPro,
    diagnostics: const NoopDiagnosticsLogger(),
  );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    providerService = AcpProviderService(settings);
    recentSessions = AcpRecentSessionsService(settings);
    connector = _FakeConnector();
    isPro = false;
    manager = buildManager();
  });

  tearDown(() async {
    await manager.dispose();
    await database.close();
  });

  Future<AcpSessionKey> startCopilot({int hostId = 1}) async {
    final result = await manager.startNewSession(
      hostId: hostId,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
    );
    expect(result, isA<AcpSessionLaunchStarted>());
    return (result as AcpSessionLaunchStarted).key;
  }

  test('starts a new session and reaches ready', () async {
    final key = await startCopilot();
    final state = manager.state.byKeyValue(key.value)!;
    expect(state.status, AcpConnectionStatus.ready);
    expect(state.isLive, isTrue);
    expect(connector.startedBridges, hasLength(1));
    expect(manager.state.selectedKey, key.value);
  });

  test('records a non-content recent-session reference', () async {
    final key = await startCopilot();
    final recents = await recentSessions.list();
    expect(recents, hasLength(1));
    final ref = recents.single;
    expect(ref.acpSessionId, key.acpSessionId);
    expect(ref.hostId, 1);
    expect(ref.cwd, '/repo');
    // No content keys are ever stored.
    expect(ref.toJson().containsKey('messages'), isFalse);
  });

  test('refuses an unapproved custom provider command', () async {
    final definition = AcpCustomProviderDefinition.create(
      id: 'custom-1',
      label: 'My Agent',
      launchCommand: AcpLaunchCommand(executable: 'agent'),
    );
    await providerService.saveCustomProvider(
      definition.update(
        launchCommand: AcpLaunchCommand(
          executable: 'agent',
          arguments: const ['--changed'],
        ),
      ),
    );
    final result = await manager.startNewSession(
      hostId: 1,
      providerId: 'custom-1',
      cwd: '/repo',
    );
    expect(result, isA<AcpSessionLaunchFailed>());
    expect(
      (result as AcpSessionLaunchFailed).error.kind,
      AcpSessionErrorKind.commandNotApproved,
    );
    expect(connector.startedBridges, isEmpty);
  });

  group('concurrency', () {
    test('free tier blocks a second live session across hosts', () async {
      final first = await startCopilot();
      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchBlocked>());
      final blocked = result as AcpSessionLaunchBlocked;
      expect(blocked.decision.blockingSessionKeys, [first.value]);
      // No second bridge is started when blocked.
      expect(connector.startedBridges, hasLength(1));
    });

    test('pro tier allows multiple live sessions', () async {
      isPro = true;
      await startCopilot();
      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      expect(manager.liveSessionKeyValues, hasLength(2));
    });

    test('replace stops the blocking session and continues for free', () async {
      final first = await startCopilot();
      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
        replace: [first],
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      expect(connector.stoppedBridges, [first.bridgeId]);
      expect(manager.state.byKeyValue(first.value), isNull);
      expect(manager.liveSessionKeyValues, hasLength(1));
    });
  });

  group('streaming normalization', () {
    test('merges message chunks and tool calls into the timeline', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final id = key.acpSessionId;
      server
        ..pushUpdate(id, {
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'm1',
          'content': {'type': 'text', 'text': 'Hel'},
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'm1',
          'content': {'type': 'text', 'text': 'lo'},
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't1',
          'title': 'Read',
          'status': 'pending',
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 't1',
          'status': 'completed',
        });
      await _pump();
      final timeline = manager.state.byKeyValue(key.value)!.timeline;
      expect(timeline.entries, hasLength(2));
      final message = timeline.entries.whereType<AcpMessageEntry>().single;
      expect(message.content, hasLength(2));
      final tool = timeline.entries.whereType<AcpToolCallEntry>().single;
      expect(tool.status, isNotNull);
      expect(tool.status!.value, 'completed');
    });

    test('applies available-commands and config updates to state', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final id = key.acpSessionId;
      server
        ..pushUpdate(id, {
          'sessionUpdate': 'available_commands_update',
          'availableCommands': [
            {'name': 'review', 'description': 'Review code'},
          ],
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'usage_update',
          'used': 100,
          'size': 1000,
        });
      await _pump();
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.availableCommands.single.name, 'review');
      expect(state.usage?.used, 100);
    });

    test('ignores updates addressed to other sessions', () async {
      final key = await startCopilot();
      connector.servers[key.bridgeId]!.pushUpdate('some-other-session', {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'nope'},
      });
      await _pump();
      expect(manager.state.byKeyValue(key.value)!.timeline.isEmpty, isTrue);
    });
  });

  group('permissions', () {
    test('surfaces and resolves a pending permission', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final requestId = server.requestPermission(key.acpSessionId, 't1');
      await _pump();
      final pending = manager.state.byKeyValue(key.value)!.pendingPermissions;
      expect(pending, hasLength(1));
      expect(pending.single.toolCallId, 't1');

      await manager.respondToPermission(
        key,
        pending.single.requestKey,
        'allow',
      );
      await _pump();
      expect(manager.state.byKeyValue(key.value)!.pendingPermissions, isEmpty);
      expect(server.permissionResponses[requestId], isNotNull);
    });
  });

  group('prompt lifecycle', () {
    test('prompt returns a stop reason and clears streaming', () async {
      final key = await startCopilot();
      final result = await manager.prompt(key, [
        const AcpTextContent('Hi there'),
      ]);
      expect(result.stopReason.value, 'end_turn');
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.promptStatus, AcpPromptStatus.idle);
      expect(state.lastStopReason?.value, 'end_turn');
    });

    test('cancel notifies the agent', () async {
      final key = await startCopilot();
      await manager.cancelPrompt(key);
      final server = connector.servers[key.bridgeId]!;
      await _pump();
      expect(server.cancelledSessions, [key.acpSessionId]);
    });
  });

  group('lifecycle', () {
    test('detach keeps the remote bridge running', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.status, AcpConnectionStatus.detached);
      expect(state.isLive, isFalse);
      expect(connector.stoppedBridges, isEmpty);
    });

    test(
      'provider exit marks the session exited without stopping others',
      () async {
        isPro = true;
        final first = await startCopilot();
        final second = await startCopilot(hostId: 2);
        connector
            .statesFor(first.bridgeId)
            .add(
              MonkeyMuxAcpTransportState(
                status: MonkeyMuxAcpTransportStatus.providerExited,
                bridgeId: first.bridgeId,
                lastDeliveredSequence: 0,
              ),
            );
        await _pump();
        expect(
          manager.state.byKeyValue(first.value)!.status,
          AcpConnectionStatus.providerExited,
        );
        // The unrelated second session is untouched.
        expect(
          manager.state.byKeyValue(second.value)!.status,
          AcpConnectionStatus.ready,
        );
        expect(manager.state.byKeyValue(second.value)!.isLive, isTrue);
      },
    );

    test('stop stops the remote bridge and drops the session', () async {
      final key = await startCopilot();
      await manager.stopSession(key);
      expect(connector.stoppedBridges, [key.bridgeId]);
      expect(manager.state.byKeyValue(key.value), isNull);
    });

    test('reconnect resumes an existing bridge session', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      final result = await manager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.status, AcpConnectionStatus.ready);
      expect(state.isLive, isTrue);
    });

    test('fork creates a sibling session on the same bridge', () async {
      isPro = true;
      final key = await startCopilot();
      final result = await manager.forkSession(key);
      expect(result, isA<AcpSessionLaunchStarted>());
      final forkKey = (result as AcpSessionLaunchStarted).key;
      expect(forkKey.acpSessionId, isNot(key.acpSessionId));
      expect(forkKey.bridgeId, key.bridgeId);
      // The original remains tracked and live.
      expect(manager.state.byKeyValue(key.value)!.isLive, isTrue);
      expect(manager.state.byKeyValue(forkKey.value)!.isLive, isTrue);
    });
  });

  group('capability adaptation', () {
    AcpSessionManager managerFor(_FakeConnector custom) {
      final built = AcpSessionManager(
        connector: custom,
        providerService: providerService,
        recentSessions: recentSessions,
        isProUnlocked: () => isPro,
        diagnostics: const NoopDiagnosticsLogger(),
      );
      addTearDown(built.dispose);
      return built;
    }

    test(
      'surfaces authentication-required when the agent demands auth',
      () async {
        final authConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            authMethods: const [
              {'id': 'oauth', 'name': 'Sign in'},
            ],
          ),
        );
        final authManager = managerFor(authConnector);
        final result = await authManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        expect(result, isA<AcpSessionLaunchFailed>());
        expect(
          (result as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.authenticationRequired,
        );
      },
    );

    test('reconnects without resume/load by reusing the session id', () async {
      final plainConnector = _FakeConnector(
        serverFactory: (_, _) =>
            _FakeAcpServer(supportsResume: false, supportsLoad: false),
      );
      final plainManager = managerFor(plainConnector);
      final started = await plainManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      await plainManager.detachSession(key);
      final result = await plainManager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      final server = plainConnector.servers[key.bridgeId]!;
      expect(server.methods, isNot(contains('session/resume')));
      expect(server.methods, isNot(contains('session/load')));
    });
  });
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));
