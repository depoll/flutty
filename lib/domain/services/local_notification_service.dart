import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Local notification channel used for tmux activity alerts.
const tmuxAlertNotificationChannelId = 'tmux-alerts';
const _androidNotificationIcon = 'ic_notification_monkey';

/// Payload attached to a tmux alert notification.
@immutable
class TmuxAlertNotificationPayload {
  /// Creates a new [TmuxAlertNotificationPayload].
  const TmuxAlertNotificationPayload({
    required this.hostId,
    required this.connectionId,
    required this.tmuxSessionName,
    required this.windowIndex,
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

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'hostId': hostId,
    'connectionId': connectionId,
    'tmuxSessionName': tmuxSessionName,
    'windowIndex': windowIndex,
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
      if (hostId is! int ||
          connectionId is! int ||
          tmuxSessionName is! String ||
          tmuxSessionName.trim().isEmpty ||
          windowIndex is! int) {
        return null;
      }
      return TmuxAlertNotificationPayload(
        hostId: hostId,
        connectionId: connectionId,
        tmuxSessionName: tmuxSessionName,
        windowIndex: windowIndex,
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
          windowIndex == other.windowIndex;

  @override
  int get hashCode =>
      Object.hash(hostId, connectionId, tmuxSessionName, windowIndex);
}

/// Builds the terminal route location for a tmux alert notification tap.
String buildTmuxAlertTerminalLocation(TmuxAlertNotificationPayload payload) =>
    Uri(
      path: '/terminal/${payload.hostId}',
      queryParameters: <String, String>{
        'connectionId': '${payload.connectionId}',
        'tmuxSession': payload.tmuxSessionName,
        'tmuxWindow': '${payload.windowIndex}',
      },
    ).toString();

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

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<TmuxAlertNotificationPayload> _tmuxAlertTapController =
      StreamController<TmuxAlertNotificationPayload>.broadcast();
  Future<bool>? _initializeFuture;
  TmuxAlertNotificationPayload? _launchTmuxAlert;
  bool _didConsumeLaunchTmuxAlert = false;

  /// Emits whenever the user taps a tmux alert notification.
  Stream<TmuxAlertNotificationPayload> get tmuxAlertTaps =>
      _tmuxAlertTapController.stream;

  /// Ensures the underlying notification plugin is initialized.
  Future<bool> initialize() => _initializeFuture ??= _initializeInternal();

  /// Returns the tmux alert that launched the app, if one has not been consumed.
  Future<TmuxAlertNotificationPayload?> consumeLaunchTmuxAlert() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchTmuxAlert) {
      return null;
    }
    _didConsumeLaunchTmuxAlert = true;
    return _launchTmuxAlert;
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

  Future<bool> _initializeInternal() async {
    if (kIsWeb) return false;

    try {
      const initializationSettings = InitializationSettings(
        android: AndroidInitializationSettings(_androidNotificationIcon),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
      );
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      _launchTmuxAlert = (launchDetails?.didNotificationLaunchApp ?? false)
          ? TmuxAlertNotificationPayload.decode(
              launchDetails?.notificationResponse?.payload,
            )
          : null;

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
      await androidImplementation?.requestNotificationsPermission();

      return true;
    } on MissingPluginException {
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = TmuxAlertNotificationPayload.decode(response.payload);
    if (payload == null) {
      return;
    }
    _tmuxAlertTapController.add(payload);
  }
}

/// Provides access to local notifications.
final Provider<LocalNotificationService> localNotificationServiceProvider =
    Provider<LocalNotificationService>((ref) => LocalNotificationService());
