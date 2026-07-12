/// Tracks the SFTP client used by the agent chat for remote uploads and
/// resource reads, keyed by the SSH connection that owns it.
///
/// When the host reconnects under a new `connectionId`, the previously cached
/// client belongs to a dead connection and must never be reused. This cache
/// discards the stale reference and reopens against the live connection before
/// any upload or read.
library;

import 'package:dartssh2/dartssh2.dart';

/// Opens a fresh SFTP client for the current SSH connection.
typedef AcpSftpClientOpener = Future<SftpClient> Function();

/// Connection-aware cache for a single host's SFTP client.
class AcpSftpClientCache {
  SftpClient? _client;
  int? _connectionId;
  Future<SftpClient?>? _opening;
  int? _openingConnectionId;

  /// The connectionId that currently owns the cached client, if any.
  int? get connectionId => _connectionId;

  /// Returns the cached client only when it is owned by [connectionId];
  /// otherwise returns `null` (the caller should [ensure] a fresh one).
  SftpClient? clientForConnection(int? connectionId) {
    if (_client == null || connectionId == null) {
      return null;
    }
    return connectionId == _connectionId ? _client : null;
  }

  /// Drops the cached client if it is not owned by [connectionId].
  void invalidateIfStale(int? connectionId) {
    if (connectionId != _connectionId) {
      _client = null;
      _connectionId = null;
    }
  }

  /// Returns a client owned by [connectionId], reusing the cached one when it
  /// matches and otherwise opening a fresh client via [open].
  ///
  /// Concurrent calls for the same connection share one in-flight open. A
  /// `null` [connectionId] (no live SSH session) clears the cache and resolves
  /// to `null`.
  Future<SftpClient?> ensure({
    required int? connectionId,
    required AcpSftpClientOpener open,
  }) async {
    if (connectionId == null) {
      _client = null;
      _connectionId = null;
      return null;
    }
    if (_client != null && _connectionId == connectionId) {
      return _client;
    }
    // The cached client (if any) belongs to a stale connection.
    _client = null;
    _connectionId = null;
    final pending = _opening;
    if (pending != null && _openingConnectionId == connectionId) {
      return pending;
    }
    final future = _open(connectionId, open);
    _opening = future;
    _openingConnectionId = connectionId;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) {
        _opening = null;
        _openingConnectionId = null;
      }
    }
  }

  Future<SftpClient?> _open(int connectionId, AcpSftpClientOpener open) async {
    try {
      final client = await open();
      _client = client;
      _connectionId = connectionId;
      return client;
    } on Object {
      return null;
    }
  }
}
