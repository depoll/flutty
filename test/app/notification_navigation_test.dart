import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/app/notification_navigation.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';

void main() {
  testWidgets('tmux alert opens terminal above the connections screen', (
    tester,
  ) async {
    final terminalLocations = <String>[];
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Text('home:${state.uri.queryParameters['tab'] ?? 'hosts'}'),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/terminal/:hostId',
          builder: (context, state) {
            terminalLocations.add(state.uri.toString());
            return Scaffold(
              body: Text('terminal:${state.pathParameters['hostId']}'),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('settings'), findsOneWidget);

    openTmuxAlertNotificationStack(
      router: router,
      payload: const TmuxAlertNotificationPayload(
        hostId: 12,
        connectionId: 34,
        tmuxSessionName: 'work',
        windowIndex: 5,
        windowId: '@9',
      ),
      notificationTapId: 'tap-1',
    );
    await tester.pumpAndSettle();

    expect(find.text('terminal:12'), findsOneWidget);
    expect(router.canPop(), isTrue);
    expect(
      terminalLocations.single,
      '/terminal/12?connectionId=34&tmuxSession=work&tmuxWindow=5&tmuxWindowId=%409&notificationTap=tap-1',
    );

    router.pop();
    await tester.pumpAndSettle();

    expect(find.text('home:connections'), findsOneWidget);
    expect(find.text('settings'), findsNothing);
  });
}
