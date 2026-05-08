import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
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
    Duration? timeout,
  }) async {
    final uri = normalizeDevTunnelWebSocketUri(url);
    final headers = <String, String>{'X-Tunnel-Skip-AntiPhishing-Page': 'true'};
    final authorization = authorizationHeader?.trim();
    if (authorization != null && authorization.isNotEmpty) {
      headers['X-Tunnel-Authorization'] = authorization;
    }

    try {
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
    } on FormatException catch (error) {
      throw DevTunnelConnectionException(error.message);
    } on WebSocketException catch (error) {
      throw DevTunnelConnectionException(
        'Dev Tunnel connection failed: ${error.message}',
      );
    }
  }
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
    if (parsedPort != null && parsedPort >= 1 && parsedPort <= 65535) {
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
  _DevTunnelSshSocket(this._socket) {
    _sinkController.stream.listen(
      (data) {
        if (_socket.readyState == WebSocket.open) {
          _socket.add(data is Uint8List ? data : Uint8List.fromList(data));
        }
      },
      onDone: () {
        if (_socket.readyState == WebSocket.open) {
          unawaited(_socket.close());
        }
      },
    );
  }

  final WebSocket _socket;
  final _sinkController = StreamController<List<int>>();

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
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() async {
    await _sinkController.close();
    await _socket.close();
  }

  @override
  Future<void> get done async {
    await _socket.done;
  }

  @override
  void destroy() {
    unawaited(close());
  }
}
