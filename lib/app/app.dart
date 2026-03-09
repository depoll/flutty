import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/services/background_ssh_service.dart';
import '../domain/services/settings_service.dart';
import '../domain/services/ssh_service.dart';
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

    return _BackgroundLifecycleBridge(
      child: MaterialApp.router(
        title: 'MonkeySSH',
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runLifecycleSync(
      _syncForegroundBackgroundStatus,
      context: 'while syncing background SSH status during app startup',
      defer: true,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _syncForegroundBackgroundStatus() async {
    await BackgroundSshService.setForegroundState(isForeground: true);
    await ref.read(activeSessionsProvider.notifier).syncBackgroundStatus();
  }

  void _runLifecycleSync(
    Future<void> Function() operation, {
    required String context,
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
            context: ErrorDescription(context),
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
        _syncForegroundBackgroundStatus,
        context:
            'while syncing background SSH status after returning to the foreground',
      );
      return;
    }
    _runLifecycleSync(
      () => BackgroundSshService.setForegroundState(isForeground: false),
      context:
          'while syncing background SSH status after moving to the background',
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
