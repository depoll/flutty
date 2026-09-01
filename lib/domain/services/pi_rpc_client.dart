import 'dart:async';
import '../models/acp_content.dart';
import '../models/acp_json.dart';
import '../models/acp_protocol.dart';
import '../models/acp_updates.dart';
import 'acp_client.dart';
import 'acp_json_rpc_connection.dart';
import 'native_agent_client.dart';
import 'pi_rpc_connection.dart';

const _piThinkingConfigId = 'pi.thinking';
const _piAutoCompactionConfigId = 'pi.autoCompaction';

/// Native Pi RPC client normalized for MonkeySSH's agent conversation UI.
final class PiRpcClient implements NativeAgentClient {
  /// Creates a client over an active Pi RPC connection.
  PiRpcClient(this.connection, {String? initialSessionId})
    : _sessionId = initialSessionId ?? '' {
    _eventSubscription = connection.events.listen(_handleEvent);
  }

  /// Underlying strict JSONL RPC connection.
  final PiRpcConnection connection;

  final StreamController<AcpSessionNotification> _updates =
      StreamController<AcpSessionNotification>.broadcast(sync: true);
  late final StreamSubscription<AcpJsonMap> _eventSubscription;
  Future<AcpInitializeResult>? _initializeFuture;
  Completer<AcpPromptResult>? _activePrompt;
  AcpStopReason _lastStopReason = AcpStopReason.endTurn;
  AcpJsonMap? _state;
  List<AcpJsonMap> _models = const <AcpJsonMap>[];
  List<String> _thinkingLevels = const <String>[];
  List<AcpAvailableCommand> _commands = const <AcpAvailableCommand>[];
  String _sessionId;
  String? _liveAssistantMessageId;
  var _assistantMessageSerial = 0;
  var _closed = false;

  @override
  Stream<AcpSessionNotification> get updates => _updates.stream;

  @override
  Future<AcpInitializeResult> initialize({Duration? timeout}) =>
      _initializeFuture ??= _doInitialize(timeout: timeout);

  Future<AcpInitializeResult> _doInitialize({Duration? timeout}) async {
    final responses = await Future.wait(<Future<AcpJsonMap>>[
      connection.request('get_state', timeout: timeout),
      connection.request('get_available_models', timeout: timeout),
      connection.request('get_available_thinking_levels', timeout: timeout),
      connection.request('get_commands', timeout: timeout),
    ]);
    _applyState(_responseData(responses[0]));
    _models = _objects(_responseData(responses[1])['models']);
    _thinkingLevels = AcpJson.strings(_responseData(responses[2])['levels']);
    _commands = <AcpAvailableCommand>[
      for (final command in _objects(_responseData(responses[3])['commands']))
        if ((AcpJson.string(command, 'name') ?? '').isNotEmpty)
          AcpAvailableCommand(
            name: AcpJson.string(command, 'name')!,
            description: AcpJson.string(command, 'description') ?? '',
          ),
    ];
    final currentModel = AcpJson.object(_state?['model']);
    final acceptsImages = AcpJson.strings(
      currentModel?['input'],
    ).contains('image');
    return AcpInitializeResult(
      protocolVersion: 1,
      agentCapabilities: AcpAgentCapabilities(
        loadSession: true,
        prompt: AcpPromptCapabilities(image: acceptsImages),
        session: const AcpSessionCapabilities(resume: true),
        meta: const <String, Object?>{'protocol': 'pi-rpc'},
      ),
      agentInfo: const AcpImplementation(name: 'pi', title: 'Pi'),
      meta: const <String, Object?>{'protocol': 'pi-rpc'},
    );
  }

  @override
  Future<AcpSessionSetupResult> newSession({
    required String cwd,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout);
    final result = _setupResult();
    Timer.run(_emitSessionMetadata);
    return result;
  }

  @override
  Future<AcpSessionSetupResult> loadSession({
    required String sessionId,
    required String cwd,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout);
    await _verifySession(sessionId, timeout: timeout);
    await _replayMessages(timeout: timeout);
    _emitSessionMetadata();
    return _setupResult();
  }

  @override
  Future<AcpSessionSetupResult> resumeSession({
    required String sessionId,
    required String cwd,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout);
    await _verifySession(sessionId, timeout: timeout);
    _emitSessionMetadata();
    return _setupResult();
  }

  Future<void> _verifySession(String expected, {Duration? timeout}) async {
    final response = await connection.request('get_state', timeout: timeout);
    _applyState(_responseData(response));
    if (_sessionId != expected) {
      throw const AcpProtocolException(
        'Pi RPC process opened a different durable session',
      );
    }
  }

