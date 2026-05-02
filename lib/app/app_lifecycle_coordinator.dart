import 'package:flutter/widgets.dart';

/// Runs an asynchronous app startup operation.
typedef AppStartupOperation = Future<void> Function();

/// Runs [operation] and reports failures with startup context.
typedef AppStartupTaskRunner =
    void Function(
      AppStartupOperation operation, {
      required String errorContext,
      bool defer,
    });

/// Coordinates startup operations that are triggered from the root app widget.
class AppBootstrapController {
  /// Creates a new [AppBootstrapController].
  AppBootstrapController({
    required void Function() startNotificationRouting,
    required AppStartupOperation initializeNotificationRouting,
    required bool supportsHomeScreenShortcutActions,
    required void Function() startHomeScreenShortcutListeners,
    required AppStartupOperation initializeHomeScreenShortcuts,
    required AppStartupOperation refreshMonetizationOnStartup,
    required AppStartupOperation syncForegroundBackgroundStatus,
    required AppStartupTaskRunner runStartupTask,
  }) : _startNotificationRouting = startNotificationRouting,
       _initializeNotificationRouting = initializeNotificationRouting,
       _supportsHomeScreenShortcutActions = supportsHomeScreenShortcutActions,
       _startHomeScreenShortcutListeners = startHomeScreenShortcutListeners,
       _initializeHomeScreenShortcuts = initializeHomeScreenShortcuts,
       _refreshMonetizationOnStartup = refreshMonetizationOnStartup,
       _syncForegroundBackgroundStatus = syncForegroundBackgroundStatus,
       _runStartupTask = runStartupTask;

  final void Function() _startNotificationRouting;
  final AppStartupOperation _initializeNotificationRouting;
  final bool _supportsHomeScreenShortcutActions;
  final void Function() _startHomeScreenShortcutListeners;
  final AppStartupOperation _initializeHomeScreenShortcuts;
  final AppStartupOperation _refreshMonetizationOnStartup;
  final AppStartupOperation _syncForegroundBackgroundStatus;
  final AppStartupTaskRunner _runStartupTask;

  /// Starts app bootstrap work in the same order as the root widget.
  void start() {
    _startNotificationRouting();
    _runStartupTask(
      _initializeNotificationRouting,
      errorContext:
          'while initializing tmux alert notification routing during app startup',
      defer: true,
    );

    if (_supportsHomeScreenShortcutActions) {
      _startHomeScreenShortcutListeners();
      _runStartupTask(
        _initializeHomeScreenShortcuts,
        errorContext:
            'while initializing home-screen shortcuts during app startup',
        defer: true,
      );
    }

    _runStartupTask(
      _refreshMonetizationOnStartup,
      errorContext: 'while refreshing subscription state during app startup',
      defer: true,
    );
    _runStartupTask(
      _syncForegroundBackgroundStatus,
      errorContext: 'while syncing background SSH status during app startup',
      defer: true,
    );
  }
}

/// Coordinates auth locking and background SSH lifecycle sync operations.
class AppLifecycleCoordinator {
  /// Creates a new [AppLifecycleCoordinator].
  AppLifecycleCoordinator({
    required Future<void> Function(AppLifecycleState state) syncAuthLifecycle,
    required Future<void> Function() syncForegroundBackgroundStatus,
    required Future<void> Function() syncBackgroundState,
  }) : _syncAuthLifecycle = syncAuthLifecycle,
       _syncForegroundBackgroundStatus = syncForegroundBackgroundStatus,
       _syncBackgroundState = syncBackgroundState;

  final Future<void> Function(AppLifecycleState state) _syncAuthLifecycle;
  final Future<void> Function() _syncForegroundBackgroundStatus;
  final Future<void> Function() _syncBackgroundState;

  /// Handles the latest app lifecycle state in a security-first order.
  Future<void> handleStateChanged(AppLifecycleState state) async {
    final isForeground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };

    await _syncAuthLifecycle(state);

    if (isForeground) {
      await _syncForegroundBackgroundStatus();
      return;
    }

    await _syncBackgroundState();
  }
}
