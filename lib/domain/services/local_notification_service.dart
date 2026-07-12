import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tmux_state.dart';

/// Local notification channel used for tmux activity alerts.
const tmuxAlertNotificationChannelId = 'tmux-alerts';

/// Local notification channel used for terminal desktop notifications emitted
/// by the remote shell (OSC 9 / 777 / 99).
const terminalNotificationChannelId = 'terminal-notifications';

/// Local notification channel used for ACP agent completion/permission
/// alerts shown only while the app is backgrounded.
const acpNotificationChannelId = 'acp-notifications';
const _androidNotificationIcon = 'ic_notification_monkey';
const _disableNotificationsForStoreScreenshots = bool.fromEnvironment(
  'STORE_SCREENSHOT_DISABLE_NOTIFICATIONS',
);

/// Payload attached to a tmux alert notification.
@immutable
class TmuxAlertNotificationPayload {
  /// Creates a new [TmuxAlertNotificationPayload].
  const TmuxAlertNotificationPayload({
    required this.hostId,
    required this.connectionId,
    required this.tmuxSessionName,
    required this.windowIndex,
    this.windowId,
  });

  static const _type = 'tmux-alert';
  static const _version = 1;

  /// Host that owns the alerted connection.
  final int hostId;

  /// Existing SSH connection that produced the alert.
  final int connectionId;

  /// tmux session containing the alerted window.
  final String tmuxSessionName;

  /// tmux window index that needs attention.
  final int windowIndex;

  /// Stable tmux window ID that needs attention, when available.
  final String? windowId;

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'hostId': hostId,
    'connectionId': connectionId,
    'tmuxSessionName': tmuxSessionName,
    'windowIndex': windowIndex,
    'windowId': ?windowId,
  });

  /// Decodes a notification payload, returning `null` for other payload types.
  static TmuxAlertNotificationPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?> ||
          decoded['type'] != _type ||
          decoded['version'] != _version) {
        return null;
      }
      final hostId = decoded['hostId'];
      final connectionId = decoded['connectionId'];
      final tmuxSessionName = decoded['tmuxSessionName'];
      final windowIndex = decoded['windowIndex'];
      final windowId = decoded['windowId'];
      final stableWindowId = windowId is String && isValidTmuxWindowId(windowId)
          ? windowId
          : null;
      if (hostId is! int ||
          connectionId is! int ||
          tmuxSessionName is! String ||
          tmuxSessionName.trim().isEmpty ||
          windowIndex is! int ||
          (windowId != null && stableWindowId == null)) {
        return null;
      }
      return TmuxAlertNotificationPayload(
        hostId: hostId,
        connectionId: connectionId,
        tmuxSessionName: tmuxSessionName,
        windowIndex: windowIndex,
        windowId: stableWindowId,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxAlertNotificationPayload &&
          hostId == other.hostId &&
          connectionId == other.connectionId &&
          tmuxSessionName == other.tmuxSessionName &&
          windowIndex == other.windowIndex &&
          windowId == other.windowId;

  @override
  int get hashCode =>
      Object.hash(hostId, connectionId, tmuxSessionName, windowIndex, windowId);
}

/// Builds the terminal route location for a tmux alert notification tap.
String buildTmuxAlertTerminalLocation(TmuxAlertNotificationPayload payload) =>
    Uri(
      path: '/terminal/${payload.hostId}',
      queryParameters: <String, String>{
        'connectionId': '${payload.connectionId}',
        'tmuxSession': payload.tmuxSessionName,
        'tmuxWindow': '${payload.windowIndex}',
        if (payload.windowId != null) 'tmuxWindowId': payload.windowId!,
      },
    ).toString();

/// Payload attached to a terminal desktop notification (OSC 9 / 777 / 99).
@immutable
class TerminalNotificationPayload {
  /// Creates a new [TerminalNotificationPayload].
  const TerminalNotificationPayload({
    required this.hostId,
    required this.connectionId,
  });

  static const _type = 'terminal-notification';
  static const _version = 1;

  /// Host that owns the connection that emitted the notification.
  final int hostId;