  @override
  Future<AcpSessionSetupResult> forkSession({
    required String sessionId,
    required String cwd,
    Duration? timeout,
  }) => Future<AcpSessionSetupResult>.error(
    const AcpUnsupportedCapabilityException('session/fork'),
  );

  @override
  Future<void> closeSession(String sessionId, {Duration? timeout}) =>
      Future<void>.error(
        const AcpUnsupportedCapabilityException('session/close'),
      );

  @override
  Future<void> deleteSession(String sessionId, {Duration? timeout}) =>
      Future<void>.error(
        const AcpUnsupportedCapabilityException('session/delete'),
      );

  @override
  Future<AcpPromptResult> prompt({
    required String sessionId,
    required List<AcpContentBlock> content,
    Duration? timeout,
  }) async {
    if (_activePrompt != null) {
      throw StateError('Pi RPC prompt is already active');
    }
    final prompt = _piPrompt(content);
    final completer = Completer<AcpPromptResult>();
    _activePrompt = completer;
    try {
      await connection.request(
        'prompt',
        fields: <String, Object?>{
          'message': prompt.message,
          if (prompt.images.isNotEmpty) 'images': prompt.images,
        },
        timeout: timeout,
        noTimeout: timeout == null,
      );
      final stateResponse = await connection.request(
        'get_state',
        timeout: timeout,
      );
      final state = _responseData(stateResponse);
      _applyState(state);
      if (!(AcpJson.boolean(state, 'isStreaming') ?? false) &&
          !completer.isCompleted) {
        completer.complete(AcpPromptResult(stopReason: _lastStopReason));
      }
      return await completer.future;
    } finally {
      if (identical(_activePrompt, completer)) _activePrompt = null;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    await connection.request('clear_queue');
    await connection.request('abort');
  }

  @override
  Future<List<AcpSessionConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
    Duration? timeout,
  }) async {
    switch (configId) {
      case _piThinkingConfigId:
        if (value is! String) {
          throw ArgumentError.value(value, 'value', 'Must be a string');
        }
        await connection.request(
          'set_thinking_level',
          fields: <String, Object?>{'level': value},
          timeout: timeout,
        );
      case _piAutoCompactionConfigId:
        if (value is! bool) {
          throw ArgumentError.value(value, 'value', 'Must be a boolean');
        }
        await connection.request(
          'set_auto_compaction',
          fields: <String, Object?>{'enabled': value},
          timeout: timeout,
        );
      default:
        throw AcpUnsupportedCapabilityException(configId);
    }
    final response = await connection.request('get_state', timeout: timeout);
    _applyState(_responseData(response));
    return _configOptions();
  }

  @override
  Future<void> setMode({
    required String sessionId,
    required String modeId,
    Duration? timeout,
  }) => Future<void>.error(
    const AcpUnsupportedCapabilityException('session/set_mode'),
  );

  @override
  Future<void> setModel({
    required String sessionId,
    required String modelId,
    Duration? timeout,
  }) async {
    final separator = modelId.indexOf('/');
    if (separator <= 0 || separator == modelId.length - 1) {
      throw ArgumentError.value(modelId, 'modelId', 'Expected provider/model');
    }
    final response = await connection.request(
      'set_model',
      fields: <String, Object?>{
        'provider': modelId.substring(0, separator),
        'modelId': modelId.substring(separator + 1),
      },
      timeout: timeout,
    );
    final model = AcpJson.object(response['data']);
    if (model != null) {
      _state = <String, Object?>{...?_state, 'model': model};
      _emit(AcpCurrentModelUpdate(modelId: modelId));
    }
    final thinking = await connection.request(
      'get_available_thinking_levels',
      timeout: timeout,
    );
    _thinkingLevels = AcpJson.strings(_responseData(thinking)['levels']);
    _emit(AcpConfigOptionsUpdate(options: _configOptions()));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _eventSubscription.cancel();
    final active = _activePrompt;
    if (active != null && !active.isCompleted) {
      active.completeError(const AcpConnectionClosedException());
    }
    await connection.close();
    await _updates.close();
  }

  AcpSessionSetupResult _setupResult() => AcpSessionSetupResult(
    sessionId: _sessionId,
    models: _modelState(),
    configOptions: _configOptions(),
    meta: const <String, Object?>{'protocol': 'pi-rpc'},
  );

  AcpModelState _modelState() {
    final current = AcpJson.object(_state?['model']);
    return AcpModelState(
      currentModelId: current == null ? '' : _modelKey(current),
      availableModels: <AcpModelInfo>[
        for (final model in _models)
          if (_modelKey(model).isNotEmpty)
            AcpModelInfo(
              id: _modelKey(model),
              name: AcpJson.string(model, 'name') ?? _modelKey(model),
              description: _modelDescription(model),
            ),
      ],
    );
  }

  List<AcpSessionConfigOption> _configOptions() {
    final options = <AcpSessionConfigOption>[];
    if (_thinkingLevels.isNotEmpty) {
      options.add(
        AcpSelectConfigOption(
          id: _piThinkingConfigId,
          name: 'Reasoning effort',
          currentValue:
              AcpJson.string(_state ?? const {}, 'thinkingLevel') ??
              _thinkingLevels.first,
          options: <AcpConfigValue>[
            for (final level in _thinkingLevels)
              AcpConfigValue(value: level, name: _titleCase(level)),
          ],
          category: 'thought',
        ),
      );
    }
    options.add(
      AcpBooleanConfigOption(
        id: _piAutoCompactionConfigId,
        name: 'Automatic compaction',
        currentValue:
            AcpJson.boolean(_state ?? const {}, 'autoCompactionEnabled') ??
            true,
        description: 'Compact the session when its context is nearly full.',
        category: 'agent',
      ),
    );
    return List<AcpSessionConfigOption>.unmodifiable(options);
  }

  void _handleEvent(AcpJsonMap event) {
    switch (AcpJson.string(event, 'type')) {
      case 'message_start':
        final message = AcpJson.object(event['message']);
        if (AcpJson.string(message ?? const {}, 'role') == 'assistant') {
          _liveAssistantMessageId = 'pi-assistant-${_assistantMessageSerial++}';
        }
      case 'message_update':
        _handleMessageUpdate(event);
      case 'message_end':
        final message = AcpJson.object(event['message']);
        if (AcpJson.string(message ?? const {}, 'role') == 'assistant') {
          _lastStopReason = _stopReason(AcpJson.string(message!, 'stopReason'));
          _emitUsageFromMessage(message);
          _liveAssistantMessageId = null;
        }
      case 'tool_execution_start':
        _handleToolStart(event);
      case 'tool_execution_update':
        _handleToolUpdate(event, completed: false);
      case 'tool_execution_end':
        _handleToolUpdate(event, completed: true);
      case 'extension_ui_request':
        final method = AcpJson.string(event, 'method');
        if (method == 'select' ||
            method == 'confirm' ||
            method == 'input' ||
            method == 'editor') {
          final id = AcpJson.string(event, 'id');
          if (id != null) {
            unawaited(
              connection.send(<String, Object?>{
                'type': 'extension_ui_response',
                'id': id,
                'cancelled': true,
              }),
            );
          }
        }
      case 'agent_settled':
        final active = _activePrompt;
        if (active != null && !active.isCompleted) {
          active.complete(AcpPromptResult(stopReason: _lastStopReason));
        }
        unawaited(_refreshUsage());
      default:
        break;
    }
  }

  void _handleMessageUpdate(AcpJsonMap event) {
    final delta = AcpJson.object(event['assistantMessageEvent']);
    if (delta == null) return;
    final deltaType = AcpJson.string(delta, 'type');
    final text = AcpJson.string(delta, 'delta');
    if (text != null && text.isNotEmpty) {
      if (deltaType == 'text_delta') {
        _emit(
          AcpContentChunkUpdate(
            kind: 'agent_message_chunk',
            content: AcpTextContent(text),
            messageId: _liveAssistantMessageId,
          ),
        );
      } else if (deltaType == 'thinking_delta') {
        _emit(
          AcpContentChunkUpdate(
            kind: 'agent_thought_chunk',
            content: AcpTextContent(text),
            messageId: _liveAssistantMessageId == null
                ? null
                : '${_liveAssistantMessageId!}-thinking',
          ),
        );
      }
    }
    final usage = AcpJson.object(event['usage']);
    if (usage != null) _emitUsage(usage);
  }

  void _handleToolStart(AcpJsonMap event) {
    final id = AcpJson.identifier(event, 'toolCallId');
    if (id == null || id.isEmpty) return;
    final name = AcpJson.string(event, 'toolName') ?? 'tool';
    _emit(
      AcpToolCallUpdate(
        toolCallId: id,
        isInitial: true,
        title: name,
        toolKind: _toolKind(name),
        status: AcpToolStatus.inProgress,
        rawInput: event['args'],
      ),
    );
  }

  void _handleToolUpdate(AcpJsonMap event, {required bool completed}) {
    final id = AcpJson.identifier(event, 'toolCallId');
    if (id == null || id.isEmpty) return;
    final result = AcpJson.object(
      event[completed ? 'result' : 'partialResult'],
    );
    final content = result == null
        ? null
        : <AcpToolContent>[
            for (final block in _contentBlocks(result['content']))
              AcpToolContentBlock(content: block),
          ];
    final failed = AcpJson.boolean(event, 'isError') ?? false;
    _emit(
      AcpToolCallUpdate(
        toolCallId: id,
        status: completed
            ? (failed ? AcpToolStatus.failed : AcpToolStatus.completed)
            : AcpToolStatus.inProgress,
        content: content,
        rawInput: event['args'],
        rawOutput: completed ? result : null,
      ),
    );
  }

  Future<void> _replayMessages({Duration? timeout}) async {
    final response = await connection.request('get_messages', timeout: timeout);
    final messages =
        AcpJson.listField(_responseData(response), 'messages') ??
        const <Object?>[];
    var index = 0;
    for (final raw in messages) {
      final message = AcpJson.object(raw);
      if (message == null) continue;
      _replayMessage(message, index++);
    }
  }

  void _replayMessage(AcpJsonMap message, int index) {
    final role = AcpJson.string(message, 'role');
    final messageId = 'pi-history-$index';
    switch (role) {
      case 'user':
        for (final block in _messageContent(message['content'])) {
          _emit(
            AcpContentChunkUpdate(
              kind: 'user_message_chunk',
              content: block,
              messageId: messageId,
            ),
          );
        }
      case 'assistant':
        for (final raw in AcpJson.listField(message, 'content') ?? const []) {
          final block = AcpJson.object(raw);
          if (block == null) continue;
          switch (AcpJson.string(block, 'type')) {
            case 'text':
              _emit(
                AcpContentChunkUpdate(
                  kind: 'agent_message_chunk',
                  content: AcpTextContent(AcpJson.string(block, 'text') ?? ''),
                  messageId: messageId,
                ),
              );
            case 'thinking':
              _emit(
                AcpContentChunkUpdate(
                  kind: 'agent_thought_chunk',
                  content: AcpTextContent(
                    AcpJson.string(block, 'thinking') ?? '',
                  ),
                  messageId: '$messageId-thinking',
                ),
              );
            case 'toolCall':
              final id = AcpJson.identifier(block, 'id');
              if (id != null && id.isNotEmpty) {
                final name = AcpJson.string(block, 'name') ?? 'tool';
                _emit(
                  AcpToolCallUpdate(
                    toolCallId: id,
                    isInitial: true,
                    title: name,
                    toolKind: _toolKind(name),
                    status: AcpToolStatus.inProgress,
                    rawInput: block['arguments'],
                  ),
                );
              }
            default:
              break;
          }
        }
        _emitUsageFromMessage(message);
      case 'toolResult':
        final id = AcpJson.identifier(message, 'toolCallId');
        if (id != null && id.isNotEmpty) {
          final failed = AcpJson.boolean(message, 'isError') ?? false;
          _emit(
            AcpToolCallUpdate(
              toolCallId: id,
              status: failed ? AcpToolStatus.failed : AcpToolStatus.completed,
              content: <AcpToolContent>[
                for (final block in _contentBlocks(message['content']))
                  AcpToolContentBlock(content: block),
              ],
              rawOutput: message['details'],
            ),
          );
        }
      default:
        break;
    }
  }

  void _emitSessionMetadata() {
    if (_commands.isNotEmpty) {
      _emit(AcpAvailableCommandsUpdate(commands: _commands));
    }
    final sessionName = AcpJson.string(_state ?? const {}, 'sessionName');
    if (sessionName != null && sessionName.isNotEmpty) {
      _emit(AcpSessionInfoUpdate(title: sessionName, hasTitle: true));
    }
  }

  Future<void> _refreshUsage() async {
    try {
      final response = await connection.request('get_session_stats');
      final stats = _responseData(response);
      final context = AcpJson.object(stats['contextUsage']);
      if (context == null) return;
      final used = AcpJson.integer(context, 'tokens');
      final size = AcpJson.integer(context, 'contextWindow');
      if (used == null || size == null) return;
      _emit(
        AcpUsageUpdate(
          used: used,
          size: size,
          cost: AcpCost(
            amount: AcpJson.number(stats, 'cost') ?? 0,
            currency: 'USD',
          ),
        ),
      );
    } on Object {
      // Usage is optional and must not fail an otherwise completed prompt.
    }
  }

  void _emitUsageFromMessage(AcpJsonMap message) {
    final usage = AcpJson.object(message['usage']);
    if (usage != null) _emitUsage(usage);
  }

  void _emitUsage(AcpJsonMap usage) {
    final model = AcpJson.object(_state?['model']);
    final size = AcpJson.integer(model ?? const {}, 'contextWindow');
    if (size == null || size <= 0) return;
    final used =
        AcpJson.integer(usage, 'totalTokens') ??
        ((AcpJson.integer(usage, 'input') ?? 0) +
            (AcpJson.integer(usage, 'output') ?? 0) +
            (AcpJson.integer(usage, 'cacheRead') ?? 0) +
            (AcpJson.integer(usage, 'cacheWrite') ?? 0));
    final cost = AcpJson.object(usage['cost']);
    _emit(
      AcpUsageUpdate(
        used: used,
        size: size,
        cost: cost == null
            ? null
            : AcpCost(
                amount: AcpJson.number(cost, 'total') ?? 0,
                currency: 'USD',
              ),
      ),
    );
  }

  void _applyState(AcpJsonMap state) {
    _state = state;
    _sessionId = AcpJson.string(state, 'sessionId') ?? _sessionId;
  }

  void _emit(AcpSessionUpdate update) {
    if (_closed || _sessionId.isEmpty) return;
    _updates.add(AcpSessionNotification(sessionId: _sessionId, update: update));
  }
}

