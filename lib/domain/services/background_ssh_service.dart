import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ssh_service.dart';

/// Platform service that keeps SSH connections alive while the app is
/// in the background.
///
/// On Android this shows a persistent notification. On iOS this updates the
/// native background activity state when supported.
class BackgroundSshService {
  BackgroundSshService._();

  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/ssh_service');

  /// Synchronizes the platform keep-alive surface with the active connections.
  static Future<void> syncConnections(
    Iterable<ActiveConnection> connections,
  ) async {
    if (kIsWeb) return;

    final activeConnections = connections
        .where(
          (connection) =>
              connection.state == SshConnectionState.connected ||
              connection.state == SshConnectionState.connecting ||
              connection.state == SshConnectionState.authenticating ||
              connection.state == SshConnectionState.reconnecting,
        )
        .toList(growable: false);

    if (activeConnections.isEmpty) {
      await stop();
      return;
    }

    final hostNames = activeConnections
        .map((connection) => connection.config.hostname)
        .toSet()
        .toList(growable: false);

    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('syncService', {
          'activeConnectionCount': activeConnections.length,
          'hostNames': hostNames,
        });
      } else if (Platform.isIOS) {
        await _channel.invokeMethod<void>('syncLiveActivity', {
          'activeConnectionCount': activeConnections.length,
          'hostNames': hostNames,
          'hostSummary': _summarizeHosts(hostNames),
        });
      }
    } on PlatformException {
      // Native background keep-alive hooks may not be available on all devices.
    }
  }

  /// Stop the background service.
  static Future<void> stop() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
    try {
      await _channel.invokeMethod<void>('stopService');
    } on PlatformException {
      // Service may already be stopped or unavailable.
    }
  }

  static String _summarizeHosts(List<String> hostNames) {
    if (hostNames.isEmpty) {
      return 'No active connections';
    }
    if (hostNames.length == 1) {
      return hostNames.first;
    }
    if (hostNames.length == 2) {
      return '${hostNames.first} and ${hostNames.last}';
    }
    return '${hostNames.first}, ${hostNames[1]}, +${hostNames.length - 2} more';
  }
}