  /// Existing SSH connection that emitted the notification.
  final int connectionId;

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'hostId': hostId,
    'connectionId': connectionId,
  });

  /// Decodes a notification payload, returning `null` for other payload types.
  static TerminalNotificationPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?> ||
          decoded['type'] != _type ||
          decoded['version'] != _version) {
        return null;
      }
      final hostId = decoded['hostId'];
      final connectionId = decoded['connectionId'];
      if (hostId is! int || connectionId is! int) {
        return null;
      }
      return TerminalNotificationPayload(
        hostId: hostId,
        connectionId: connectionId,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalNotificationPayload &&
          hostId == other.hostId &&
          connectionId == other.connectionId;

  @override
  int get hashCode => Object.hash(hostId, connectionId);
}

/// Builds the terminal route location for a terminal notification tap.
String buildTerminalNotificationLocation(TerminalNotificationPayload payload) =>
    Uri(
      path: '/terminal/${payload.hostId}',
      queryParameters: <String, String>{
        'connectionId': '${payload.connectionId}',
      },
    ).toString();

/// Coarse category of an ACP notification. Never carries prompt, tool, path,
/// or content details.
enum AcpNotificationKind {
  /// A prompt turn finished while the app was backgrounded.
  completion,

  /// The agent requested a permission decision while the app was
  /// backgrounded.
  permission,
}

/// Payload attached to an ACP agent notification.
///
/// Deliberately holds only stable identifiers: no prompt text, tool output,
/// paths, commands, or session titles are ever included.
@immutable
class AcpNotificationPayload {
  /// Creates a new [AcpNotificationPayload].
  const AcpNotificationPayload({
    required this.kind,
    required this.hostId,
    required this.providerId,
    required this.bridgeId,
    required this.acpSessionId,
  });

  static const _type = 'acp-notification';
  static const _version = 1;

  /// Notification category.
  final AcpNotificationKind kind;

  /// Host that owns the ACP session.
  final int hostId;

  /// ACP provider identifier (built-in or custom), never a raw command.
  final String providerId;

  /// Remote MonkeyMux ACP bridge identifier.
  final String bridgeId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'kind': kind.name,
    'hostId': hostId,
    'providerId': providerId,
    'bridgeId': bridgeId,
    'acpSessionId': acpSessionId,
  });

  /// Decodes a notification payload, returning `null` for other payload types.
  static AcpNotificationPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?> ||
          decoded['type'] != _type ||
          decoded['version'] != _version) {
        return null;
      }
      final kindName = decoded['kind'];
      final hostId = decoded['hostId'];
      final providerId = decoded['providerId'];
      final bridgeId = decoded['bridgeId'];
      final acpSessionId = decoded['acpSessionId'];
      AcpNotificationKind? kind;
      for (final value in AcpNotificationKind.values) {
        if (value.name == kindName) {
          kind = value;
          break;
        }
      }
      if (kind == null ||
          hostId is! int ||
          providerId is! String ||
          providerId.isEmpty ||
          bridgeId is! String ||
          bridgeId.isEmpty ||
          acpSessionId is! String ||
          acpSessionId.isEmpty) {
        return null;
      }
      return AcpNotificationPayload(
        kind: kind,
        hostId: hostId,
        providerId: providerId,
        bridgeId: bridgeId,
        acpSessionId: acpSessionId,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpNotificationPayload &&
          kind == other.kind &&
          hostId == other.hostId &&
          providerId == other.providerId &&
          bridgeId == other.bridgeId &&
          acpSessionId == other.acpSessionId;

  @override
  int get hashCode =>
      Object.hash(kind, hostId, providerId, bridgeId, acpSessionId);
}

/// Builds the safe navigation location for an ACP notification tap.
///
/// This intentionally lands on the general Agents overview rather than a
/// session-specific deep link: routing into a specific chat session is
/// outside this change's scope.
String buildAcpNotificationLocation(AcpNotificationPayload payload) =>
    Uri(path: '/home', queryParameters: const {'tab': 'agents'}).toString();

/// Service for showing local notifications inside the app.
class LocalNotificationService {
  /// Creates a new [LocalNotificationService].
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _tmuxAlertNotificationChannel = AndroidNotificationChannel(
    tmuxAlertNotificationChannelId,
    'tmux alerts',
    description: 'Window activity alerts for tmux sessions.',
    importance: Importance.high,
  );

  static const _terminalNotificationChannel = AndroidNotificationChannel(
    terminalNotificationChannelId,
    'Terminal notifications',
    description: 'Notifications sent by the remote shell.',
    importance: Importance.high,
  );

