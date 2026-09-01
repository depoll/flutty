// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/pi_rpc_client.dart';
import 'package:monkeyssh/domain/services/pi_rpc_connection.dart';

class _FakePiRpcServer implements AcpTransport {
  final StreamController<List<int>> _incoming = StreamController<List<int>>(
    sync: true,
  );
  final List<Map<String, Object?>> received = <Map<String, Object?>>[];
  bool streaming = false;
  bool closed = false;
  String thinkingLevel = 'high';
  bool autoCompaction = true;
  Map<String, Object?> currentModel = <String, Object?>{
    'id': 'model-a',
    'name': 'Model A',
    'provider': 'provider-a',
    'input': <String>['text', 'image'],
    'contextWindow': 200000,
  };

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final message = jsonDecode(utf8.decode(bytes).trim()) as Map;
    final command = message.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    received.add(command);
    final type = command['type'];
    final id = command['id'] as String?;
    switch (type) {
      case 'get_state':
        _respond(id!, type as String, <String, Object?>{
          'model': currentModel,
          'thinkingLevel': thinkingLevel,
          'isStreaming': streaming,
          'isCompacting': false,
          'steeringMode': 'one-at-a-time',
          'followUpMode': 'one-at-a-time',
          'sessionId': 'session-123',
          'sessionName': 'Named Pi session',
          'autoCompactionEnabled': autoCompaction,
          'messageCount': 3,
          'pendingMessageCount': 0,
        });
      case 'get_available_models':
        _respond(id!, type as String, <String, Object?>{
          'models': <Object?>[
            currentModel,
            <String, Object?>{
              'id': 'model-b',
              'name': 'Model B',
              'provider': 'provider-b',
              'input': <String>['text'],
              'contextWindow': 1000000,
            },
          ],
        });
      case 'get_available_thinking_levels':
        _respond(id!, type as String, <String, Object?>{
          'levels': <String>['off', 'low', 'high'],
        });
      case 'get_commands':
        _respond(id!, type as String, <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{
              'name': 'review',
              'description': 'Review the current changes',
              'source': 'prompt',
              'sourceInfo': <String, Object?>{'path': '/private/prompt.md'},
            },
          ],
        });
      case 'get_messages':
        _respond(id!, type as String, <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'Earlier question'},
            <String, Object?>{
              'role': 'assistant',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'thinking',
                  'thinking': 'Consider it',
                },
                <String, Object?>{'type': 'text', 'text': 'Earlier answer'},
                <String, Object?>{
                  'type': 'toolCall',
                  'id': 'history-tool',
                  'name': 'read',
                  'arguments': <String, Object?>{'path': 'README.md'},
                },
              ],
              'usage': _usage(),
              'stopReason': 'toolUse',
            },
            <String, Object?>{
              'role': 'toolResult',
              'toolCallId': 'history-tool',
              'toolName': 'read',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'contents'},
              ],
              'isError': false,
            },
          ],
        });
      case 'prompt':
        streaming = true;
        _respond(id!, type as String, null);
        scheduleMicrotask(_streamPrompt);
      case 'get_session_stats':
        _respond(id!, type as String, <String, Object?>{
          'sessionId': 'session-123',
          'cost': 0.42,
          'contextUsage': <String, Object?>{
            'tokens': 1200,
            'contextWindow': 200000,
            'percent': 0.6,
          },
        });
      case 'set_thinking_level':
        thinkingLevel = command['level']! as String;
        _respond(id!, type as String, null);
      case 'set_auto_compaction':
        autoCompaction = command['enabled']! as bool;
        _respond(id!, type as String, null);
      case 'set_model':
        currentModel = <String, Object?>{
          'id': command['modelId'],
          'name': 'Selected model',
          'provider': command['provider'],
          'input': <String>['text'],
          'contextWindow': 300000,
        };
        _respond(id!, type as String, currentModel);
      case 'clear_queue' || 'abort':
        _respond(id!, type as String, null);
      case 'extension_ui_response':
        break;
      default:
        throw StateError('Unexpected Pi RPC command: $type');
    }
  }

  void _streamPrompt() {
    _event(<String, Object?>{
      'type': 'message_start',
      'message': <String, Object?>{'role': 'assistant', 'content': <Object?>[]},
    });
    _event(<String, Object?>{
      'type': 'message_update',
      'usage': _usage(),
      'assistantMessageEvent': <String, Object?>{
        'type': 'thinking_delta',
        'contentIndex': 0,
        'delta': 'Checking',
      },
    });
    _event(<String, Object?>{
      'type': 'message_update',
      'usage': _usage(),
      'assistantMessageEvent': <String, Object?>{
        'type': 'text_delta',
        'contentIndex': 1,
        'delta': 'Done',
      },
    });
    _event(<String, Object?>{
      'type': 'tool_execution_start',
      'toolCallId': 'live-tool',
      'toolName': 'bash',
      'args': <String, Object?>{'command': 'pwd'},
    });
    _event(<String, Object?>{
      'type': 'tool_execution_update',
      'toolCallId': 'live-tool',
      'toolName': 'bash',
      'args': <String, Object?>{'command': 'pwd'},
      'partialResult': <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '/repo'},
        ],
      },
    });
    _event(<String, Object?>{
      'type': 'tool_execution_end',
      'toolCallId': 'live-tool',
      'toolName': 'bash',
      'args': <String, Object?>{'command': 'pwd'},
      'result': <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '/repo'},
        ],
      },
      'isError': false,
    });
    _event(<String, Object?>{
      'type': 'message_end',
      'message': <String, Object?>{
        'role': 'assistant',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'Done'},
        ],
        'usage': _usage(),
        'stopReason': 'stop',
      },
    });
    streaming = false;
    _event(<String, Object?>{'type': 'agent_settled'});
  }

  Map<String, Object?> _usage() => <String, Object?>{
    'input': 100,
    'output': 20,
    'cacheRead': 10,
    'cacheWrite': 0,
    'totalTokens': 130,
    'cost': <String, Object?>{
      'input': 0.01,
      'output': 0.02,
      'cacheRead': 0,
      'cacheWrite': 0,
      'total': 0.03,
    },
  };

  void _respond(String id, String command, Object? data) =>
      _event(<String, Object?>{
        'id': id,
        'type': 'response',
        'command': command,
        'success': true,
        'data': ?data,
      });

  void _event(Map<String, Object?> event) {
    _incoming.add(utf8.encode('${jsonEncode(event)}\n'));
  }

  void requestExtensionDialog() => _event(<String, Object?>{
    'type': 'extension_ui_request',
    'id': 'dialog-1',
    'method': 'confirm',
    'title': 'Continue?',
    'message': 'Proceed with the extension action?',
  });

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

