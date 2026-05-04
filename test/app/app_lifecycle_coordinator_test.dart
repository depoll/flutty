// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/app/app_lifecycle_coordinator.dart';

void main() {
  group('AppBootstrapController', () {
    test('starts startup tasks in app bootstrap order', () async {
      final calls = <String>[];
      final deferredOperations = <Future<void> Function()>[];

      AppBootstrapController(
        startNotificationRouting: () => calls.add('listen:notifications'),
        initializeNotificationRouting: () async {
          calls.add('run:notifications');
        },
        supportsHomeScreenShortcutActions: true,
        startHomeScreenShortcutListeners: () => calls.add('listen:shortcuts'),
        initializeHomeScreenShortcuts: () async {
          calls.add('run:shortcuts');
        },
        refreshMonetizationOnStartup: () async {
          calls.add('run:monetization');
        },
        syncForegroundBackgroundStatus: () async {
          calls.add('run:foreground');
        },
        runStartupTask:
            (operation, {required errorContext, bool defer = false}) {
              calls.add('schedule:$errorContext:$defer');
              deferredOperations.add(operation);
            },
      ).start();

      expect(calls, [
        'listen:notifications',
        'schedule:while initializing tmux alert notification routing during app startup:true',
        'listen:shortcuts',
        'schedule:while initializing home-screen shortcuts during app startup:true',
        'schedule:while refreshing subscription state during app startup:true',
        'schedule:while syncing background SSH status during app startup:true',
      ]);

      for (final operation in deferredOperations) {
        await operation();
      }

      expect(calls.skip(calls.length - 4), [
        'run:notifications',
        'run:shortcuts',
        'run:monetization',
        'run:foreground',
      ]);
    });

    test('skips home-screen shortcut startup when unsupported', () {
      final calls = <String>[];

      AppBootstrapController(
        startNotificationRouting: () => calls.add('listen:notifications'),
        initializeNotificationRouting: () async {
          calls.add('run:notifications');
        },
        supportsHomeScreenShortcutActions: false,
        startHomeScreenShortcutListeners: () => calls.add('listen:shortcuts'),
        initializeHomeScreenShortcuts: () async {
          calls.add('run:shortcuts');
        },
        refreshMonetizationOnStartup: () async {
          calls.add('run:monetization');
        },
        syncForegroundBackgroundStatus: () async {
          calls.add('run:foreground');
        },
        runStartupTask:
            (operation, {required errorContext, bool defer = false}) {
              calls.add('schedule:$errorContext:$defer');
            },
      ).start();

      expect(calls, [
        'listen:notifications',
        'schedule:while initializing tmux alert notification routing during app startup:true',
        'schedule:while refreshing subscription state during app startup:true',
        'schedule:while syncing background SSH status during app startup:true',
      ]);
    });
  });

  group('AppLifecycleCoordinator', () {
    test('locks auth before foreground SSH sync resumes', () async {
      final callOrder = <String>[];
      final authSyncCompleter = Completer<void>();
      final foregroundSyncStarted = Completer<void>();

      final coordinator = AppLifecycleCoordinator(
        syncAuthLifecycle: (state) async {
          callOrder.add('auth:start:${state.name}');
          await authSyncCompleter.future;
          callOrder.add('auth:end:${state.name}');
        },
        syncForegroundBackgroundStatus: () async {
          callOrder.add('foreground:start');
          foregroundSyncStarted.complete();
        },
        syncBackgroundState: () async => callOrder.add('background'),
      );

      final future = coordinator.handleStateChanged(AppLifecycleState.resumed);

      await pumpEventQueue();
      expect(callOrder, ['auth:start:resumed']);
      expect(foregroundSyncStarted.isCompleted, isFalse);

      authSyncCompleter.complete();
      await future;

      expect(foregroundSyncStarted.isCompleted, isTrue);
      expect(callOrder, [
        'auth:start:resumed',
        'auth:end:resumed',
        'foreground:start',
      ]);
    });
  });
}
