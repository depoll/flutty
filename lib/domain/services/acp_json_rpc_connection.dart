import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../models/acp_json.dart';
import 'acp_transport.dart';

/// JSON-RPC request identifier accepted by ACP.
typedef AcpRequestId = Object;

/// Generates request identifiers for an [AcpJsonRpcConnection].
typedef AcpRequestIdFactory = AcpRequestId Function();

/// Base class for ACP JSON-RPC failures.
sealed class AcpJsonRpcException implements Exception {
  const AcpJsonRpcException(this.message);

  /// Human-readable failure description.
  final String message;

  @override
  String toString() => 'ACP JSON-RPC error: $message';
}

/// The peer sent invalid JSON-RPC or invalid NDJSON framing.
final class AcpProtocolException extends AcpJsonRpcException {
  /// Creates a protocol error.
  const AcpProtocolException(super.message);
}

/// A JSON-RPC response contained an error object.
final class AcpRemoteException extends AcpJsonRpcException {
  /// Creates a remote JSON-RPC error.
  const AcpRemoteException({
    required this.code,
    required String message,
    this.data,
  }) : super(message);

  /// JSON-RPC error code.
  final int code;

  /// Optional error data.
  final Object? data;
}

/// A request did not receive a response before its deadline.
final class AcpRequestTimeoutException extends AcpJsonRpcException {
  /// Creates a timeout error.
  const AcpRequestTimeoutException(this.id, this.method, Duration timeout)
    : super('Request $method ($id) timed out after $timeout');

  /// Timed-out request identifier.
  final AcpRequestId id;

  /// Timed-out method.
  final String method;
}

/// A pending request was cancelled locally.
final class AcpRequestCancelledException extends AcpJsonRpcException {
  /// Creates a cancellation error.
  const AcpRequestCancelledException(this.id, this.method)
    : super('Request $method ($id) was cancelled');

  /// Cancelled request identifier.
  final AcpRequestId id;

  /// Cancelled method.
  final String method;
}

/// The connection closed while work was pending.
final class AcpConnectionClosedException extends AcpJsonRpcException {
  /// Creates a connection-closed error.
  const AcpConnectionClosedException([super.message = 'Connection closed']);
}

/// A received JSON-RPC notification.
final class AcpJsonRpcNotification {
  /// Creates a JSON-RPC notification.
  const AcpJsonRpcNotification({
    required this.method,
    required this.params,
    required this.raw,
  });

  /// Notification method.
  final String method;

  /// Optional notification parameters.
  final Object? params;

  /// Complete notification object.
  final AcpJsonMap raw;
}

/// A received JSON-RPC request that must be answered by the client.
final class AcpJsonRpcServerRequest {
  AcpJsonRpcServerRequest._({
    required this.id,
    required this.method,
    required this.params,
    required this.raw,
    required Future<void> Function(Object? result) respond,
    required Future<void> Function(int code, String message, Object? data)
    respondError,
  }) : _respond = respond,
       _respondError = respondError;

  /// Request identifier.
  final AcpRequestId id;

  /// Request method.
  final String method;

  /// Optional request parameters.
  final Object? params;

  /// Complete request object.
  final AcpJsonMap raw;

  final Future<void> Function(Object? result) _respond;
  final Future<void> Function(int code, String message, Object? data)
  _respondError;
  var _answered = false;

  /// Responds successfully exactly once.
  Future<void> respond([Object? result]) {
    _markAnswered();
    return _respond(result);
  }

  /// Responds with a JSON-RPC error exactly once.
  Future<void> respondError(int code, String message, {Object? data}) {
    _markAnswered();
    return _respondError(code, message, data);
  }

  void _markAnswered() {
    if (_answered) throw StateError('JSON-RPC request was already answered');
    _answered = true;
  }
}

/// A cancellable pending JSON-RPC request.
final class AcpPendingRequest {
  AcpPendingRequest._({
    required this.id,
    required this.method,
    required this.future,
    required void Function() cancel,
  }) : _cancel = cancel;

  /// Request identifier.
  final AcpRequestId id;

  /// Request method.
  final String method;

  /// Future JSON-RPC result.
  final Future<Object?> future;

  final void Function() _cancel;

  /// Cancels local response waiting.
  void cancel() => _cancel();
}

final class _PendingResponse {
  _PendingResponse({
    required this.id,
    required this.method,
    required this.completer,
    required this.timer,
  });

  final AcpRequestId id;
  final String method;
  final Completer<Object?> completer;
  final Timer timer;
}

