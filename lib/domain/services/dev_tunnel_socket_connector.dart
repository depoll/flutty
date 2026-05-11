// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/message/msg_request.dart';
import 'package:dartssh2/src/message/msg_service.dart';
import 'package:dartssh2/src/message/msg_userauth.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_channel_id.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter/foundation.dart';

/// Error raised when a Dev Tunnel socket cannot be prepared.
class DevTunnelConnectionException implements Exception {
  /// Creates a [DevTunnelConnectionException].
  const DevTunnelConnectionException(this.message);

  /// User-facing error message.
  final String message;

  @override
  String toString() => message;
}

/// Opens SSH byte streams through GitHub/Microsoft Dev Tunnel forwarding URLs.
class DevTunnelSocketConnector {
  DevTunnelSocketConnector._();

  /// Opens a WebSocket-backed [SSHSocket] to [url].
  static Future<SSHSocket> connect(
    String url, {
    String? authorizationHeader,
    Uri? clientRelayUri,
    int? portNumber,
    String? protocol,
    Duration? timeout,
  }) async {
    try {
      if (_isKnownWebOnlyProtocol(protocol)) {
        final protocolLabel = protocol!.trim().toUpperCase();
        throw DevTunnelConnectionException(
          'This Dev Tunnel port is $protocolLabel, not SSH. Choose a Dev '
          'Tunnel port that forwards an SSH server, usually port 22.',
        );
      }
      if (clientRelayUri != null && portNumber != null) {
        return await _connectThroughRelay(
          clientRelayUri,
          authorizationHeader: authorizationHeader,
          portNumber: portNumber,
          timeout: timeout,
        );
      }
      if (authorizationHeader?.trim().isNotEmpty ?? false) {
        throw const DevTunnelConnectionException(
          'Dev Tunnel access did not include a relay endpoint. Refresh tunnels '
          'and select the SSH port again.',
        );
      }
      return await _connectDirectWebForwarding(
        url,
        authorizationHeader: authorizationHeader,
        timeout: timeout,
      );
    } on FormatException catch (error) {
      throw DevTunnelConnectionException(error.message);
    } on TimeoutException {
      throw const DevTunnelConnectionException(
        'Timed out while opening the Dev Tunnel connection. Make sure the '
        'tunnel host is online and the selected port forwards SSH.',
      );
    } on WebSocketException catch (error) {
      throw DevTunnelConnectionException(
        'Dev Tunnel connection failed: ${error.message}',
      );
    } on SSHError catch (error) {
      throw DevTunnelConnectionException(
        'Dev Tunnel relay connected, but opening the forwarded SSH port failed: '
        '$error',
      );
    }
  }

  static Future<SSHSocket> _connectDirectWebForwarding(
    String url, {
    String? authorizationHeader,
    Duration? timeout,
  }) async {
    final uri = parseDevTunnelForwardingUrl(url).uri;
    final headers = <String, String>{'X-Tunnel-Skip-AntiPhishing-Page': 'true'};
    final authorization = authorizationHeader?.trim();
    if (authorization != null && authorization.isNotEmpty) {
      headers['X-Tunnel-Authorization'] = authorization;
    }

    final socketFuture = WebSocket.connect(
      uri.toString(),
      headers: headers,
      compression: CompressionOptions.compressionOff,
    );
    // ignore: close_sinks — returned SSHSocket owns and closes the WebSocket.
    final socket =
        (timeout == null
              ? await socketFuture
              : await socketFuture.timeout(timeout))
          ..pingInterval = const Duration(seconds: 30);
    return _DevTunnelSshSocket(socket);
  }

  static Future<SSHSocket> _connectThroughRelay(
    Uri clientRelayUri, {
    required String? authorizationHeader,
    required int portNumber,
    Duration? timeout,
  }) async {
    final headers = <String, String>{};
    final authorization = authorizationHeader?.trim();
    if (authorization != null && authorization.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = authorization;
    }

    final socketFuture = WebSocket.connect(
      clientRelayUri.toString(),
      protocols: const ['tunnel-relay-client'],
      headers: headers,
      compression: CompressionOptions.compressionOff,
    );
    // ignore: close_sinks — relayClient owns and closes the WebSocket.
    final webSocket =
        (timeout == null
              ? await socketFuture
              : await socketFuture.timeout(timeout))
          ..pingInterval = const Duration(seconds: 30);
    final relaySocket = _DevTunnelSshSocket(webSocket);
    final relayClient = _DevTunnelRelayClient(relaySocket);
    try {
      if (timeout == null) {
        await relayClient.authenticated;
      } else {
        await relayClient.authenticated.timeout(timeout);
      }
      final forwardedSocket = await relayClient.openForwardedPort(
        portNumber,
        timeout: timeout,
      );
      return _DevTunnelRelayForwardedSshSocket(
        forwardedSocket: forwardedSocket,
        relayClient: relayClient,
      );
    } on Object {
      relayClient.close();
      rethrow;
    }
  }
}

