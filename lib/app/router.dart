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

/// Provider for the app router.
final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final isLocked = authState == AuthState.locked;
      final isNotConfigured = authState == AuthState.notConfigured;
      final isOnLockScreen = state.matchedLocation == '/lock';
      final isOnSetupScreen = state.matchedLocation == '/auth-setup';

      if (isLocked && !isOnLockScreen) {
        return '/lock';
      }

      if (isNotConfigured && !isOnSetupScreen && !isOnLockScreen) {
        // Allow skipping setup, so don't force redirect
        return null;
      }

      if (!isLocked &&
          !isNotConfigured &&
          (isOnLockScreen || isOnSetupScreen)) {
        return '/';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
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
        name: 'terminal',
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
        name: 'hosts',
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
        name: 'keys',
        builder: (context, state) => const KeysScreen(),
      ),
      GoRoute(
        path: '/keys/add',
        name: 'key-add',
        builder: (context, state) => const KeyAddScreen(),
      ),
      GoRoute(
        path: '/sftp/:hostId',
        name: 'sftp',
        builder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          if (hostId == null) {
            return const Scaffold(body: Center(child: Text('Invalid host ID')));
          }
          return SftpScreen(hostId: hostId);
        },
      ),
      GoRoute(
        path: '/snippets',
        name: 'snippets',
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
        name: 'port-forwards',
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
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/theme-editor',
        name: 'theme-editor-new',
        builder: (context, state) => const ThemeEditorScreen(),
      ),
      GoRoute(
        path: '/theme-editor/:themeId',
        name: 'theme-editor',
        builder: (context, state) {
          final themeId = state.pathParameters['themeId'];
          return ThemeEditorScreen(themeId: themeId);
        },
      ),
    ],
  );
});

/// Route names for type-safe navigation.
abstract final class Routes {
  /// Home screen route.
  static const home = 'home';

  /// Hosts list route.
  static const hosts = 'hosts';

  /// Host detail/edit route.
  static const hostDetail = 'host-detail';

  /// Terminal session route.
  static const terminal = 'terminal';

  /// SFTP browser route.
  static const sftp = 'sftp';

  /// Keys management route.
  static const keys = 'keys';

  /// Snippets route.
  static const snippets = 'snippets';

  /// Port forwards route.
  static const portForwards = 'port-forwards';

  /// Settings route.
  static const settings = 'settings';

  /// Theme editor route.
  static const themeEditor = 'theme-editor';

  /// Theme editor route for new theme.
  static const themeEditorNew = 'theme-editor-new';
}