({String message, List<AcpJsonMap> images}) _piPrompt(
  List<AcpContentBlock> content,
) {
  final text = <String>[];
  final images = <AcpJsonMap>[];
  for (final block in content) {
    switch (block) {
      case AcpTextContent(text: final value):
        text.add(value);
      case AcpImageContent(:final data, :final mimeType):
        images.add(<String, Object?>{
          'type': 'image',
          'data': data,
          'mimeType': mimeType,
        });
      case AcpResourceContent(:final resource):
        if (resource is AcpTextResource) text.add(resource.text);
      case AcpAudioContent() || AcpResourceLinkContent() || AcpUnknownContent():
        throw const AcpUnsupportedCapabilityException('prompt content');
    }
  }
  return (message: text.join('\n'), images: images);
}

AcpJsonMap _responseData(AcpJsonMap response) =>
    AcpJson.object(response['data']) ?? const <String, Object?>{};

List<AcpJsonMap> _objects(Object? value) =>
    (value is List ? value : const <Object?>[])
        .map(AcpJson.object)
        .nonNulls
        .toList(growable: false);

String _modelKey(AcpJsonMap model) {
  final provider = AcpJson.string(model, 'provider') ?? '';
  final id = AcpJson.string(model, 'id') ?? '';
  return provider.isEmpty || id.isEmpty ? '' : '$provider/$id';
}

