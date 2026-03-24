import 'package:flutter/widgets.dart';

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
