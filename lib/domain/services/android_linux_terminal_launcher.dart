import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Status of the system AVF Linux Terminal app on this device.
@immutable
class AndroidLinuxTerminalStatus {
  /// Creates a terminal status snapshot.
  const AndroidLinuxTerminalStatus({
    required this.installed,
    required this.enabled,
    required this.canLaunch,
    this.packageName,
  });

  /// Parses a method-channel map.
  factory AndroidLinuxTerminalStatus.fromMap(Map<Object?, Object?> map) =>
      AndroidLinuxTerminalStatus(
        installed: map['installed'] == true,
        enabled: map['enabled'] == true,
        canLaunch: map['canLaunch'] == true,
        packageName: map['packageName'] as String?,
      );

  /// Status used when the channel is unavailable.
  static const unavailable = AndroidLinuxTerminalStatus(
    installed: false,
    enabled: false,
    canLaunch: false,
  );

  /// Whether the Terminal package is installed.
  final bool installed;

  /// Whether the Terminal package is enabled.
  final bool enabled;

  /// Whether MonkeySSH can launch Terminal right now.
  final bool canLaunch;

  /// Package name reported by the platform channel.
  final String? packageName;
}

/// Platform bridge for launching Android's AVF Linux Terminal app.
class AndroidLinuxTerminalLauncher {
  /// Creates a launcher.
  AndroidLinuxTerminalLauncher({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('xyz.depollsoft.monkeyssh/linux_terminal');

  final MethodChannel _channel;

  /// Whether this launcher can run on the current platform.
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Returns Terminal package/install status.
  Future<AndroidLinuxTerminalStatus> getStatus() async {
    if (!isSupported) {
      return AndroidLinuxTerminalStatus.unavailable;
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getStatus',
      );
      if (raw == null) {
        return AndroidLinuxTerminalStatus.unavailable;
      }
      return AndroidLinuxTerminalStatus.fromMap(raw);
    } on MissingPluginException {
      return AndroidLinuxTerminalStatus.unavailable;
    } on PlatformException {
      return AndroidLinuxTerminalStatus.unavailable;
    }
  }

  /// Opens the Linux Terminal app when possible.
  Future<bool> openTerminal() async {
    if (!isSupported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('openTerminal') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Developer Options so the user can enable Linux Terminal.
  Future<bool> openDeveloperOptions() async {
    if (!isSupported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('openDeveloperOptions') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Terminal port-forwarding settings when available.
  Future<bool> openPortForwardingSettings() async {
    if (!isSupported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('openPortForwardingSettings') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
