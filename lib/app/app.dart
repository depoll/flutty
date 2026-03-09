import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/services/background_ssh_service.dart';
import '../domain/services/settings_service.dart';
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

class _BackgroundLifecycleBridge extends StatefulWidget {
  const _BackgroundLifecycleBridge({required this.child});

  final Widget child;

  @override
  State<_BackgroundLifecycleBridge> createState() =>
      _BackgroundLifecycleBridgeState();
}

class _BackgroundLifecycleBridgeState extends State<_BackgroundLifecycleBridge>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(
      () => BackgroundSshService.setForegroundState(isForeground: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    unawaited(
      BackgroundSshService.setForegroundState(isForeground: isForeground),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
