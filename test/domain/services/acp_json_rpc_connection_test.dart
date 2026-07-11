import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';

final class _MemoryTransport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final writes = <List<int>>[];
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  void add(List<int> bytes) => _incoming.add(bytes);

  @override
  Future<void> write(List<int> bytes) async {
    writes.add(List<int>.of(bytes));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

Map<String, Object?> _decodeWrite(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes).trim());
  return (decoded as Map).map((key, value) => MapEntry(key as String, value));
}

List<int> _encodeMessage(Map<String, Object?> message) =>
    utf8.encode('${jsonEncode(message)}\n');

void main() {
  test('generates UUID string request IDs by default', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    final pending = connection.sendRequest('example');
    final expectation = expectLater(
      pending.future,
      throwsA(isA<AcpRequestCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);

    final request = _decodeWrite(transport.writes.single);
    expect(
      request['id'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    pending.cancel();
    await expectation;
    await connection.close();
  });

  test('decodes split UTF-8 and NDJSON response frames', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      requestIdFactory: () => 'request-id',
    );
    final resultFuture = connection.request('example');
    await Future<void>.delayed(Duration.zero);

    final response = _encodeMessage({
      'jsonrpc': '2.0',
      'id': 'request-id',
      'result': {'text': 'café 🚀'},
    });
    final split = response.indexOf(0xf0) + 2;
    transport
      ..add(response.sublist(0, split))
      ..add(response.sublist(split));

    expect(await resultFuture, {'text': 'café 🚀'});
    await connection.close();
  });

  test('routes mixed responses, notifications, and server requests', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      requestIdFactory: () => 'client-request',
    );
    final notificationFuture = connection.notifications.first;
    final serverRequestFuture = connection.serverRequests.first;
    final resultFuture = connection.request('client/method');
    await Future<void>.delayed(Duration.zero);

    transport.add(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {'sessionId': 'session-1'},
        })}\n'
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 7,
          'method': 'session/request_permission',
          'params': {'sessionId': 'session-1'},
        })}\n'
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 'client-request',
          'result': {'ok': true},
        })}\n',
      ),
    );

    expect((await notificationFuture).method, 'session/update');
    final serverRequest = await serverRequestFuture;
    expect(serverRequest.id, 7);
    expect(await resultFuture, {'ok': true});

    await serverRequest.respond({'accepted': true});
    final response = _decodeWrite(transport.writes.last);
    expect(response['id'], 7);
    expect(response['result'], {'accepted': true});
    await connection.close();
  });

  test(
    'times out, cancels, and closes pending requests deterministically',
    () async {
      final transport = _MemoryTransport();
      var nextId = 0;
      final connection = AcpJsonRpcConnection(
        transport: transport,
        defaultRequestTimeout: const Duration(milliseconds: 10),
        requestIdFactory: () => 'request-${nextId++}',
      );

      await expectLater(
        connection.request('slow'),
        throwsA(isA<AcpRequestTimeoutException>()),
      );

      final cancelled = connection.sendRequest(
        'cancelled',
        timeout: const Duration(seconds: 1),
      );
      final cancelledExpectation = expectLater(
        cancelled.future,
        throwsA(isA<AcpRequestCancelledException>()),
      );
      cancelled.cancel();
      await cancelledExpectation;

      final pending = connection.request(
        'pending',
        timeout: const Duration(seconds: 1),
      );
      final closeExpectation = expectLater(
        pending,
        throwsA(isA<AcpConnectionClosedException>()),
      );
      await connection.close();
      await closeExpectation;
      expect(transport.closed, isTrue);
    },
  );

  test('rejects oversized frames with an explicit protocol error', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      maxFrameSize: 8,
    );
    final errorFuture = connection.errors.first;

    transport.add(utf8.encode('123456789'));

    expect(await errorFuture, isA<AcpProtocolException>());
    expect(connection.isClosed, isTrue);
  });
}