bool _isKnownWebOnlyProtocol(String? protocol) {
  final normalized = protocol?.trim().toLowerCase();
  return normalized == 'http' ||
      normalized == 'https' ||
      normalized == 'ws' ||
      normalized == 'wss';
}

/// Parsed components of a standard `devtunnels.ms` forwarding URL.
@immutable
class DevTunnelForwardingUrl {
  /// Creates parsed Dev Tunnel forwarding URL details.
  const DevTunnelForwardingUrl({
    required this.uri,
    required this.tunnelId,
    required this.clusterId,
    required this.port,
  });

  /// WebSocket-normalized forwarding URI.
  final Uri uri;

  /// Dev Tunnel ID from the forwarding hostname.
  final String tunnelId;

  /// Dev Tunnel cluster ID from the forwarding hostname.
  final String clusterId;

  /// Tunnel port number from the URL, if one can be resolved.
  final int? port;
}

/// Normalizes a Dev Tunnel forwarding URL to a WebSocket URL.
Uri normalizeDevTunnelWebSocketUri(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Enter a Dev Tunnel forwarding URL.');
  }

  final parsed = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'wss://$trimmed',
  );
  if (parsed == null || parsed.host.isEmpty) {
    throw const FormatException('Enter a valid Dev Tunnel forwarding URL.');
  }

  final scheme = switch (parsed.scheme.toLowerCase()) {
    'https' => 'wss',
    'http' => 'ws',
    'wss' => 'wss',
    'ws' => 'ws',
    _ => throw const FormatException(
      'Dev Tunnel URLs must start with https://, http://, wss://, or ws://.',
    ),
  };

  return parsed.replace(scheme: scheme);
}

/// Parses a standard Dev Tunnel forwarding URL.
DevTunnelForwardingUrl parseDevTunnelForwardingUrl(
  String rawUrl, {
  int? fallbackPort,
}) {
  final uri = normalizeDevTunnelWebSocketUri(rawUrl);
  final labels = uri.host.split('.');
  if (labels.length < 4 ||
      labels[labels.length - 2] != 'devtunnels' ||
      labels.last != 'ms') {
    throw const FormatException('Use a standard devtunnels.ms forwarding URL.');
  }

  final tunnelLabel = labels.first;
  final clusterId = labels[labels.length - 3];
  if (tunnelLabel.isEmpty || clusterId.isEmpty) {
    throw const FormatException('Enter a valid Dev Tunnel forwarding URL.');
  }

  final parsedExplicitPort = uri.hasPort ? uri.port : null;
  var tunnelId = tunnelLabel;
  var port = parsedExplicitPort ?? fallbackPort;
  final subdomainPortMatch = RegExp(
    r'^(.+)-([0-9]{1,5})$',
  ).firstMatch(tunnelLabel);
  if (parsedExplicitPort == null && subdomainPortMatch != null) {
    final parsedPort = int.tryParse(subdomainPortMatch.group(2)!);
    if (parsedPort != null &&
        parsedPort >= 1 &&
        parsedPort <= 65535 &&
        (fallbackPort == null || parsedPort == fallbackPort)) {
      tunnelId = subdomainPortMatch.group(1)!;
      port = parsedPort;
    }
  }

  return DevTunnelForwardingUrl(
    uri: uri,
    tunnelId: tunnelId,
    clusterId: clusterId,
    port: port,
  );
}

class _DevTunnelSshSocket implements SSHSocket {
  _DevTunnelSshSocket(this._socket) : _sink = _DevTunnelSshSocketSink(_socket);

  final WebSocket _socket;
  final _DevTunnelSshSocketSink _sink;

  @override
  Stream<Uint8List> get stream => _socket.map((message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    if (message is String) {
      throw const DevTunnelConnectionException(
        'Dev Tunnel returned text data instead of an SSH byte stream.',
      );
    }
    throw DevTunnelConnectionException(
      'Dev Tunnel returned unsupported data: ${message.runtimeType}.',
    );
  });

