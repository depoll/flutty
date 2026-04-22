import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import '../data/repositories/host_repository.dart';
import '../domain/services/background_ssh_service.dart';
import '../domain/services/home_screen_shortcut_service.dart';
import '../domain/services/monetization_service.dart';
import '../domain/services/settings_service.dart';
import '../domain/services/ssh_service.dart';
import 'app_lifecycle_coordinator.dart';
import 'app_metadata.dart';
import 'auth_lifecycle_controller.dart';
import 'router.dart';
import 'theme.dart';

/// The root widget of the Flutty application.
class FluttyApp extends ConsumerWidget {
  /// Creates a new [FluttyApp].
  const FluttyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeNotifierProvider);
    final appName = ref.watch(appDisplayNameProvider);

    return _BackgroundLifecycleBridge(
      child: MaterialApp.router(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: FluttyTheme.light,
        darkTheme: FluttyTheme.dark,
        themeMode: themeMode,
        routerConfig: router,
      ),
    );
  }
}

class _BackgroundLifecycleBridge extends ConsumerStatefulWidget {
  const _BackgroundLifecycleBridge({required this.child});

  final Widget child;

  @override
  ConsumerState<_BackgroundLifecycleBridge> createState() =>
      _BackgroundLifecycleBridgeState();
}

class _BackgroundLifecycleBridgeState
    extends ConsumerState<_BackgroundLifecycleBridge>
    with WidgetsBindingObserver {
  late final AppLifecycleCoordinator _lifecycleCoordinator;
  StreamSubscription<List<Host>>? _homeScreenShortcutHostsSubscription;
  StreamSubscription<Set<int>>? _pinnedHomeScreenShortcutHostsSubscription;
  List<Host> _latestHomeScreenShortcutHosts = const <Host>[];
  Set<int> _latestPinnedHomeScreenShortcutHostIds = const <int>{};
  bool _hasLoadedHomeScreenShortcutHosts = false;
  bool _hasLoadedPinnedHomeScreenShortcutHostIds = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleCoordinator = AppLifecycleCoordinator(
      syncAuthLifecycle: _syncAuthLifecycle,
      syncForegroundBackgroundStatus: _syncForegroundBackgroundStatus,
      syncBackgroundState: () =>
          BackgroundSshService.setForegroundState(isForeground: false),
    );
    if (supportsHomeScreenShortcutActions) {
      _listenForHomeScreenShortcutChanges();
      _runLifecycleSync(
        () => ref.read(homeScreenShortcutServiceProvider).initialize(),
        errorContext:
            'while initializing home-screen shortcuts during app startup',
        defer: true,
      );
    }
    _runLifecycleSync(
      _refreshMonetizationOnStartup,
      errorContext: 'while refreshing subscription state during app startup',
      defer: true,
    );
    _runLifecycleSync(
      _syncForegroundBackgroundStatus,
      errorContext: 'while syncing background SSH status during app startup',
      defer: true,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_homeScreenShortcutHostsSubscription?.cancel());
    unawaited(_pinnedHomeScreenShortcutHostsSubscription?.cancel());
    super.dispose();
  }

  void _listenForHomeScreenShortcutChanges() {
    final hostRepository = ref.read(hostRepositoryProvider);
    _homeScreenShortcutHostsSubscription = hostRepository.watchAll().listen((
      hosts,
    ) {
      _latestHomeScreenShortcutHosts = hosts;
      _hasLoadedHomeScreenShortcutHosts = true;
      _runLifecycleSync(
        _syncHomeScreenShortcuts,
        errorContext:
            'while syncing home-screen shortcuts after the host list changed',
      );
    });

    final preferencesService = ref.read(
      homeScreenShortcutPreferencesServiceProvider,
    );
    _pinnedHomeScreenShortcutHostsSubscription = preferencesService
        .watchPinnedHostIds()
        .listen((hostIds) {
          _latestPinnedHomeScreenShortcutHostIds = hostIds;
          _hasLoadedPinnedHomeScreenShortcutHostIds = true;
          _runLifecycleSync(
            _syncHomeScreenShortcuts,
            errorContext:
                'while syncing home-screen shortcuts after pinned hosts changed',
          );
        });
  }

  Future<void> _syncForegroundBackgroundStatus() async {
    await BackgroundSshService.setForegroundState(isForeground: true);
    await ref.read(activeSessionsProvider.notifier).syncBackgroundStatus();
  }

  Future<void> _refreshMonetizationOnStartup() async {
    await ref.read(monetizationServiceProvider).initialize();
  }

  Future<void> _syncHomeScreenShortcuts() async {
    if (!_hasLoadedHomeScreenShortcutHosts ||
        !_hasLoadedPinnedHomeScreenShortcutHostIds) {
      return;
    }

    await ref
        .read(homeScreenShortcutServiceProvider)
        .updateShortcuts(
          hosts: _latestHomeScreenShortcutHosts,
          pinnedHostIds: _latestPinnedHomeScreenShortcutHostIds,
        );
  }

  Future<void> _syncAuthLifecycle(AppLifecycleState state) => ref
      .read(authLifecycleControllerProvider)
      .handleLifecycleStateChanged(state);

  void _runLifecycleSync(
    Future<void> Function() operation, {
    required String errorContext,
    bool defer = false,
  }) {
    final future = defer ? Future<void>.microtask(operation) : operation();
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'app',
            context: ErrorDescription(errorContext),
          ),
        );
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    if (isForeground) {
      _runLifecycleSync(
        () => _lifecycleCoordinator.handleStateChanged(state),
        errorContext:
            'while syncing background SSH status and auth lock state after returning to the foreground',
      );
      return;
    }
    _runLifecycleSync(
      () => _lifecycleCoordinator.handleStateChanged(state),
      errorContext:
          'while syncing background SSH status and auth lock state after moving to the background',
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
