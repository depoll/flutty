import 'dart:async';
import 'dart:convert';

import '../models/acp_json.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_transport.dart';

/// Default maximum Pi RPC JSONL frame size.
const piRpcDefaultMaxFrameBytes = 20 * 1024 * 1024;

final class _PiPendingResponse {
  _PiPendingResponse({
    required this.command,
    required this.completer,
    required this.timer,
  });

  final String command;
  final Completer<AcpJsonMap> completer;
  final Timer? timer;
}

/// Strict LF-delimited client for Pi's native RPC mode.
final class PiRpcConnection {
  /// Starts reading Pi RPC responses and events from [transport].
  PiRpcConnection({
    required AcpTransport transport,
    this.defaultRequestTimeout = const Duration(seconds: 60),
    this.maxFrameSize = piRpcDefaultMaxFrameBytes,
  }) : _transport = transport {
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

  /// Default command response deadline.
  final Duration defaultRequestTimeout;

  /// Maximum encoded JSONL frame size.
  final int maxFrameSize;

  final AcpTransport _transport;
  final List<int> _frameBytes = <int>[];
  final Map<String, _PiPendingResponse> _pending =
      <String, _PiPendingResponse>{};
  final StreamController<AcpJsonMap> _events =
      StreamController<AcpJsonMap>.broadcast(sync: true);
  final StreamController<AcpJsonRpcException> _errors =
      StreamController<AcpJsonRpcException>.broadcast(sync: true);
  late final StreamSubscription<List<int>> _incomingSubscription;
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _closeFuture;
  var _nextRequestId = 0;
  var _closed = false;

  /// Unsolicited Pi agent and extension UI events.
  Stream<AcpJsonMap> get events => _events.stream;

  /// Protocol and transport failures.
  Stream<AcpJsonRpcException> get errors => _errors.stream;

  /// Sends one typed RPC command and returns its successful response data.
  Future<AcpJsonMap> request(
    String command, {
    AcpJsonMap fields = const <String, Object?>{},
    Duration? timeout,
    bool noTimeout = false,
  }) {
    _ensureOpen();
    final id = 'monkeyssh-pi-${_nextRequestId++}';
    final completer = Completer<AcpJsonMap>();
    final effectiveTimeout = noTimeout
        ? null
        : timeout ?? defaultRequestTimeout;
    final timer = effectiveTimeout == null
        ? null
        : Timer(effectiveTimeout, () {
            final pending = _pending.remove(id);
            if (pending == null || pending.completer.isCompleted) return;
            pending.completer.completeError(
              AcpRequestTimeoutException(id, command, effectiveTimeout),
            );
          });
    _pending[id] = _PiPendingResponse(
      command: command,
      completer: completer,
      timer: timer,
    );
    unawaited(
      _writeMessage(<String, Object?>{
        'id': id,
        'type': command,
        ...fields,
      }).catchError((Object error, StackTrace stackTrace) {
        final pending = _pending.remove(id);
        pending?.timer?.cancel();
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.completeError(error, stackTrace);
        }
      }),
    );
    return completer.future;
  }

  /// Sends an extension UI response, which is not command-correlated.
  Future<void> send(AcpJsonMap message) => _writeMessage(message);

  /// Closes the connection and underlying transport.
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
            'Pi RPC frame exceeds maximum size of $maxFrameSize bytes',
          ),
        );
        return;
      }
    }
  }

  void _handleFrame(List<int> bytes) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      _protocolFailure(const AcpProtocolException('Invalid Pi RPC JSON frame'));
      return;
    }
    final message = AcpJson.object(decoded);
    final type = message == null ? null : AcpJson.string(message, 'type');
    if (message == null || type == null) {
      _protocolFailure(const AcpProtocolException('Invalid Pi RPC message'));
      return;
    }
    if (type != 'response') {
      _events.add(AcpJson.immutableObject(message));
      return;
    }
    final id = AcpJson.string(message, 'id');
    if (id == null) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    if (!(AcpJson.boolean(message, 'success') ?? false)) {
      pending.completer.completeError(
        AcpRemoteException(
          code: -32000,
          message:
              AcpJson.string(message, 'error') ??
              'Pi rejected ${pending.command}',
        ),
      );
      return;
    }
    pending.completer.complete(AcpJson.immutableObject(message));
  }

  Future<void> _writeMessage(AcpJsonMap message) {
    _ensureOpen();
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length > maxFrameSize) {
      return Future<void>.error(
        AcpProtocolException(
          'Pi RPC frame exceeds maximum size of $maxFrameSize bytes',
        ),
      );
    }
    final operation = _writeTail.then((_) => _transport.write(bytes));
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    unawaited(operation.then<void>((_) {}, onError: _handleTransportError));
    return operation;
  }

  void _handleTransportError(Object error, StackTrace stackTrace) {
    if (_closed) return;
    final reason = AcpConnectionClosedException(
      'Pi RPC transport failed: ${error.runtimeType}',
    );
    if (!_errors.isClosed) _errors.add(reason);
    unawaited(_terminate(reason, stackTrace));
  }

  void _handleTransportDone() {
    if (_frameBytes.isNotEmpty) {
      _protocolFailure(
        const AcpProtocolException('Pi RPC transport closed mid-frame'),
      );
      return;
    }
    unawaited(
      _terminate(const AcpConnectionClosedException('Pi RPC transport closed')),
    );
  }

  void _protocolFailure(AcpProtocolException error) {
    if (!_errors.isClosed) _errors.add(error);
    unawaited(_terminate(error));
  }

  Future<void> _terminate(
    AcpJsonRpcException reason, [
    StackTrace? stackTrace,
  ]) async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(reason, stackTrace);
      }
    }
    _pending.clear();
    await _incomingSubscription.cancel();
    await _transport.close();
    await _events.close();
    await _errors.close();
  }

  void _ensureOpen() {
    if (_closed) throw const AcpConnectionClosedException();
  }
}
