import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import '../data/repositories/host_repository.dart';
import '../domain/models/terminal_theme.dart';
import '../domain/models/terminal_themes.dart';
import '../domain/services/auth_service.dart';
import '../domain/services/background_ssh_service.dart';
import '../domain/services/home_screen_shortcut_service.dart';
import '../domain/services/local_notification_service.dart';
import '../domain/services/monetization_service.dart';
import '../domain/services/settings_service.dart';
import '../domain/services/ssh_service.dart';
import '../domain/services/terminal_theme_service.dart';
import 'app_lifecycle_coordinator.dart';
import 'app_metadata.dart';
import 'auth_lifecycle_controller.dart';
import 'notification_navigation.dart';
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
    final terminalThemesApplyToApp = ref.watch(
      terminalThemesApplyToAppNotifierProvider,
    );
    late final ThemeData lightTheme;
    late final ThemeData darkTheme;

    if (terminalThemesApplyToApp) {
      final terminalThemeSettings = ref.watch(terminalThemeSettingsProvider);
      final terminalAppThemeOverride = ref.watch(
        terminalAppThemeOverrideProvider,
      );
      final terminalThemes =
          ref.watch(allTerminalThemesProvider).asData?.value ??
          TerminalThemes.all;
      lightTheme = buildTerminalAppTheme(
        brightness: Brightness.light,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: terminalThemes,
        terminalAppThemeOverride: terminalAppThemeOverride,
      );
      darkTheme = buildTerminalAppTheme(
        brightness: Brightness.dark,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: terminalThemes,
        terminalAppThemeOverride: terminalAppThemeOverride,
      );
    } else {
      lightTheme = FluttyTheme.light;
      darkTheme = FluttyTheme.dark;
    }
    final appName = ref.watch(appDisplayNameProvider);

    return _BackgroundLifecycleBridge(
      child: MaterialApp.router(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        routerConfig: router,
      ),
    );
  }
}

/// Builds an app [ThemeData] from global settings plus active terminal overrides.
@visibleForTesting
ThemeData buildTerminalAppTheme({
  required Brightness brightness,
  required TerminalThemeSettings terminalThemeSettings,
  required List<TerminalThemeData> terminalThemes,
  TerminalAppThemeOverride? terminalAppThemeOverride,
}) {
  final themeId = switch (brightness) {
    Brightness.light =>
      terminalAppThemeOverride?.lightThemeId ??
          terminalThemeSettings.lightThemeId,
    Brightness.dark =>
      terminalAppThemeOverride?.darkThemeId ??
          terminalThemeSettings.darkThemeId,
  };
  final terminalTheme = TerminalThemes.resolveById(
    brightness: brightness,
    themeId: themeId,
    additionalThemes: terminalThemes,
  );
  return FluttyTheme.fromTerminalTheme(terminalTheme, brightness: brightness);
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
  late final AppBootstrapController _bootstrapController;
  StreamSubscription<List<Host>>? _homeScreenShortcutHostsSubscription;
  StreamSubscription<Set<int>>? _pinnedHomeScreenShortcutHostsSubscription;
  StreamSubscription<TmuxAlertNotificationPayload>? _tmuxAlertTapSubscription;
  ProviderSubscription<AuthState>? _authStateSubscription;
  List<Host> _latestHomeScreenShortcutHosts = const <Host>[];
  Set<int> _latestPinnedHomeScreenShortcutHostIds = const <int>{};
  bool _hasLoadedHomeScreenShortcutHosts = false;
  bool _hasLoadedPinnedHomeScreenShortcutHostIds = false;
  TmuxAlertNotificationPayload? _pendingTmuxAlertNavigation;
  bool _isTmuxAlertNavigationQueued = false;

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
    _bootstrapController = AppBootstrapController(
      startNotificationRouting: _startTmuxAlertNotificationRouting,
      initializeNotificationRouting: _initializeTmuxAlertNotificationRouting,
      supportsHomeScreenShortcutActions: supportsHomeScreenShortcutActions,
      startHomeScreenShortcutListeners: _listenForHomeScreenShortcutChanges,
      initializeHomeScreenShortcuts: () =>
          ref.read(homeScreenShortcutServiceProvider).initialize(),
      refreshMonetizationOnStartup: _refreshMonetizationOnStartup,
      syncForegroundBackgroundStatus: _syncForegroundBackgroundStatus,
      runStartupTask: _runLifecycleSync,
    );
    _bootstrapController.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_homeScreenShortcutHostsSubscription?.cancel());
    unawaited(_pinnedHomeScreenShortcutHostsSubscription?.cancel());
    unawaited(_tmuxAlertTapSubscription?.cancel());
    _authStateSubscription?.close();
    super.dispose();
  }

  void _startTmuxAlertNotificationRouting() {
    final notificationService = ref.read(localNotificationServiceProvider);
    _tmuxAlertTapSubscription = notificationService.tmuxAlertTaps.listen(
      _handleTmuxAlertNotification,
    );
    _authStateSubscription = ref.listenManual<AuthState>(authStateProvider, (
      previous,
      next,
    ) {
      if (_canOpenTmuxAlertNotification(next)) {
        _queuePendingTmuxAlertNavigation();
      }
    });
  }

  Future<void> _initializeTmuxAlertNotificationRouting() async {
    final notificationService = ref.read(localNotificationServiceProvider);
    await notificationService.initialize();
    final launchAlert = await notificationService.consumeLaunchTmuxAlert();
    if (launchAlert != null) {
      _handleTmuxAlertNotification(launchAlert);
    }
  }

  bool _canOpenTmuxAlertNotification(AuthState authState) =>
      authState != AuthState.unknown && authState != AuthState.locked;

  void _handleTmuxAlertNotification(TmuxAlertNotificationPayload payload) {
    _pendingTmuxAlertNavigation = payload;
    _queuePendingTmuxAlertNavigation();
  }

  void _queuePendingTmuxAlertNavigation() {
    if (_isTmuxAlertNavigationQueued ||
        _pendingTmuxAlertNavigation == null ||
        !_canOpenTmuxAlertNotification(ref.read(authStateProvider))) {
      return;
    }

    _isTmuxAlertNavigationQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTmuxAlertNavigationQueued = false;
      if (!mounted ||
          !_canOpenTmuxAlertNotification(ref.read(authStateProvider))) {
        return;
      }
      final payload = _pendingTmuxAlertNavigation;
      if (payload == null) {
        return;
      }
      _pendingTmuxAlertNavigation = null;
      openTmuxAlertNotificationStack(
        router: ref.read(routerProvider),
        payload: payload,
        notificationTapId: '${DateTime.now().microsecondsSinceEpoch}',
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
