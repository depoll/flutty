import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models/monetization.dart';
import '../domain/services/auth_service.dart';
import '../presentation/screens/auth_setup_screen.dart';
import '../presentation/screens/home_screen.dart';
import '../presentation/screens/host_edit_screen.dart';
import '../presentation/screens/hosts_screen.dart';
import '../presentation/screens/key_add_screen.dart';
import '../presentation/screens/keys_screen.dart';
import '../presentation/screens/lock_screen.dart';
import '../presentation/screens/port_forward_edit_screen.dart';
import '../presentation/screens/port_forwards_screen.dart';
import '../presentation/screens/settings_screen.dart';
import '../presentation/screens/sftp_screen.dart';
import '../presentation/screens/snippet_edit_screen.dart';
import '../presentation/screens/snippets_screen.dart';
import '../presentation/screens/terminal_screen.dart';
import '../presentation/screens/upgrade_screen.dart';
import 'routes.dart';

/// Root navigator key used for global modal prompts.
final appNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'appNavigator');

/// Provider for the app router.
final routerProvider = Provider<GoRouter>((ref) {
  // Keep this watch: rebuilding the router on auth transitions intentionally
  // clears protected navigation history when the app locks.
  // TODO(router): only switch to a persistent GoRouter/refreshListenable after
  // tests prove locked routes cannot be revealed via back navigation and
  // notification deep-link navigation remains compatible.
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    navigatorKey: appNavigatorKey,
    initialLocation: '/',
    redirect: (context, state) => redirectForAuthState(
      authState: authState,
      matchedLocation: state.matchedLocation,
    ),
    routes: [
      GoRoute(
        path: '/',
        name: Routes.home,
        builder: (context, state) => HomeScreen(
          initialTab: _homeScreenTabFromRoute(state.uri.queryParameters['tab']),
        ),
      ),
      GoRoute(
        path: '/lock',
        name: 'lock',
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(
        path: '/auth-setup',
        name: Routes.authSetup,
        builder: (context, state) => const AuthSetupScreen(),
      ),
      GoRoute(
        path: '/terminal/:hostId',
        name: Routes.terminal,
        builder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          final connectionId = int.tryParse(
            state.uri.queryParameters['connectionId'] ?? '',
          );
          final initialTmuxSessionName =
              state.uri.queryParameters['tmuxSession'];
          final initialTmuxWindowIndex = int.tryParse(
            state.uri.queryParameters['tmuxWindow'] ?? '',
          );
          final initialTmuxWindowId = state.uri.queryParameters['tmuxWindowId'];
          if (hostId == null) {
            return const Scaffold(body: Center(child: Text('Invalid host ID')));
          }
          return TerminalScreen(
            key: ValueKey<Object>(
              Object.hash(
                hostId,
                connectionId,
                initialTmuxSessionName,
                initialTmuxWindowIndex,
                initialTmuxWindowId,
                state.uri.queryParameters['notificationTap'],
              ),
            ),
            hostId: hostId,
            connectionId: connectionId,
            initialTmuxSessionName: initialTmuxSessionName,
            initialTmuxWindowIndex: initialTmuxWindowIndex,
            initialTmuxWindowId: initialTmuxWindowId,
            initialTmuxWindowRequiresVisibleSession:
                state.uri.queryParameters['notificationTap'] != null,
            initiallyExpandTmuxWindows:
                state.uri.queryParameters['expandTmux'] == '1',
          );
        },
      ),
      GoRoute(
        path: '/hosts',
        name: Routes.hosts,
        builder: (context, state) => const HostsScreen(),
      ),
      GoRoute(
        path: '/hosts/add',
        name: 'host-add',
        builder: (context, state) =>
            HostEditScreen(initialSshUrl: state.uri.queryParameters['sshUrl']),
      ),
      GoRoute(
        path: '/hosts/edit/:hostId',
        name: 'host-edit',
        builder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          return HostEditScreen(hostId: hostId);
        },
      ),
      GoRoute(
        path: '/keys',
        name: Routes.keys,
        builder: (context, state) => const KeysScreen(),
      ),
      GoRoute(
        path: '/keys/add',
        name: 'key-add',
        builder: (context, state) => KeyAddScreen(
          initialTabIndex: state.uri.queryParameters['tab'] == 'import' ? 1 : 0,
        ),
      ),
      GoRoute(
        path: '/sftp/:hostId',
        name: Routes.sftp,
        pageBuilder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          final connectionId = int.tryParse(
            state.uri.queryParameters['connectionId'] ?? '',
          );
          final initialPath = state.uri.queryParameters['path'];
          final initialWorkingDirectory = state.uri.queryParameters['cwd'];
          final connectionStartDirectory =
              state.uri.queryParameters['connectionCwd'];
          final tmuxPaneDirectory = state.uri.queryParameters['tmuxCwd'];
          if (hostId == null) {
            return _buildSlideUpPage<String>(
              key: state.pageKey,
              child: const Scaffold(
                body: Center(child: Text('Invalid host ID')),
              ),
            );
          }
          return _buildSlideUpPage<String>(
            key: state.pageKey,
            child: SftpScreen(
              hostId: hostId,
              connectionId: connectionId,
              initialPath: initialPath,
              initialWorkingDirectory: initialWorkingDirectory,
              connectionStartDirectory: connectionStartDirectory,
              tmuxPaneDirectory: tmuxPaneDirectory,
              showCloseButton: true,
            ),
          );
        },
      ),
      GoRoute(
        path: '/snippets',
        name: Routes.snippets,
        builder: (context, state) => const SnippetsScreen(),
      ),
      GoRoute(
        path: '/snippets/add',
        name: Routes.snippetAdd,
        builder: (context, state) {
          final extra = state.extra;
          final prefill = extra is SnippetEditPrefill
              ? extra
              : const SnippetEditPrefill();
          return SnippetEditScreen(prefill: prefill);
        },
      ),
      GoRoute(
        path: '/snippets/edit/:snippetId',
        name: Routes.snippetEdit,
        builder: (context, state) {
          final snippetId = int.tryParse(
            state.pathParameters['snippetId'] ?? '',
          );
          return SnippetEditScreen(snippetId: snippetId);
        },
      ),
      GoRoute(
        path: '/port-forwards',
        name: Routes.portForwards,
        builder: (context, state) => const PortForwardsScreen(),
      ),
      GoRoute(
        path: '/port-forwards/add',
        name: 'port-forward-add',
        builder: (context, state) => const PortForwardEditScreen(),
      ),
      GoRoute(
        path: '/port-forwards/edit/:id',
        name: 'port-forward-edit',
        builder: (context, state) {
          final portForwardId = int.tryParse(state.pathParameters['id'] ?? '');
          return PortForwardEditScreen(portForwardId: portForwardId);
        },
      ),
      GoRoute(
        path: '/settings',
        name: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/upgrade',
        name: Routes.upgrade,
        builder: (context, state) {
          final featureName = state.uri.queryParameters['feature'];
          final feature = MonetizationFeature.values.firstWhereOrNull(
            (value) => value.name == featureName,
          );
          return UpgradeScreen(
            feature: feature,
            blockedAction: state.uri.queryParameters['action'],
            blockedOutcome: state.uri.queryParameters['outcome'],
          );
        },
      ),
    ],
  );
});

HomeScreenTab _homeScreenTabFromRoute(String? tab) => switch (tab) {
  'connections' => HomeScreenTab.connections,
  _ => HomeScreenTab.hosts,
};

CustomTransitionPage<T> _buildSlideUpPage<T>({
  required LocalKey key,
  required Widget child,
}) => CustomTransitionPage<T>(
  key: key,
  fullscreenDialog: true,
  transitionDuration: const Duration(milliseconds: 280),
  reverseTransitionDuration: const Duration(milliseconds: 220),
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        child: child,
      ),
  child: child,
);

/// Computes the route redirect for the given authentication state.
String? redirectForAuthState({
  required AuthState authState,
  required String matchedLocation,
}) {
  final isBlocked =
      authState == AuthState.unknown || authState == AuthState.locked;
  final isNotConfigured = authState == AuthState.notConfigured;
  final isOnLockScreen = matchedLocation == '/lock';
  final isOnSetupScreen = matchedLocation == '/auth-setup';

  if (isBlocked) {
    return isOnLockScreen ? null : '/lock';
  }

  if (isNotConfigured && isOnLockScreen) {
    return '/';
  }

  if (!isNotConfigured && (isOnLockScreen || isOnSetupScreen)) {
    return '/';
  }

  return null;
}
