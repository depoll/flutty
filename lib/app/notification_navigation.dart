import 'dart:async';

import 'package:go_router/go_router.dart';

import '../domain/services/local_notification_service.dart';

const _homeTabQueryKey = 'tab';
const _connectionsTabQueryValue = 'connections';

/// Builds the home route that should sit underneath a tmux alert terminal.
String buildTmuxAlertHomeLocation() => Uri(
  path: '/',
  queryParameters: const <String, String>{
    _homeTabQueryKey: _connectionsTabQueryValue,
  },
).toString();

/// Builds the terminal route for a tmux alert notification navigation.
String buildTmuxAlertNotificationTerminalLocation(
  TmuxAlertNotificationPayload payload, {
  required String notificationTapId,
}) {
  final targetUri = Uri.parse(buildTmuxAlertTerminalLocation(payload));
  final queryParameters = Map<String, String>.from(targetUri.queryParameters)
    ..['notificationTap'] = notificationTapId;
  return targetUri.replace(queryParameters: queryParameters).toString();
}

/// Opens a tmux alert notification with the same stack as manual navigation.
void openTmuxAlertNotificationStack({
  required GoRouter router,
  required TmuxAlertNotificationPayload payload,
  required String notificationTapId,
}) {
  router.go(buildTmuxAlertHomeLocation());
  unawaited(
    router.push<void>(
      buildTmuxAlertNotificationTerminalLocation(
        payload,
        notificationTapId: notificationTapId,
      ),
    ),
  );
}