  static const _acpNotificationChannel = AndroidNotificationChannel(
    acpNotificationChannelId,
    'Agent notifications',
    description:
        'Agent completion and permission alerts shown only while the app '
        'is in the background.',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<TmuxAlertNotificationPayload> _tmuxAlertTapController =
      StreamController<TmuxAlertNotificationPayload>.broadcast();
  final StreamController<TerminalNotificationPayload>
  _terminalNotificationTapController =
      StreamController<TerminalNotificationPayload>.broadcast();
  final StreamController<AcpNotificationPayload> _acpNotificationTapController =
      StreamController<AcpNotificationPayload>.broadcast();
  Future<bool>? _initializeFuture;
  TmuxAlertNotificationPayload? _launchTmuxAlert;
  TerminalNotificationPayload? _launchTerminalNotification;
  AcpNotificationPayload? _launchAcpNotification;
  bool _didConsumeLaunchTmuxAlert = false;
  bool _didConsumeLaunchTerminalNotification = false;
  bool _didConsumeLaunchAcpNotification = false;

  /// Emits whenever the user taps a tmux alert notification.
  Stream<TmuxAlertNotificationPayload> get tmuxAlertTaps =>
      _tmuxAlertTapController.stream;

  /// Emits whenever the user taps a terminal desktop notification.
  Stream<TerminalNotificationPayload> get terminalNotificationTaps =>
      _terminalNotificationTapController.stream;

  /// Emits whenever the user taps an ACP agent notification.
  Stream<AcpNotificationPayload> get acpNotificationTaps =>
      _acpNotificationTapController.stream;

  /// Ensures the underlying notification plugin is initialized.
  Future<bool> initialize() => _initializeFuture ??= _initializeInternal();

  /// Releases notification routing resources.
  void dispose() {
    unawaited(_tmuxAlertTapController.close());
    unawaited(_terminalNotificationTapController.close());
    unawaited(_acpNotificationTapController.close());
  }

  /// Returns the tmux alert that launched the app, if one has not been consumed.
  Future<TmuxAlertNotificationPayload?> consumeLaunchTmuxAlert() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchTmuxAlert) {
      return null;
    }
    _didConsumeLaunchTmuxAlert = true;
    return _launchTmuxAlert;
  }

  /// Returns the terminal notification that launched the app, if one has not
  /// been consumed.
  Future<TerminalNotificationPayload?>
  consumeLaunchTerminalNotification() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchTerminalNotification) {
      return null;
    }
    _didConsumeLaunchTerminalNotification = true;
    return _launchTerminalNotification;
  }

  /// Returns the ACP notification that launched the app, if one has not been
  /// consumed.
  Future<AcpNotificationPayload?> consumeLaunchAcpNotification() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchAcpNotification) {
      return null;
    }
    _didConsumeLaunchAcpNotification = true;
    return _launchAcpNotification;
  }

  /// Shows or refreshes a tmux alert notification.
  Future<void> showTmuxAlert({
    required int notificationId,
    required String title,
    required String body,
    required TmuxAlertNotificationPayload payload,
  }) async {
    final didInitialize = await initialize();
    if (!didInitialize) return;
    final hasPermission = await _requestNotificationPermission();
    if (!hasPermission) return;

    const androidDetails = AndroidNotificationDetails(
      tmuxAlertNotificationChannelId,
      'tmux alerts',
      channelDescription: 'Window activity alerts for tmux sessions.',
      importance: Importance.high,
      priority: Priority.high,
      icon: _androidNotificationIcon,
      onlyAlertOnce: true,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    try {
      await _plugin.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
        ),
        payload: payload.encode(),
      );
    } on MissingPluginException {
      // Widget and unit tests don't register platform notification plugins.
    }
  }

  /// Clears a previously shown tmux alert notification.
  Future<void> clearTmuxAlert(int notificationId) async {
    final didInitialize = await initialize();
    if (!didInitialize) return;

    try {
      await _plugin.cancel(id: notificationId);
    } on MissingPluginException {
      // Widget and unit tests don't register platform notification plugins.
    }
  }

  /// Shows a terminal desktop notification emitted by the remote shell.
  Future<void> showTerminalNotification({
    required int notificationId,
    required String title,
    required String body,
    required TerminalNotificationPayload payload,
  }) async {
    final didInitialize = await initialize();
    if (!didInitialize) return;
    final hasPermission = await _requestNotificationPermission();
    if (!hasPermission) return;

    const androidDetails = AndroidNotificationDetails(
      terminalNotificationChannelId,
      'Terminal notifications',
      channelDescription: 'Notifications sent by the remote shell.',
      importance: Importance.high,
      priority: Priority.high,
      icon: _androidNotificationIcon,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    try {
      await _plugin.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
        ),
        payload: payload.encode(),
      );
    } on MissingPluginException {
      // Widget and unit tests don't register platform notification plugins.
    }
  }

  /// Shows an ACP agent notification (completion or permission-needed).
  ///
  /// Callers must only invoke this while the app is backgrounded and a
  /// network/SSH path to the host still exists: there is no push path when
  /// disconnected, so no notification can ever be delivered in that case.
  /// [title] and [body] must never include prompt text, tool arguments or
  /// output, paths, or commands.
  Future<void> showAcpNotification({
    required int notificationId,
    required String title,
    required String body,
    required AcpNotificationPayload payload,
  }) async {
    final didInitialize = await initialize();
    if (!didInitialize) return;
    final hasPermission = await _requestNotificationPermission();
    if (!hasPermission) return;

    const androidDetails = AndroidNotificationDetails(
      acpNotificationChannelId,
      'Agent notifications',
      channelDescription:
          'Agent completion and permission alerts shown only while the app '
          'is in the background.',
      importance: Importance.high,
      priority: Priority.high,
      icon: _androidNotificationIcon,
      onlyAlertOnce: true,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    try {
      await _plugin.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
        ),
        payload: payload.encode(),
      );
    } on MissingPluginException {
      // Widget and unit tests don't register platform notification plugins.
    }
  }

  /// Clears a previously shown ACP notification.
  Future<void> clearAcpNotification(int notificationId) async {
    final didInitialize = await initialize();
    if (!didInitialize) return;

    try {
      await _plugin.cancel(id: notificationId);
    } on MissingPluginException {
      // Widget and unit tests don't register platform notification plugins.
    }
  }

  Future<bool> _initializeInternal() async {
    if (kIsWeb) return false;
    if (_disableNotificationsForStoreScreenshots) return false;

    try {
      const initializationSettings = InitializationSettings(
        android: AndroidInitializationSettings(_androidNotificationIcon),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final launchPayload = (launchDetails?.didNotificationLaunchApp ?? false)
          ? launchDetails?.notificationResponse?.payload
          : null;
      _launchTmuxAlert = TmuxAlertNotificationPayload.decode(launchPayload);
      _launchTerminalNotification = TerminalNotificationPayload.decode(
        launchPayload,
      );
      _launchAcpNotification = AcpNotificationPayload.decode(launchPayload);

      await _plugin.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: _handleNotificationResponse,
      );

      final androidImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImplementation?.createNotificationChannel(
        _tmuxAlertNotificationChannel,
      );
      await androidImplementation?.createNotificationChannel(
        _terminalNotificationChannel,
      );
      await androidImplementation?.createNotificationChannel(
        _acpNotificationChannel,
      );

      return true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> _requestNotificationPermission() async {
    try {
      final androidImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImplementation != null) {
        return await androidImplementation.requestNotificationsPermission() ??
            false;
      }

      final iOSImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iOSImplementation != null) {
        return await iOSImplementation.requestPermissions(alert: true) ?? false;
      }

      final macOSImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (macOSImplementation != null) {
        return await macOSImplementation.requestPermissions(alert: true) ??
            false;
      }

      return true;
    } on MissingPluginException {
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final tmuxPayload = TmuxAlertNotificationPayload.decode(response.payload);
    if (tmuxPayload != null) {
      _tmuxAlertTapController.add(tmuxPayload);
      return;
    }
    final terminalPayload = TerminalNotificationPayload.decode(
      response.payload,
    );
    if (terminalPayload != null) {
      _terminalNotificationTapController.add(terminalPayload);
      return;
    }
    final acpPayload = AcpNotificationPayload.decode(response.payload);
    if (acpPayload != null) {
      _acpNotificationTapController.add(acpPayload);
    }
  }
}

/// Provides access to local notifications.
final Provider<LocalNotificationService> localNotificationServiceProvider =
    Provider<LocalNotificationService>((ref) {
      final service = LocalNotificationService();
      ref.onDispose(service.dispose);
      return service;
    });
