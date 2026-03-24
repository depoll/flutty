// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/app/app_lifecycle_coordinator.dart';

void main() {
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