/// Reusable NDJSON JSON-RPC 2.0 connection for ACP.
final class AcpJsonRpcConnection {
  /// Starts a connection over [transport].
  AcpJsonRpcConnection({
    required AcpTransport transport,
    this.defaultRequestTimeout = const Duration(seconds: 30),
    this.maxFrameSize = 1024 * 1024,
    AcpRequestIdFactory? requestIdFactory,
  }) : _transport = transport,
       _requestIdFactory = requestIdFactory ?? _newUuid {
    if (maxFrameSize <= 0) {
      throw ArgumentError.value(maxFrameSize, 'maxFrameSize');
    }
    _incomingSubscription = transport.incoming.listen(
      _handleBytes,
      onError: _handleTransportError,
      onDone: _handleTransportDone,
      cancelOnError: false,
    );
  }

  /// Default deadline applied to requests.
  final Duration defaultRequestTimeout;

  /// Maximum encoded size of one NDJSON frame.
  final int maxFrameSize;

  final AcpTransport _transport;
  final AcpRequestIdFactory _requestIdFactory;
  final _frameBytes = <int>[];
  final _pending = <AcpRequestId, _PendingResponse>{};
  final _notifications = StreamController<AcpJsonRpcNotification>.broadcast(
    sync: true,
  );
  final _serverRequests = StreamController<AcpJsonRpcServerRequest>.broadcast(
    sync: true,
  );
  final _errors = StreamController<AcpJsonRpcException>.broadcast(sync: true);
  late final StreamSubscription<List<int>> _incomingSubscription;
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _closeFuture;
  var _closed = false;

  /// Received JSON-RPC notifications.
  Stream<AcpJsonRpcNotification> get notifications => _notifications.stream;

  /// Received server-to-client JSON-RPC requests.
  Stream<AcpJsonRpcServerRequest> get serverRequests => _serverRequests.stream;

  /// Protocol and transport failures observed by the connection.
  Stream<AcpJsonRpcException> get errors => _errors.stream;

  /// Whether the connection has closed.
  bool get isClosed => _closed;

