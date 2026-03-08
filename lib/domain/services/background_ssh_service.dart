import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform service that keeps SSH connections alive while the app is
/// in the background.
///
/// On Android this controls the persistent keepalive notification.
/// On iOS this controls the Live Activity shown while the app is backgrounded.
class BackgroundSshService {
  BackgroundSshService._();

  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/ssh_service');

  /// Publish the latest active connection status to native keepalive surfaces.
  static Future<void> updateStatus({
    required int connectionCount,
    required int connectedCount,
    required String primaryLabel,
    String? primaryPreview,
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateStatus', {
        'connectionCount': connectionCount,
        'connectedCount': connectedCount,
        'primaryLabel': primaryLabel,
        'primaryPreview': primaryPreview,
      });
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to update background SSH status: ${error.message ?? error.code}',
      );
    }
  }

  /// Tell native keepalive surfaces whether the app is currently foregrounded.
  static Future<void> setForegroundState({required bool isForeground}) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setForegroundState', {
        'isForeground': isForeground,
      });
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to update background SSH lifecycle: '
        '${error.message ?? error.code}',
      );
    }
  }

  /// Stop the background service.
  static Future<void> stop() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopService');
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to stop background SSH status: ${error.message ?? error.code}',
      );
    }
  }
}
