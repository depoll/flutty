import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';

final class _ServerTransport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final requests = <Map<String, Object?>>[];
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  void send(Map<String, Object?> message) {
    _incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> write(List<int> bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    final request = (decoded as Map).map(
      (key, value) => MapEntry(key as String, value),
    );
    requests.add(request);
    final id = request['id'];
    if (id == null) return;
    switch (request['method']) {
      case 'initialize':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {
              'sessionCapabilities': {
                'list': <String, Object?>{},
                'fork': <String, Object?>{},
                'resume': <String, Object?>{},
                'close': <String, Object?>{},
                'delete': <String, Object?>{},
              },
            },
          },
        });
      case 'session/list':
        final params = request['params'] as Map;
        final cursor = params['cursor'];
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': cursor == null
              ? {
                  'sessions': [
                    {
                      'sessionId': 'session-1',
                      'cwd': '/repo',
                      'title': 'First',
                    },
                  ],
                  'nextCursor': 'page-2',
                }
              : {
                  'sessions': [
                    {
                      'sessionId': 'session-2',
                      'cwd': '/repo',
                      'title': 'Second',
                    },
                  ],
                },
        });
      default:
        send({'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}});
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

void main() {
  test('initializes and follows session list pagination', () async {
    final transport = _ServerTransport();
    var nextId = 0;
    final client = AcpClient(
      AcpJsonRpcConnection(
        transport: transport,
        requestIdFactory: () => 'request-${nextId++}',
      ),
    );

    final initialization = await client.initialize();
    final sessions = await client.listAllSessions(cwd: '/repo');

    expect(initialization.agentCapabilities.session.list, isTrue);
    expect(sessions.map((session) => session.sessionId), [
      'session-1',
      'session-2',
    ]);
    final listRequests = transport.requests
        .where((request) => request['method'] == 'session/list')
        .toList();
    expect(listRequests, hasLength(2));
    expect((listRequests.last['params'] as Map?)?['cursor'], 'page-2');
    await client.close();
  });

  test('exposes typed updates and permission server requests', () async {
    final transport = _ServerTransport();
    final client = AcpClient(AcpJsonRpcConnection(transport: transport));
    final updateFuture = client.updates.first;
    final requestFuture = client.serverRequests.first;

    transport
      ..send({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'session-1',
          'update': {'sessionUpdate': 'usage_update', 'used': 5, 'size': 100},
        },
      })
      ..send({
        'jsonrpc': '2.0',
        'id': 'permission-1',
        'method': 'session/request_permission',
        'params': {
          'sessionId': 'session-1',
          'toolCall': {
            'toolCallId': 'tool-1',
            'title': 'Write file',
            'kind': 'edit',
          },
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        },
      });

    final update = await updateFuture;
    expect(update.update, isA<AcpUsageUpdate>());
    final request = await requestFuture;
    expect(request, isA<AcpPermissionServerRequest>());
    await (request as AcpPermissionServerRequest).select('allow');
    expect(transport.requests.last['id'], 'permission-1');
    expect(transport.requests.last['result'], {
      'outcome': {'outcome': 'selected', 'optionId': 'allow'},
    });
    await client.close();
  });

  test(
    'rejects session operations absent from initialized capabilities',
    () async {
      final transport = _ServerTransport();
      final client = AcpClient(AcpJsonRpcConnection(transport: transport));
      await client.initialize();

      expect(
        () => client.loadSession(sessionId: 'session-1', cwd: '/repo'),
        throwsA(isA<AcpUnsupportedCapabilityException>()),
      );
      await client.close();
    },
  );
}
