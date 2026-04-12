import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform service that publishes SSH session status to native background UI.
///
/// On Android this controls the foreground-service notification.
/// On iOS this controls the Live Activity shown while the app is backgrounded.
///
/// This surface reports status only; iOS may still suspend the app shortly
/// after it enters the background.
class BackgroundSshService {
  BackgroundSshService._();

  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/ssh_service');
  static bool get _supportsPlatform =>
      debugIsSupportedPlatformOverride ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS));
  static bool get _supportsBatteryOptimizationControls =>
      debugIsAndroidPlatformOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Overrides platform support checks in tests.
  ///
  /// Set to `null` to use the real runtime platform detection.
  @visibleForTesting
  static bool? debugIsSupportedPlatformOverride;

  /// Overrides Android-only battery optimization support checks in tests.
  ///
  /// Set to `null` to use the real runtime platform detection.
  @visibleForTesting
  static bool? debugIsAndroidPlatformOverride;

  /// Whether Android battery-optimization controls are available.
  static bool get supportsBatteryOptimizationControls =>
      _supportsBatteryOptimizationControls;

  /// Publish the latest active connection status to native background UI.
  static Future<void> updateStatus({
    required int connectionCount,
    required int connectedCount,
  }) async {
    if (!_supportsPlatform) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateStatus', {
        'connectionCount': connectionCount,
        'connectedCount': connectedCount,
      });
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to update background SSH status: ${error.message ?? error.code}',
      );
    } on MissingPluginException catch (error) {
      debugPrint(
        'Failed to update background SSH status: '
        '${error.message ?? 'missing plugin'}',
      );
    }
  }

  /// Tell native background UI whether the app is currently foregrounded.
  static Future<void> setForegroundState({required bool isForeground}) async {
    if (!_supportsPlatform) {
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
    } on MissingPluginException catch (error) {
      debugPrint(
        'Failed to update background SSH lifecycle: '
        '${error.message ?? 'missing plugin'}',
      );
    }
  }

  /// Stop the background service.
  static Future<void> stop() async {
    if (!_supportsPlatform) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopService');
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to stop background SSH status: ${error.message ?? error.code}',
      );
    } on MissingPluginException catch (error) {
      debugPrint(
        'Failed to stop background SSH status: '
        '${error.message ?? 'missing plugin'}',
      );
    }
  }

  /// Whether Android battery optimization is already disabled for the app.
  static Future<bool> isBatteryOptimizationIgnored() async {
    if (!_supportsBatteryOptimizationControls) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'isBatteryOptimizationIgnored',
          ) ??
          false;
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to read Android battery optimization status: '
        '${error.message ?? error.code}',
      );
      return false;
    } on MissingPluginException catch (error) {
      debugPrint(
        'Failed to read Android battery optimization status: '
        '${error.message ?? 'missing plugin'}',
      );
      return false;
    }
  }

  /// Open Android settings so the user can disable battery optimization.
  static Future<bool> requestDisableBatteryOptimization() async {
    if (!_supportsBatteryOptimizationControls) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'requestDisableBatteryOptimization',
          ) ??
          false;
    } on PlatformException catch (error) {
      debugPrint(
        'Failed to open Android battery optimization settings: '
        '${error.message ?? error.code}',
      );
      return false;
    } on MissingPluginException catch (error) {
      debugPrint(
        'Failed to open Android battery optimization settings: '
        '${error.message ?? 'missing plugin'}',
      );
      return false;
    }
  }
}
