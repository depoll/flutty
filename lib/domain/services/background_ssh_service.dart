import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform service that keeps SSH connections alive while the app is
/// in the background.
///
/// On Android this starts a foreground service with a persistent notification.
/// On iOS this is a no-op — background task handling is done natively in
/// AppDelegate via `beginBackgroundTaskWithExpirationHandler`.
class BackgroundSshService {
  BackgroundSshService._();

  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/ssh_service');

  /// Start the background service for the given host.
  static Future<void> start({required String hostName}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startService', {'hostName': hostName});
    } on PlatformException {
      // Foreground service may not be available on all devices.
    }
  }

  /// Stop the background service.
  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopService');
    } on PlatformException {
      // Service may already be stopped.
    }
  }
}
