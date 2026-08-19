import 'dart:async';

import '../models/acp_content.dart';
import '../models/acp_json.dart';
import '../models/acp_protocol.dart';
import '../models/acp_updates.dart';
import 'acp_json_rpc_connection.dart';

/// A requested operation is not advertised by the initialized ACP agent.
final class AcpUnsupportedCapabilityException implements Exception {
  /// Creates an unsupported-capability error.
  const AcpUnsupportedCapabilityException(this.capability);

  /// Missing capability.
  final String capability;

  @override
  String toString() => 'ACP capability is not available: $capability';
}

/// Base class for typed server-to-client ACP requests.
sealed class AcpServerRequest {
  const AcpServerRequest(this.raw);

  /// Underlying JSON-RPC request.
  final AcpJsonRpcServerRequest raw;

  /// ACP method name.
  String get method => raw.method;
}

/// A typed `session/request_permission` server request.
final class AcpPermissionServerRequest extends AcpServerRequest {
  /// Creates a permission server request.
  const AcpPermissionServerRequest(super.raw, this.permission);

  /// Parsed permission parameters.
  final AcpPermissionRequest permission;

  /// Responds with the selected option.
  Future<void> select(String optionId) => raw.respond(<String, Object?>{
    'outcome': AcpSelectedPermissionOutcome(optionId).toJson(),
  });

  /// Responds that the request was cancelled.
  Future<void> cancel() => raw.respond(<String, Object?>{
    'outcome': const AcpCancelledPermissionOutcome().toJson(),
  });
}

/// An unrecognized server request retained for future ACP versions.
final class AcpUnknownServerRequest extends AcpServerRequest {
  /// Creates an unknown server request.
  const AcpUnknownServerRequest(super.raw);
}

/// High-level typed ACP v1 client.
final class AcpClient {
  /// Creates a client over an active JSON-RPC connection.
  AcpClient(this.connection) {
    _notificationSubscription = connection.notifications.listen(
      _handleNotification,
    );
    _serverRequestSubscription = connection.serverRequests.listen(
      _handleServerRequest,
    );
  }

  /// Underlying JSON-RPC connection.
  final AcpJsonRpcConnection connection;

  final _updates = StreamController<AcpSessionNotification>.broadcast(
    sync: true,
  );
  final _serverRequests = StreamController<AcpServerRequest>.broadcast(
    sync: true,
  );
  final _otherNotifications =
      StreamController<AcpJsonRpcNotification>.broadcast(sync: true);
  late final StreamSubscription<AcpJsonRpcNotification>
  _notificationSubscription;
  late final StreamSubscription<AcpJsonRpcServerRequest>
  _serverRequestSubscription;
  AcpInitializeResult? _initialization;
  var _closed = false;

  /// Most recent successful initialization result.
  AcpInitializeResult? get initialization => _initialization;

  /// Typed `session/update` notifications.
  Stream<AcpSessionNotification> get updates => _updates.stream;

  /// Typed incoming server requests.
  Stream<AcpServerRequest> get serverRequests => _serverRequests.stream;

  /// Notifications not handled by the typed ACP layer.
  Stream<AcpJsonRpcNotification> get otherNotifications =>
      _otherNotifications.stream;

