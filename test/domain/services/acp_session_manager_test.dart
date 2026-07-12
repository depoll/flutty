// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_telemetry.dart';
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
    this.failNewSession = false,
    this.failEstablish = false,
    this.replayTextOnLoad,
    this.permissionIdOnLoad,
  });

  final bool supportsResume;
  final bool supportsLoad;
  final List<Map<String, Object?>> authMethods;

  /// When true, `session/new` replies with a JSON-RPC error.
  final bool failNewSession;

  /// When true, `session/resume` and `session/load` reply with an error.
  final bool failEstablish;

  /// When set, a `session/load` pushes an agent message chunk with this text
  /// BEFORE replying, simulating synchronous history replay during the load.
  final String? replayTextOnLoad;

  /// When set, a `session/load` pushes a permission request with this stable
  /// JSON-RPC id before replying, simulating a replayed pending permission.
  final String? permissionIdOnLoad;

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
        if (authMethods.isNotEmpty || failNewSession) {
          _replyError(id, -32000, 'Authentication required');
        } else {
          _reply(id, {'sessionId': 'session-${++_sessionCounter}'});
        }
      case 'session/fork':
        final sessionId = 'fork-${++_sessionCounter}';
        _reply(id, {'sessionId': sessionId});
      case 'session/resume':
        if (failEstablish) {
          _replyError(id, -32001, 'Cannot resume');
        } else {
          _reply(id, <String, Object?>{});
        }
      case 'session/load':
        if (failEstablish) {
          _replyError(id, -32001, 'Cannot load');
          break;
        }
        final params = (message['params']! as Map).cast<String, Object?>();
        final sessionId = params['sessionId'] as String? ?? '';
        // Emit synchronous replay BEFORE replying to the load request.
        if (replayTextOnLoad != null) {
          pushUpdate(sessionId, {
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'replay',
            'content': {'type': 'text', 'text': replayTextOnLoad},
          });
        }
        if (permissionIdOnLoad != null) {
          _pushPermission(permissionIdOnLoad!, sessionId, 'replay-tool');
        }
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

  /// Sends a permission request with an auto-allocated id and returns it.
  Object requestPermission(String sessionId, String toolCallId) {
    final id = 'srv-${++_serverRequestId}';
    _pushPermission(id, sessionId, toolCallId);
    return id;
  }

  void _pushPermission(String id, String sessionId, String toolCallId) {
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
  }

  /// Sends a server-to-client request with an auto-allocated id and returns
  /// that id. The client's eventual response lands in [permissionResponses].
  Object pushServerRequest(String method, Map<String, Object?> params) {
    final id = 'srv-${++_serverRequestId}';
    _push({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
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

/// Records every telemetry call for assertions without needing Firebase.
class _RecordingTelemetrySink implements AcpTelemetrySink {
  final events = <String>[];

  @override
  void featureOpened() => events.add('featureOpened');

  @override
  void sessionOpened({
    required String providerCategory,
    required bool isReconnect,
  }) => events.add('sessionOpened:$providerCategory:$isReconnect');

  @override
  void sessionEnded({required String reason}) =>
      events.add('sessionEnded:$reason');

  @override
  void reconnectOutcome({required bool succeeded, String? failureCategory}) =>
      events.add('reconnectOutcome:$succeeded:${failureCategory ?? ''}');

  @override
  void attachmentSent({required String category, required int count}) =>
      events.add('attachmentSent:$category:$count');

  @override
  void permissionOutcome({required String outcome}) =>
      events.add('permissionOutcome:$outcome');

  @override
  void failure({required String category}) => events.add('failure:$category');
}

/// Minimal in-memory filesystem used to test capability-service wiring.
class _FakeCapabilityFileSystem implements AcpRemoteFileSystem {
  final files = <String, Uint8List>{};
  final writes = <String, String>{};

  @override
  Future<String> canonicalizeExistingPath(String path) async => path;

  @override
  Future<String> canonicalizeWritePath(String path) async => path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    final bytes = files[path];
    if (bytes == null) {
      throw const AcpClientCapabilityException('Missing file');
    }
    return bytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    writes[path] = utf8.decode(bytes);
  }
}

/// Minimal terminal executor used only to satisfy [AcpHostCapabilityBinding]
/// in capability-wiring tests that do not exercise `terminal/*` methods.
class _FakeCapabilityTerminalExecutor implements AcpTerminalExecutor {
  @override
  Future<AcpTerminalProcess> start(String command) =>
      throw UnimplementedError();
}

/// Fake connector that records bridge lifecycle calls and wires each bridge to
/// a controllable [_FakeAcpServer].
class _FakeConnector implements AcpBridgeConnector {
  _FakeConnector({this.serverFactory, this.capabilityBinding});

  final _FakeAcpServer Function(int hostId, String bridgeId)? serverFactory;

  /// When set, returned for every [resolveCapabilityBinding] call, mirroring
  /// production wiring where the bridge attachment gets one same-host
  /// filesystem/terminal binding.
  final AcpHostCapabilityBinding? capabilityBinding;

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

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(
    int hostId,
  ) async => capabilityBinding;
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

  AcpSessionManager buildManagerWith(
    _FakeConnector custom, {
    AcpTelemetrySink telemetry = const NoopAcpTelemetrySink(),
  }) {
    final built = AcpSessionManager(
      connector: custom,
      providerService: providerService,
      recentSessions: recentSessions,
      isProUnlocked: () => isPro,
      diagnostics: const NoopDiagnosticsLogger(),
      telemetry: telemetry,
    );
    addTearDown(built.dispose);
    return built;
  }

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

  group('capability wiring', () {
    test('routes fs/read_text_file through the resolved binding instead of '
        'leaving it unanswered', () async {
      final fileSystem = _FakeCapabilityFileSystem()
        ..files['/repo/a.txt'] = Uint8List.fromList(utf8.encode('hello'));
      final capableConnector = _FakeConnector(
        capabilityBinding: AcpHostCapabilityBinding(
          fileSystem: fileSystem,
          terminalExecutor: _FakeCapabilityTerminalExecutor(),
        ),
      );
      final capableManager = buildManagerWith(capableConnector);
      final result = await capableManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      final server = capableConnector.servers[key.bridgeId]!;

      final requestId = server.pushServerRequest('fs/read_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/repo/a.txt',
      });
      await _pump();

      final response = server.permissionResponses[requestId];
      expect(response, isNotNull);
      expect((response! as Map)['content'], 'hello');
    });

    test(
      'declines fs/terminal requests safely when no binding is available',
      () async {
        final key = await startCopilot();
        final server = connector.servers[key.bridgeId]!;
        final requestId = server.pushServerRequest('fs/read_text_file', {
          'sessionId': key.acpSessionId,
          'path': '/repo/a.txt',
        });
        await _pump();
        final response = server.permissionResponses[requestId];
        expect(response, isNotNull);
        expect((response! as Map).containsKey('code'), isTrue);
      },
    );

    test('queues a pending write, surfaces it on session state, and '
        'approveWrite completes it', () async {
      final fileSystem = _FakeCapabilityFileSystem();
      final capableConnector = _FakeConnector(
        capabilityBinding: AcpHostCapabilityBinding(
          fileSystem: fileSystem,
          terminalExecutor: _FakeCapabilityTerminalExecutor(),
        ),
      );
      final capableManager = buildManagerWith(capableConnector);
      final result = await capableManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      final server = capableConnector.servers[key.bridgeId]!;

      final requestId = server.pushServerRequest('fs/write_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/repo/new.txt',
        'content': 'written content',
      });
      await _pump();

      final pendingWrites = capableManager.state
          .byKeyValue(key.value)!
          .pendingWrites;
      expect(pendingWrites, hasLength(1));
      expect(pendingWrites.single.path, '/repo/new.txt');

      await capableManager.approveWrite(key, pendingWrites.single.requestKey);
      await _pump();

      expect(fileSystem.writes['/repo/new.txt'], 'written content');
      expect(
        capableManager.state.byKeyValue(key.value)!.pendingWrites,
        isEmpty,
      );
      // A successful write responds with a null JSON-RPC result, so check
      // presence rather than non-null.
      expect(server.permissionResponses.containsKey(requestId), isTrue);
    });

    test(
      'rejectWrite declines without writing and clears the pending state',
      () async {
        final fileSystem = _FakeCapabilityFileSystem();
        final capableConnector = _FakeConnector(
          capabilityBinding: AcpHostCapabilityBinding(
            fileSystem: fileSystem,
            terminalExecutor: _FakeCapabilityTerminalExecutor(),
          ),
        );
        final capableManager = buildManagerWith(capableConnector);
        final result = await capableManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (result as AcpSessionLaunchStarted).key;

        capableConnector.servers[key.bridgeId]!.pushServerRequest(
          'fs/write_text_file',
          {
            'sessionId': key.acpSessionId,
            'path': '/repo/new.txt',
            'content': 'nope',
          },
        );
        await _pump();
        final requestKey = capableManager.state
            .byKeyValue(key.value)!
            .pendingWrites
            .single
            .requestKey;

        await capableManager.rejectWrite(key, requestKey);
        await _pump();

        expect(fileSystem.writes, isEmpty);
        expect(
          capableManager.state.byKeyValue(key.value)!.pendingWrites,
          isEmpty,
        );
      },
    );

    test('detaching locally leaves a pending permission unanswered so it can '
        'be replayed and answered after reconnect', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final requestId = server.requestPermission(key.acpSessionId, 't1');
      await _pump();

      await manager.detachSession(key);
      await _pump();

      // A soft/local detach must never answer the request on the agent's
      // behalf: the remote bridge keeps it pending until a real decision.
      expect(server.permissionResponses[requestId], isNull);
    });

    test('explicit stop cancels an unanswered pending permission because no '
        'one will ever answer it', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final requestId = server.requestPermission(key.acpSessionId, 't1');
      await _pump();

      await manager.stopSession(key);
      await _pump();

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
    AcpSessionManager managerFor(_FakeConnector custom) =>
        buildManagerWith(custom);

    test(
      'authentication-required stops the fresh bridge and leaves no session',
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
        // There is no authenticate/retry-on-existing-bridge path, so the
        // orphaned bridge is stopped just like any other failed creation. The
        // UI offers the provider's terminal-auth command and the user retries
        // cleanly.
        expect(authConnector.startedBridges, hasLength(1));
        expect(authConnector.stoppedBridges, authConnector.startedBridges);
        // No session or attachment is left tracked.
        expect(authManager.state.sessions, isEmpty);
        expect(authManager.liveSessionKeyValues, isEmpty);
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

  group('attachment lease', () {
    test('detach is idempotent and never double-releases', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      // A second detach must be a no-op and must not stop the bridge.
      await manager.detachSession(key);
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.detached,
      );
      expect(connector.stoppedBridges, isEmpty);
    });

    test(
      'detaching the original never stops a bridge still used by a fork',
      () async {
        isPro = true;
        final key = await startCopilot();
        final fork = await manager.forkSession(key);
        final forkKey = (fork as AcpSessionLaunchStarted).key;
        expect(forkKey.bridgeId, key.bridgeId);

        // Detach the original twice, then explicitly stop it.
        await manager.detachSession(key);
        await manager.detachSession(key);
        await manager.stopSession(key);

        // The shared bridge must not be stopped while the fork still uses it.
        expect(connector.stoppedBridges, isEmpty);
        expect(manager.state.byKeyValue(forkKey.value)!.isLive, isTrue);

        // Stopping the fork (the last user) finally stops the bridge once.
        await manager.stopSession(forkKey);
        expect(connector.stoppedBridges, [key.bridgeId]);
      },
    );
  });

  group('reconnect hardening', () {
    test(
      'repeated reconnect failures return typed errors and then recover',
      () async {
        var failEstablish = true;
        final flakyConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(failEstablish: failEstablish),
        );
        final flakyManager = buildManagerWith(flakyConnector);
        final started = await flakyManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;

        Future<AcpSessionLaunchResult> reconnect() async {
          await flakyManager.detachSession(key);
          return flakyManager.reconnectSession(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
            cwd: '/repo',
          );
        }

        final first = await reconnect();
        expect(first, isA<AcpSessionLaunchFailed>());
        expect(
          (first as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.protocol,
        );
        expect(
          flakyManager.state.byKeyValue(key.value)!.status,
          AcpConnectionStatus.failed,
        );

        final second = await reconnect();
        expect(second, isA<AcpSessionLaunchFailed>());

        // Leases stayed balanced across repeated failures: once the agent
        // recovers, a fresh reconnect succeeds and the session is live again.
        failEstablish = false;
        final third = await reconnect();
        expect(third, isA<AcpSessionLaunchStarted>());
        final state = flakyManager.state.byKeyValue(key.value)!;
        expect(state.status, AcpConnectionStatus.ready);
        expect(state.isLive, isTrue);
      },
    );
  });

  group('history replay on load', () {
    test('retains replay emitted synchronously during session/load', () async {
      final replayConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(
          supportsResume: false,
          replayTextOnLoad: 'Replayed history',
        ),
      );
      final replayManager = buildManagerWith(replayConnector);
      final started = await replayManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      await replayManager.detachSession(key);
      final result = await replayManager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      await _pump();
      final timeline = replayManager.state.byKeyValue(key.value)!.timeline;
      final message = timeline.entries.whereType<AcpMessageEntry>().firstWhere(
        (e) => e.messageId == 'replay',
      );
      expect(
        (message.content.single as AcpTextContent).text,
        'Replayed history',
      );
    });

    test(
      'deduplicates a replayed permission by request id across reconnect',
      () async {
        final permConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            supportsResume: false,
            permissionIdOnLoad: 'perm-stable-1',
          ),
        );
        final permManager = buildManagerWith(permConnector);
        final started = await permManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;

        Future<void> reconnect() async {
          await permManager.detachSession(key);
          await permManager.reconnectSession(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
            cwd: '/repo',
          );
          await _pump();
        }

        await reconnect();
        expect(
          permManager.state.byKeyValue(key.value)!.pendingPermissions,
          hasLength(1),
        );

        // Reconnect again: the same JSON-RPC id is replayed and must rebind the
        // responder without appending a second pending UI entry.
        await reconnect();
        final pending = permManager.state
            .byKeyValue(key.value)!
            .pendingPermissions;
        expect(pending, hasLength(1));

        await permManager.respondToPermission(
          key,
          pending.single.requestKey,
          'allow',
        );
        await _pump();
        expect(
          permManager.state.byKeyValue(key.value)!.pendingPermissions,
          isEmpty,
        );
        // The responder was rebound to the latest connection, which received
        // the response.
        final latestServer = permConnector.servers[key.bridgeId]!;
        expect(latestServer.permissionResponses['perm-stable-1'], isNotNull);
      },
    );
  });

  group('orphan bridge cleanup', () {
    test('stops a fresh bridge when session creation fails', () async {
      final failConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(failNewSession: true),
      );
      final failManager = buildManagerWith(failConnector);
      final result = await failManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchFailed>());
      // The orphaned bridge was best-effort stopped.
      expect(failConnector.startedBridges, hasLength(1));
      expect(failConnector.stoppedBridges, failConnector.startedBridges);
    });
  });

  group('telemetry allowlist', () {
    test('reports open, permission, attachment, and stop events', () async {
      final telemetry = _RecordingTelemetrySink();
      final telemetryConnector = _FakeConnector();
      final telemetryManager = buildManagerWith(
        telemetryConnector,
        telemetry: telemetry,
      );
      final result = await telemetryManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      expect(
        telemetry.events,
        contains('sessionOpened:${AcpBuiltinProviderIds.copilotCli}:false'),
      );

      await telemetryManager.prompt(key, const [
        AcpTextContent('hi'),
        AcpImageContent(data: 'aGk=', mimeType: 'image/png'),
      ]);
      expect(telemetry.events, contains('attachmentSent:image:1'));
      // Never a text/content count, and never anything content-bearing.
      expect(telemetry.events.every((event) => !event.contains('hi')), isTrue);

      telemetryConnector.servers[key.bridgeId]!.requestPermission(
        key.acpSessionId,
        't1',
      );
      await _pump();
      final pending = telemetryManager.state
          .byKeyValue(key.value)!
          .pendingPermissions
          .single;
      await telemetryManager.respondToPermission(
        key,
        pending.requestKey,
        'allow',
      );
      expect(telemetry.events, contains('permissionOutcome:selected'));

      await telemetryManager.stopSession(key);
      expect(telemetry.events, contains('sessionEnded:stopped'));
    });

    test('reports a failure category without any session content', () async {
      final telemetry = _RecordingTelemetrySink();
      final failConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(failNewSession: true),
      );
      final failManager = buildManagerWith(failConnector, telemetry: telemetry);
      await failManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(
        telemetry.events.any((event) => event.startsWith('failure:')),
        isTrue,
      );
    });
  });
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));
