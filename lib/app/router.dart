import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../presentation/screens/theme_editor_screen.dart';
import 'routes.dart';

/// Root navigator key used for global modal prompts.
final appNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'appNavigator');

/// Provider for the app router.
final routerProvider = Provider<GoRouter>((ref) {
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
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/lock',
        name: 'lock',
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(
        path: '/auth-setup',
        name: 'auth-setup',
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
          if (hostId == null) {
            return const Scaffold(body: Center(child: Text('Invalid host ID')));
          }
          return TerminalScreen(hostId: hostId, connectionId: connectionId);
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
        builder: (context, state) => const HostEditScreen(),
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
        builder: (context, state) => const KeyAddScreen(),
      ),
      GoRoute(
        path: '/sftp/:hostId',
        name: Routes.sftp,
        builder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          final connectionId = int.tryParse(
            state.uri.queryParameters['connectionId'] ?? '',
          );
          final initialPath = state.uri.queryParameters['path'];
          final initialWorkingDirectory = state.uri.queryParameters['cwd'];
          if (hostId == null) {
            return const Scaffold(body: Center(child: Text('Invalid host ID')));
          }
          return SftpScreen(
            hostId: hostId,
            connectionId: connectionId,
            initialPath: initialPath,
            initialWorkingDirectory: initialWorkingDirectory,
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
        name: 'snippet-add',
        builder: (context, state) => const SnippetEditScreen(),
      ),
      GoRoute(
        path: '/snippets/edit/:snippetId',
        name: 'snippet-edit',
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
        path: '/theme-editor',
        name: Routes.themeEditorNew,
        builder: (context, state) => const ThemeEditorScreen(),
      ),
      GoRoute(
        path: '/theme-editor/:themeId',
        name: Routes.themeEditor,
        builder: (context, state) {
          final themeId = state.pathParameters['themeId'];
          return ThemeEditorScreen(themeId: themeId);
        },
      ),
    ],
  );
});

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