void main() {
  test('Pi RPC connection uses LF JSONL and correlates responses', () async {
    final server = _FakePiRpcServer();
    final connection = PiRpcConnection(transport: server);

    final response = await connection.request('get_state');

    expect(response['command'], 'get_state');
    expect(server.received.single['id'], 'monkeyssh-pi-0');
    await connection.close();
    expect(server.closed, isTrue);
  });

  test(
    'initialization maps models, thinking, compaction, and commands',
    () async {
      final server = _FakePiRpcServer();
      final client = PiRpcClient(PiRpcConnection(transport: server));
      final updates = <AcpSessionUpdate>[];
      final subscription = client.updates.listen(
        (notification) => updates.add(notification.update),
      );

      final initialization = await client.initialize();
      final setup = await client.newSession(cwd: '/repo');
      await Future<void>.delayed(Duration.zero);

      expect(initialization.agentInfo?.name, 'pi');
      expect(initialization.agentCapabilities.loadSession, isTrue);
      expect(initialization.agentCapabilities.prompt.image, isTrue);
      expect(setup.sessionId, 'session-123');
      expect(setup.models?.currentModelId, 'provider-a/model-a');
      expect(
        setup.models?.availableModels.map((model) => model.id),
        containsAll(<String>['provider-a/model-a', 'provider-b/model-b']),
      );
      expect(
        setup.configOptions.map((option) => option.id),
        containsAll(<String>['pi.thinking', 'pi.autoCompaction']),
      );
      final commands = updates.whereType<AcpAvailableCommandsUpdate>().single;
      expect(commands.commands.single.name, 'review');
      expect(commands.commands.single.meta, isEmpty);

      await subscription.cancel();
      await client.close();
    },
  );

  test('load replays user, thought, answer, tool input, and result', () async {
    final server = _FakePiRpcServer();
    final client = PiRpcClient(
      PiRpcConnection(transport: server),
      initialSessionId: 'session-123',
    );
    final updates = <AcpSessionUpdate>[];
    final subscription = client.updates.listen(
      (notification) => updates.add(notification.update),
    );

    await client.initialize();
    await client.loadSession(sessionId: 'session-123', cwd: '/repo');

    final chunks = updates.whereType<AcpContentChunkUpdate>().toList();
    expect(
      chunks.map((chunk) => (chunk.content as AcpTextContent).text),
      containsAll(<String>[
        'Earlier question',
        'Consider it',
        'Earlier answer',
      ]),
    );
    final tools = updates
        .whereType<AcpToolCallUpdate>()
        .where((update) => update.toolCallId == 'history-tool')
        .toList();
    expect(tools.first.rawInput, <String, Object?>{'path': 'README.md'});
    expect(tools.last.status, AcpToolStatus.completed);

    await subscription.cancel();
    await client.close();
  });

  test('prompt maps images, thought, tools, settlement, and usage', () async {
    final server = _FakePiRpcServer();
    final client = PiRpcClient(PiRpcConnection(transport: server));
    final updates = <AcpSessionUpdate>[];
    final subscription = client.updates.listen(
      (notification) => updates.add(notification.update),
    );
    await client.initialize();
    await client.newSession(cwd: '/repo');

    final result = await client.prompt(
      sessionId: 'session-123',
      content: const <AcpContentBlock>[
        AcpTextContent('Inspect this'),
        AcpImageContent(data: 'aW1hZ2U=', mimeType: 'image/png'),
      ],
    );
    await Future<void>.delayed(Duration.zero);

    expect(result.stopReason, AcpStopReason.endTurn);
    final prompt = server.received.firstWhere(
      (message) => message['type'] == 'prompt',
    );
    expect(prompt['message'], 'Inspect this');
    expect((prompt['images']! as List).single, <String, Object?>{
      'type': 'image',
      'data': 'aW1hZ2U=',
      'mimeType': 'image/png',
    });
    expect(
      updates.whereType<AcpContentChunkUpdate>().map((update) => update.kind),
      containsAll(<String>['agent_thought_chunk', 'agent_message_chunk']),
    );
    final liveTool = updates
        .whereType<AcpToolCallUpdate>()
        .where((update) => update.toolCallId == 'live-tool')
        .toList();
    expect(liveTool.first.toolKind, AcpToolKind.execute);
    expect(liveTool.last.status, AcpToolStatus.completed);
    expect(
      updates.whereType<AcpUsageUpdate>().last.cost?.amount,
      anyOf(0.03, 0.42),
    );

    await subscription.cancel();
    await client.close();
  });

  test('model and Pi settings use their native RPC commands', () async {
    final server = _FakePiRpcServer();
    final client = PiRpcClient(PiRpcConnection(transport: server));
    await client.initialize();
    await client.newSession(cwd: '/repo');

    await client.setModel(
      sessionId: 'session-123',
      modelId: 'provider-b/model-b',
    );
    final thinking = await client.setConfigOption(
      sessionId: 'session-123',
      configId: 'pi.thinking',
      value: 'low',
    );
    final compaction = await client.setConfigOption(
      sessionId: 'session-123',
      configId: 'pi.autoCompaction',
      value: false,
    );

    expect(server.received, contains(containsPair('type', 'set_model')));
    expect(
      thinking.whereType<AcpSelectConfigOption>().single.currentValue,
      'low',
    );
    expect(
      compaction.whereType<AcpBooleanConfigOption>().single.currentValue,
      isFalse,
    );
    await client.close();
  });

  test(
    'unsupported extension dialogs are cancelled instead of deadlocking',
    () async {
      final server = _FakePiRpcServer();
      final client = PiRpcClient(PiRpcConnection(transport: server));
      await client.initialize();

      server.requestExtensionDialog();
      await Future<void>.delayed(Duration.zero);

      expect(
        server.received.any(
          (message) =>
              message['type'] == 'extension_ui_response' &&
              message['id'] == 'dialog-1' &&
              message['cancelled'] == true,
        ),
        isTrue,
      );
      await client.close();
    },
  );

  test('invalid Pi JSON terminates pending commands', () async {
    final transport = _ManualTransport();
    final connection = PiRpcConnection(transport: transport);
    final pending = connection.request('get_state');
    transport.emit(utf8.encode('{not json}\n'));

    await expectLater(pending, throwsA(isA<AcpProtocolException>()));
    await connection.close();
  });
}

class _ManualTransport implements AcpTransport {
  final StreamController<List<int>> _incoming = StreamController<List<int>>(
    sync: true,
  );

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {}

  void emit(List<int> bytes) => _incoming.add(bytes);

  @override
  Future<void> close() => _incoming.close();
}