  /// Sends a request and returns a cancellable handle.
  AcpPendingRequest sendRequest(
    String method, {
    Object? params,
    Duration? timeout,
    AcpRequestId? id,
  }) {
    _ensureOpen();
    final requestId = id ?? _requestIdFactory();
    if (requestId is! String && requestId is! int) {
      throw ArgumentError.value(
        requestId,
        'id',
        'JSON-RPC IDs must be strings or integers',
      );
    }
    if (_pending.containsKey(requestId)) {
      throw StateError('Duplicate JSON-RPC request ID: $requestId');
    }
    final completer = Completer<Object?>();
    final effectiveTimeout = timeout ?? defaultRequestTimeout;
    late final Timer timer;
    timer = Timer(effectiveTimeout, () {
      final pending = _pending.remove(requestId);
      if (pending == null || pending.completer.isCompleted) return;
      pending.completer.completeError(
        AcpRequestTimeoutException(requestId, method, effectiveTimeout),
      );
    });
    _pending[requestId] = _PendingResponse(
      id: requestId,
      method: method,
      completer: completer,
      timer: timer,
    );
    unawaited(
      _writeMessage(<String, Object?>{
        'jsonrpc': '2.0',
        'id': requestId,
        'method': method,
        'params': ?params,
      }).catchError((Object error, StackTrace stackTrace) {
        final pending = _pending.remove(requestId);
        pending?.timer.cancel();
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.completeError(error, stackTrace);
        }
      }),
    );
    return AcpPendingRequest._(
      id: requestId,
      method: method,
      future: completer.future,
      cancel: () => _cancelRequest(requestId),
    );
  }

  /// Sends a request and awaits its result.
  Future<Object?> request(
    String method, {
    Object? params,
    Duration? timeout,
    AcpRequestId? id,
  }) => sendRequest(method, params: params, timeout: timeout, id: id).future;

  /// Sends a JSON-RPC notification.
  Future<void> notify(String method, {Object? params}) {
    _ensureOpen();
    return _writeMessage(<String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  /// Closes the connection and fails all pending requests.
  Future<void> close() =>
      _closeFuture ??= _terminate(const AcpConnectionClosedException());

  void _handleBytes(List<int> bytes) {
    if (_closed) return;
    for (final byte in bytes) {
      if (byte == 0x0a) {
        final frame = List<int>.of(_frameBytes);
        _frameBytes.clear();
        if (frame.isNotEmpty && frame.last == 0x0d) frame.removeLast();
        if (frame.isNotEmpty) _handleFrame(frame);
        if (_closed) return;
        continue;
      }
      _frameBytes.add(byte);
      if (_frameBytes.length > maxFrameSize) {
        _protocolFailure(
          AcpProtocolException(
            'ACP frame exceeds maximum size of $maxFrameSize bytes',
          ),
        );
        return;
      }
    }
  }

  void _handleFrame(List<int> bytes) {
    if (bytes.length > maxFrameSize) {
      _protocolFailure(
        AcpProtocolException(
          'ACP frame exceeds maximum size of $maxFrameSize bytes',
        ),
      );
      return;
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      _protocolFailure(const AcpProtocolException('Invalid ACP JSON frame'));
      return;
    }
    final message = AcpJson.object(decoded);
    if (message == null || message['jsonrpc'] != '2.0') {
      _protocolFailure(
        const AcpProtocolException('Invalid JSON-RPC 2.0 message'),
      );
      return;
    }
    final method = AcpJson.string(message, 'method');
    final id = message['id'];
    if (method != null) {
      if (id == null) {
        _notifications.add(
          AcpJsonRpcNotification(
            method: method,
            params: message['params'],
            raw: AcpJson.immutableObject(message),
          ),
        );
        return;
      }
      if (id is! String && id is! int) {
        _protocolFailure(
          const AcpProtocolException('Invalid JSON-RPC request ID'),
        );
        return;
      }
      final request = AcpJsonRpcServerRequest._(
        id: id,
        method: method,
        params: message['params'],
        raw: AcpJson.immutableObject(message),
        respond: (result) => _writeMessage(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }),
        respondError: (code, errorMessage, data) =>
            _writeMessage(<String, Object?>{
              'jsonrpc': '2.0',
              'id': id,
              'error': <String, Object?>{
                'code': code,
                'message': errorMessage,
                'data': ?data,
              },
            }),
      );
      _serverRequests.add(request);
      return;
    }
    if (id is! String && id is! int) {
      _protocolFailure(
        const AcpProtocolException('Invalid JSON-RPC response ID'),
      );
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer.cancel();
    final error = AcpJson.objectField(message, 'error');
    if (error != null) {
      pending.completer.completeError(
        AcpRemoteException(
          code: AcpJson.integer(error, 'code') ?? -32000,
          message: AcpJson.string(error, 'message') ?? 'Remote error',
          data: error['data'],
        ),
      );
      return;
    }
    if (!message.containsKey('result')) {
      pending.completer.completeError(
        const AcpProtocolException(
          'JSON-RPC response has neither result nor error',
        ),
      );
      return;
    }
    pending.completer.complete(message['result']);
  }

  void _cancelRequest(AcpRequestId id) {
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.completeError(
        AcpRequestCancelledException(pending.id, pending.method),
      );
    }
  }

  Future<void> _writeMessage(AcpJsonMap message) {
    _ensureOpen();
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    final operation = _writeTail.then((_) => _transport.write(bytes));
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(operation.then<void>((_) {}, onError: _handleTransportError));
    return operation;
  }

  void _handleTransportError(Object error, StackTrace stackTrace) {
    if (_closed) return;
    final reason = AcpConnectionClosedException('ACP transport failed: $error');
    final termination = _terminate(reason, stackTrace);
    if (!_errors.isClosed) _errors.add(reason);
    unawaited(termination);
  }

  void _handleTransportDone() {
    if (_frameBytes.isNotEmpty) {
      _protocolFailure(
        const AcpProtocolException('ACP transport closed mid-frame'),
      );
      return;
    }
    unawaited(
      _terminate(const AcpConnectionClosedException('ACP transport closed')),
    );
  }

  void _protocolFailure(AcpProtocolException error) {
    final termination = _terminate(error);
    if (!_errors.isClosed) _errors.add(error);
    unawaited(termination);
  }

  Future<void> _terminate(
    AcpJsonRpcException reason, [
    StackTrace? stackTrace,
  ]) async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(reason, stackTrace);
      }
    }
    _pending.clear();
    await _incomingSubscription.cancel();
    try {
      await _transport.close();
    } on Object {
      // The connection is already terminal; transport cleanup is best-effort.
    }
    await _notifications.close();
    await _serverRequests.close();
    await _errors.close();
  }

  void _ensureOpen() {
    if (_closed) throw const AcpConnectionClosedException();
  }
}

final _secureRandom = Random.secure();

AcpRequestId _newUuid() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final encoded = bytes.map(hex).join();
  return '${encoded.substring(0, 8)}-'
      '${encoded.substring(8, 12)}-'
      '${encoded.substring(12, 16)}-'
      '${encoded.substring(16, 20)}-'
      '${encoded.substring(20)}';
}