  @override
  StreamSink<List<int>> get sink => _sink;

  @override
  Future<void> close() async {
    await _sink.close();
  }

  @override
  Future<void> get done async {
    await _socket.done;
  }

  @override
  void destroy() {
    _sink.destroy();
  }
}

class _DevTunnelSshSocketSink implements StreamSink<List<int>> {
  _DevTunnelSshSocketSink(this._socket);

  final WebSocket _socket;
  var _closed = false;

  @override
  void add(List<int> event) {
    if (_closed || _socket.readyState != WebSocket.open) {
      throw const DevTunnelConnectionException(
        'Dev Tunnel connection closed before SSH data could be sent.',
      );
    }
    _socket.add(event is Uint8List ? event : Uint8List.fromList(event));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed || _socket.readyState != WebSocket.open) {
      throw const DevTunnelConnectionException(
        'Dev Tunnel connection closed before SSH data could be sent.',
      );
    }
    _socket.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      await done;
      return;
    }
    _closed = true;
    if (_socket.readyState == WebSocket.open) {
      await _socket.close();
    }
    await done;
  }

  @override
  Future<void> get done async {
    await _socket.done;
  }

  void destroy() {
    _closed = true;
    if (_socket.readyState == WebSocket.open) {
      unawaited(_socket.close());
    }
  }
}