  /// Initializes the ACP connection.
  Future<AcpInitializeResult> initialize({
    int protocolVersion = 1,
    AcpClientCapabilities capabilities = const AcpClientCapabilities(
      meta: <String, Object?>{'subagent-transcript': true},
    ),
    AcpImplementation clientInfo = const AcpImplementation(
      name: 'monkeyssh',
      title: 'MonkeySSH',
      version: '1',
    ),
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    final result = await connection.request(
      'initialize',
      params: <String, Object?>{
        'protocolVersion': protocolVersion,
        'clientCapabilities': capabilities.toJson(),
        'clientInfo': clientInfo.toJson(),
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
    final parsed = AcpInitializeResult.fromJson(_requireObject(result));
    if (parsed.protocolVersion != protocolVersion) {
      throw AcpProtocolException(
        'Unsupported ACP protocol version ${parsed.protocolVersion}',
      );
    }
    _initialization = parsed;
    return parsed;
  }

  /// Authenticates using an advertised method.
  Future<void> authenticate(
    String methodId, {
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    await connection.request(
      'authenticate',
      params: <String, Object?>{
        'methodId': methodId,
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
  }

  /// Creates a new ACP session.
  Future<AcpSessionSetupResult> newSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) => _sessionSetupRequest('session/new', <String, Object?>{
    'cwd': cwd,
    'mcpServers': mcpServers,
    if (additionalDirectories.isNotEmpty)
      'additionalDirectories': additionalDirectories,
    if (meta.isNotEmpty) '_meta': meta,
  }, timeout);

  /// Lists one page of known sessions.
  Future<AcpSessionListResult> listSessions({
    String? cwd,
    String? cursor,
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    _requireCapability(
      'session/list',
      _initialization?.agentCapabilities.session.list ?? true,
    );
    final result = await connection.request(
      'session/list',
      params: <String, Object?>{
        'cwd': ?cwd,
        'cursor': ?cursor,
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
    return AcpSessionListResult.fromJson(_requireObject(result));
  }

  /// Lists pages until the cursor ends or [maxSessions] is reached.
  Future<List<AcpSessionInfo>> listAllSessions({
    String? cwd,
    int? maxSessions,
    Duration? timeout,
  }) async {
    if (maxSessions != null && maxSessions <= 0) {
      return const <AcpSessionInfo>[];
    }
    final sessions = <AcpSessionInfo>[];
    final seenCursors = <String>{};
    String? cursor;
    do {
      final page = await listSessions(
        cwd: cwd,
        cursor: cursor,
        timeout: timeout,
      );
      for (final session in page.sessions) {
        sessions.add(session);
        if (maxSessions != null && sessions.length >= maxSessions) {
          return List<AcpSessionInfo>.unmodifiable(sessions);
        }
      }
      cursor = page.nextCursor;
      if (cursor != null && !seenCursors.add(cursor)) {
        throw const AcpProtocolException(
          'session/list returned a repeated cursor',
        );
      }
    } while (cursor != null);
    return List<AcpSessionInfo>.unmodifiable(sessions);
  }

  /// Loads a stored ACP session and requests history replay.
  Future<AcpSessionSetupResult> loadSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) {
    _requireCapability(
      'session/load',
      _initialization?.agentCapabilities.loadSession ?? true,
    );
    return _sessionSetupRequest('session/load', <String, Object?>{
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
      if (additionalDirectories.isNotEmpty)
        'additionalDirectories': additionalDirectories,
      if (meta.isNotEmpty) '_meta': meta,
    }, timeout);
  }

  /// Resumes a stored ACP session without requiring history replay.
  Future<AcpSessionSetupResult> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) {
    _requireCapability(
      'session/resume',
      _initialization?.agentCapabilities.session.resume ?? true,
    );
    return _sessionSetupRequest('session/resume', <String, Object?>{
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
      if (additionalDirectories.isNotEmpty)
        'additionalDirectories': additionalDirectories,
      if (meta.isNotEmpty) '_meta': meta,
    }, timeout);
  }

  /// Forks a session using the unstable ACP v1 extension.
  Future<AcpSessionSetupResult> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) {
    _requireCapability(
      'session/fork',
      _initialization?.agentCapabilities.session.fork ?? true,
    );
    return _sessionSetupRequest('session/fork', <String, Object?>{
      'sessionId': sessionId,
      'cwd': cwd,
      if (mcpServers.isNotEmpty) 'mcpServers': mcpServers,
      if (additionalDirectories.isNotEmpty)
        'additionalDirectories': additionalDirectories,
      if (meta.isNotEmpty) '_meta': meta,
    }, timeout);
  }

  /// Closes an active session when supported.
  Future<void> closeSession(String sessionId, {Duration? timeout}) async {
    _requireCapability(
      'session/close',
      _initialization?.agentCapabilities.session.close ?? true,
    );
    await connection.request(
      'session/close',
      params: <String, Object?>{'sessionId': sessionId},
      timeout: timeout,
    );
  }

  /// Deletes a stored session when supported.
  Future<void> deleteSession(String sessionId, {Duration? timeout}) async {
    _requireCapability(
      'session/delete',
      _initialization?.agentCapabilities.session.delete ?? true,
    );
    await connection.request(
      'session/delete',
      params: <String, Object?>{'sessionId': sessionId},
      timeout: timeout,
    );
  }

  /// Sends a prompt turn.
  Future<AcpPromptResult> prompt({
    required String sessionId,
    required List<AcpContentBlock> content,
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    final result = await connection.request(
      'session/prompt',
      params: <String, Object?>{
        'sessionId': sessionId,
        'prompt': content.map((block) => block.toJson()).toList(),
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
    return AcpPromptResult.fromJson(_requireObject(result));
  }

  /// Cancels the active prompt turn for [sessionId].
  Future<void> cancel(String sessionId) => connection.notify(
    'session/cancel',
    params: <String, Object?>{'sessionId': sessionId},
  );

  /// Sets a generic session configuration option.
  Future<List<AcpSessionConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
    Duration? timeout,
  }) async {
    if (value is! String && value is! bool) {
      throw ArgumentError.value(value, 'value', 'Must be a string or boolean');
    }
    final result = await connection.request(
      'session/set_config_option',
      params: <String, Object?>{
        'sessionId': sessionId,
        'configId': configId,
        if (value is bool) 'type': 'boolean',
        'value': value,
      },
      timeout: timeout,
    );
    return AcpSessionSetupResult.fromJson(_requireObject(result)).configOptions;
  }

  /// Sets the legacy ACP session mode.
  Future<void> setMode({
    required String sessionId,
    required String modeId,
    Duration? timeout,
  }) async {
    await connection.request(
      'session/set_mode',
      params: <String, Object?>{'sessionId': sessionId, 'modeId': modeId},
      timeout: timeout,
    );
  }

  /// Sets a provider's legacy ACP model extension.
  Future<void> setModel({
    required String sessionId,
    required String modelId,
    Duration? timeout,
  }) async {
    await connection.request(
      'session/set_model',
      params: <String, Object?>{'sessionId': sessionId, 'modelId': modelId},
      timeout: timeout,
    );
  }

  /// Closes the client and its underlying connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _notificationSubscription.cancel();
    await _serverRequestSubscription.cancel();
    await connection.close();
    await _updates.close();
    await _serverRequests.close();
    await _otherNotifications.close();
  }

  Future<AcpSessionSetupResult> _sessionSetupRequest(
    String method,
    AcpJsonMap params,
    Duration? timeout,
  ) async {
    final result = await connection.request(
      method,
      params: params,
      timeout: timeout,
    );
    return AcpSessionSetupResult.fromJson(_requireObject(result));
  }

  void _handleNotification(AcpJsonRpcNotification notification) {
    if (notification.method != 'session/update') {
      _otherNotifications.add(notification);
      return;
    }
    final params = AcpJson.object(notification.params);
    if (params == null) {
      _otherNotifications.add(notification);
      return;
    }
    _updates.add(AcpSessionNotification.fromJson(params));
  }

  void _handleServerRequest(AcpJsonRpcServerRequest request) {
    if (request.method == 'session/request_permission') {
      final params = AcpJson.object(request.params);
      if (params != null) {
        _serverRequests.add(
          AcpPermissionServerRequest(
            request,
            AcpPermissionRequest.fromJson(params),
          ),
        );
        return;
      }
    }
    _serverRequests.add(AcpUnknownServerRequest(request));
  }

  void _requireCapability(String capability, bool supported) {
    if (!supported) throw AcpUnsupportedCapabilityException(capability);
  }
}

AcpJsonMap _requireObject(Object? value) {
  final object = AcpJson.object(value);
  if (object == null) {
    throw const AcpProtocolException('ACP response result must be an object');
  }
  return object;
}