String? _modelDescription(AcpJsonMap model) {
  final context = AcpJson.integer(model, 'contextWindow');
  if (context == null) return null;
  final formatted = context >= 1000000
      ? '${(context / 1000000).toStringAsFixed(context % 1000000 == 0 ? 0 : 1)}M'
      : '${(context / 1000).round()}K';
  return '$formatted token context';
}

String _titleCase(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

AcpStopReason _stopReason(String? reason) => switch (reason) {
  'stop' || 'toolUse' => AcpStopReason.endTurn,
  'length' => AcpStopReason.maxTokens,
  'aborted' => AcpStopReason.cancelled,
  'error' => AcpStopReason.refusal,
  _ => AcpStopReason.endTurn,
};

AcpToolKind _toolKind(String name) => switch (name) {
  'read' || 'grep' || 'find' || 'ls' => AcpToolKind.read,
  'edit' || 'write' => AcpToolKind.edit,
  'bash' || 'powershell' => AcpToolKind.execute,
  _ => AcpToolKind.other,
};

List<AcpContentBlock> _messageContent(Object? raw) {
  if (raw is String) return <AcpContentBlock>[AcpTextContent(raw)];
  return _contentBlocks(raw);
}

List<AcpContentBlock> _contentBlocks(Object? raw) {
  final result = <AcpContentBlock>[];
  for (final item in raw is List ? raw : const <Object?>[]) {
    final block = AcpJson.object(item);
    if (block == null) continue;
    switch (AcpJson.string(block, 'type')) {
      case 'text':
        result.add(AcpTextContent(AcpJson.string(block, 'text') ?? ''));
      case 'image':
        result.add(
          AcpImageContent(
            data: AcpJson.string(block, 'data') ?? '',
            mimeType: AcpJson.string(block, 'mimeType') ?? '',
          ),
        );
      default:
        break;
    }
  }
  return result;
}