class _DevTunnelRelayClient {
  _DevTunnelRelayClient(SSHSocket socket) {
    _transport = SSHTransport(
      socket,
      disableHostkeyVerification: true,
      onReady: _requestAuthentication,
      onPacket: _dispatchMessage,
    );
    unawaited(
      _transport.done.then<void>(
        (_) {
          _completePending(
            const DevTunnelConnectionException('Dev Tunnel relay closed.'),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          _completePending(error, stackTrace);
        },
      ),
    );
  }

  static const _initialWindowSize = 1024 * 1024 * 2;
  static const _maximumPacketSize = 32768;
  static const _relayUsername = 'tunnel';

  late final SSHTransport _transport;
  final _authenticated = Completer<void>();
  final _channelIdAllocator = SSHChannelIdAllocator();
  final _channelOpenReplyWaiters = <SSHChannelId, Completer<SSHMessage>>{};
  final _channels = <SSHChannelId, SSHChannelController>{};
  final _forwardedPorts = <int>{};
  final _forwardedPortWaiters = <int, List<Completer<void>>>{};

  Future<void> get authenticated => _authenticated.future;

  Future<SSHSocket> openForwardedPort(int port, {Duration? timeout}) async {
    final waitFuture = _waitForForwardedPort(port);
    if (timeout == null) {
      await waitFuture;
    } else {
      await waitFuture.timeout(
        timeout,
        onTimeout: () {
          throw DevTunnelConnectionException(
            'Dev Tunnel port $port is not available for SSH forwarding.',
          );
        },
      );
    }

    final channelFuture = _openForwardedTcpipChannel(port);
    final channel = timeout == null
        ? await channelFuture
        : await channelFuture.timeout(timeout);
    return SSHForwardChannel(channel.channel);
  }

  void close() {
    _transport.close();
  }

  void _requestAuthentication() {
    _sendMessage(SSH_Message_Service_Request('ssh-userauth'));
  }

  void _dispatchMessage(Uint8List payload) {
    final messageId = SSHMessage.readMessageId(payload);
    switch (messageId) {
      case SSH_Message_Service_Accept.messageId:
        return _handleServiceAccept(payload);
      case SSH_Message_Userauth_Success.messageId:
        return _handleUserauthSuccess();
      case SSH_Message_Userauth_Failure.messageId:
        return _handleUserauthFailure(payload);
      case SSH_Message_Userauth_Banner.messageId:
        return;
      case SSH_Message_Global_Request.messageId:
        return _handleGlobalRequest(payload);
      case SSH_Message_Channel_Confirmation.messageId:
        return _handleChannelConfirmation(payload);
      case SSH_Message_Channel_Open_Failure.messageId:
        return _handleChannelOpenFailure(payload);
      case SSH_Message_Channel_Window_Adjust.messageId:
        return _handleChannelWindowAdjust(payload);
      case SSH_Message_Channel_Data.messageId:
        return _handleChannelData(payload);
      case SSH_Message_Channel_Extended_Data.messageId:
        return _handleChannelExtendedData(payload);
      case SSH_Message_Channel_EOF.messageId:
        return _handleChannelEOF(payload);
      case SSH_Message_Channel_Close.messageId:
        return _handleChannelClose(payload);
      case SSH_Message_Channel_Request.messageId:
        return _handleChannelRequest(payload);
      case SSH_Message_Channel_Success.messageId:
        return _handleChannelSuccess(payload);
      case SSH_Message_Channel_Failure.messageId:
        return _handleChannelFailure(payload);
      case SSH_Message_Channel_Open.messageId:
        return _handleChannelOpen(payload);
      case SSH_Message_Request_Success.messageId:
      case SSH_Message_Request_Failure.messageId:
        return;
      default:
        _transport.closeWithError(
          SSHStateError('Unexpected Dev Tunnel relay message: $messageId'),
        );
    }
  }

  void _handleServiceAccept(Uint8List payload) {
    final message = SSH_Message_Service_Accept.decode(payload);
    if (message.serviceName != 'ssh-userauth') {
      _transport.closeWithError(
        SSHAuthAbortError('Dev Tunnel relay rejected ssh-userauth service.'),
      );
      return;
    }
    _sendMessage(SSH_Message_Userauth_Request.none(user: _relayUsername));
  }

  void _handleUserauthSuccess() {
    if (!_authenticated.isCompleted) {
      _authenticated.complete();
    }
  }

  void _handleUserauthFailure(Uint8List payload) {
    final message = SSH_Message_Userauth_Failure.decode(payload);
    final error = SSHAuthFailError(
      'Dev Tunnel relay authentication failed: ${message.methodsLeft.join(', ')}',
    );
    if (!_authenticated.isCompleted) {
      _authenticated.completeError(error, StackTrace.current);
    }
    _transport.closeWithError(error);
  }

  void _handleGlobalRequest(Uint8List payload) {
    final message = SSH_Message_Global_Request.decode(payload);
    switch (message.requestName) {
      case 'tcpip-forward':
        final bindPort = message.bindPort;
        if (bindPort != null && bindPort > 0) {
          _markForwardedPortReady(bindPort);
        }
        if (message.wantReply) {
          _sendMessage(SSH_Message_Request_Success(Uint8List(0)));
        }
        return;
      case 'cancel-tcpip-forward':
        final bindPort = message.bindPort;
        if (bindPort != null) {
          _forwardedPorts.remove(bindPort);
        }
        if (message.wantReply) {
          _sendMessage(SSH_Message_Request_Success(Uint8List(0)));
        }
        return;
    }

    if (message.wantReply) {
      _sendMessage(SSH_Message_Request_Failure());
    }
  }

  void _handleChannelOpen(Uint8List payload) {
    final message = SSH_Message_Channel_Open.decode(payload);
    _sendMessage(
      SSH_Message_Channel_Open_Failure(
        recipientChannel: message.senderChannel,
        reasonCode: SSH_Message_Channel_Open_Failure.codeUnknownChannelType,
        description: 'Unexpected Dev Tunnel relay channel type.',
      ),
    );
  }

  void _handleChannelConfirmation(Uint8List payload) {
    final message = SSH_Message_Channel_Confirmation.decode(payload);
    _dispatchChannelOpenReply(message.recipientChannel, message);
  }

  void _handleChannelOpenFailure(Uint8List payload) {
    final message = SSH_Message_Channel_Open_Failure.decode(payload);
    _dispatchChannelOpenReply(message.recipientChannel, message);
  }

  void _handleChannelWindowAdjust(Uint8List payload) {
    final message = SSH_Message_Channel_Window_Adjust.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelData(Uint8List payload) {
    final message = SSH_Message_Channel_Data.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelExtendedData(Uint8List payload) {
    final message = SSH_Message_Channel_Extended_Data.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelEOF(Uint8List payload) {
    final message = SSH_Message_Channel_EOF.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelClose(Uint8List payload) {
    final message = SSH_Message_Channel_Close.decode(payload);
    final channel = _channels.remove(message.recipientChannel);
    if (channel != null) {
      channel.handleMessage(message);
      _channelIdAllocator.release(message.recipientChannel);
    }
  }

  void _handleChannelRequest(Uint8List payload) {
    final message = SSH_Message_Channel_Request.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelSuccess(Uint8List payload) {
    final message = SSH_Message_Channel_Success.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelFailure(Uint8List payload) {
    final message = SSH_Message_Channel_Failure.decode(payload);
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  Future<void> _waitForForwardedPort(int port) {
    if (_forwardedPorts.contains(port)) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    (_forwardedPortWaiters[port] ??= <Completer<void>>[]).add(completer);
    return completer.future;
  }

  void _markForwardedPortReady(int port) {
    _forwardedPorts.add(port);
    final waiters = _forwardedPortWaiters.remove(port);
    if (waiters == null) {
      return;
    }
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  Future<SSHChannelController> _openForwardedTcpipChannel(int port) async {
    final localChannelId = _channelIdAllocator.allocate();
    final request = SSH_Message_Channel_Open.forwardedTcpip(
      senderChannel: localChannelId,
      initialWindowSize: _initialWindowSize,
      maximumPacketSize: _maximumPacketSize,
      host: '127.0.0.1',
      port: port,
      originatorIP: '',
      originatorPort: 0,
    );
    _sendMessage(request);

    final message = await _waitChannelOpenReply(localChannelId);
    if (message is SSH_Message_Channel_Open_Failure) {
      _channelIdAllocator.release(localChannelId);
      throw DevTunnelConnectionException(
        'Dev Tunnel forwarded port failed to open: ${message.description}',
      );
    }

    final confirmation = message as SSH_Message_Channel_Confirmation;
    if (confirmation.recipientChannel != localChannelId) {
      _channelIdAllocator.release(localChannelId);
      throw const DevTunnelConnectionException(
        'Dev Tunnel relay sent an unexpected channel confirmation.',
      );
    }

    return _acceptChannel(
      localChannelId: localChannelId,
      remoteChannelId: confirmation.senderChannel,
      remoteInitialWindowSize: confirmation.initialWindowSize,
      remoteMaximumPacketSize: confirmation.maximumPacketSize,
    );
  }

  Future<SSHMessage> _waitChannelOpenReply(SSHChannelId id) {
    final existingWaiter = _channelOpenReplyWaiters[id];
    if (existingWaiter != null) {
      return existingWaiter.future;
    }

    final completer = Completer<SSHMessage>();
    _channelOpenReplyWaiters[id] = completer;
    return completer.future;
  }

  void _dispatchChannelOpenReply(SSHChannelId id, SSHMessage message) {
    final completer = _channelOpenReplyWaiters.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(message);
  }

  SSHChannelController _acceptChannel({
    required SSHChannelId localChannelId,
    required SSHChannelId remoteChannelId,
    required int remoteInitialWindowSize,
    required int remoteMaximumPacketSize,
  }) {
    final channelController = SSHChannelController(
      localId: localChannelId,
      localInitialWindowSize: _initialWindowSize,
      localMaximumPacketSize: _maximumPacketSize,
      remoteId: remoteChannelId,
      remoteInitialWindowSize: remoteInitialWindowSize,
      remoteMaximumPacketSize: remoteMaximumPacketSize,
      sendMessage: _sendMessage,
    );
    _channels[localChannelId] = channelController;
    return channelController;
  }

  void _sendMessage(SSHMessage message) {
    if (_transport.isClosed) {
      return;
    }
    _transport.sendPacket(message.encode());
  }

  void _completePending(Object error, [StackTrace? stackTrace]) {
    if (!_authenticated.isCompleted) {
      _authenticated.completeError(error, stackTrace ?? StackTrace.current);
    }

    for (final completer in _channelOpenReplyWaiters.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace ?? StackTrace.current);
      }
    }
    _channelOpenReplyWaiters.clear();

    for (final waiters in _forwardedPortWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.completeError(error, stackTrace ?? StackTrace.current);
        }
      }
    }
    _forwardedPortWaiters.clear();

    for (final channel in _channels.values) {
      channel.destroy();
    }
    _channels.clear();
  }
}

class _DevTunnelRelayForwardedSshSocket implements SSHSocket {
  _DevTunnelRelayForwardedSshSocket({
    required SSHSocket forwardedSocket,
    required _DevTunnelRelayClient relayClient,
  }) : _forwardedSocket = forwardedSocket,
       _relayClient = relayClient;

  final SSHSocket _forwardedSocket;
  final _DevTunnelRelayClient _relayClient;

  @override
  Stream<Uint8List> get stream => _forwardedSocket.stream;

  @override
  StreamSink<List<int>> get sink => _forwardedSocket.sink;

  @override
  Future<void> close() async {
    try {
      await _forwardedSocket.close();
    } finally {
      _relayClient.close();
    }
  }

  @override
  Future<void> get done => _forwardedSocket.done;

  @override
  void destroy() {
    _forwardedSocket.destroy();
    _relayClient.close();
  }
}
