import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  group('control mode command builders', () {
    test(
      'attach command starts tmux in control mode with safe client flags',
      () {
        expect(
          buildTmuxControlModeAttachCommand('dev\'s session'),
          'tmux -CC attach-session -f '
          'read-only,ignore-size,no-output,wait-exit '
          "-t 'dev'\"'\"'s session'",
        );
      },
    );

    test(
      'subscription command watches all windows in the attached session',
      () {
        expect(
          buildTmuxWindowSubscriptionCommand('flutty-1-42'),
          'refresh-client -B '
          "'flutty-1-42:@*:"
          '#{window_index}|#{window_name}|#{window_active}|'
          '#{pane_current_command}|#{pane_current_path}|'
          "#{window_flags}|#{pane_title}|#{window_activity}'",
        );
      },
    );
  });

  group('parseTmuxWindowChangeEventFromControlLine', () {
    const subscriptionName = 'flutty-1-42';

    test('returns a window snapshot event for matching subscriptions', () {
      final event = parseTmuxWindowChangeEventFromControlLine(
        r'%subscription-changed flutty-1-42 $1 @1 1 %1 : 1|renamed|1|sleep|/tmp|*|custom-title|1712930000',
        subscriptionName: subscriptionName,
      );

      expect(event, isA<TmuxWindowSnapshotEvent>());
      final snapshot = event! as TmuxWindowSnapshotEvent;
      expect(snapshot.window.index, 1);
      expect(snapshot.window.name, 'renamed');
      expect(snapshot.window.isActive, isTrue);
      expect(snapshot.window.paneTitle, 'custom-title');
    });

    test('normalizes the wrapped first control-mode line', () {
      final event = parseTmuxWindowChangeEventFromControlLine(
        '\u001bP1000p%subscription-changed flutty-1-42 \$1 @1 1 %1 : '
        '0|shell|1|sleep|/tmp|*|wrapped-title|1712930000',
        subscriptionName: subscriptionName,
      );

      expect(event, isA<TmuxWindowSnapshotEvent>());
      final snapshot = event! as TmuxWindowSnapshotEvent;
      expect(snapshot.window.displayTitle, 'wrapped-title');
    });

    test('returns null for other subscriptions', () {
      expect(
        parseTmuxWindowChangeEventFromControlLine(
          r'%subscription-changed other-subscription $1 @1 1 %1 : updated',
          subscriptionName: subscriptionName,
        ),
        isNull,
      );
    });

    test(
      'returns reload events for lifecycle notifications without snapshots',
      () {
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%window-close @1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%unlinked-window-close @1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%pane-mode-changed %1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
      },
    );

    test(
      'ignores noise and notifications that should rely on snapshots instead',
      () {
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%window-renamed @1 🔥 test-emoji',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            r'%session-window-changed $1 @1',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%begin 1 2 0',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%output %1 hello',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
      },
    );
  });

  group('shouldScheduleTmuxWindowReloadFallback', () {
    const subscriptionName = 'flutty-1-42';

    test(
      'schedules fallback reloads for window signals that may miss snapshots',
      () {
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            r'%subscription-changed flutty-1-42 $1 @1 1 %1 : malformed',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            r'%session-window-changed $1 @1',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            '%window-renamed @1 renamed-window',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
      },
    );

    test('ignores unrelated control-mode noise', () {
      expect(
        shouldScheduleTmuxWindowReloadFallback(
          r'%subscription-changed other-subscription $1 @1 1 %1 : value',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
      expect(
        shouldScheduleTmuxWindowReloadFallback(
          '%output %1 hello',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
    });
  });

  group('tmux window action helpers', () {
    test('parses the current pane path from display-message output', () {
      expect(parseTmuxCurrentPanePath('/tmp/project\n'), '/tmp/project');
      expect(
        parseTmuxCurrentPanePath('\n  /tmp/workspace  \n'),
        '/tmp/workspace',
      );
      expect(parseTmuxCurrentPanePath(' \n \n'), isNull);
    });

    test('detects only non-control tmux clients as foreground clients', () {
      expect(hasForegroundTmuxClient('1\n1\n'), isFalse);
      expect(hasForegroundTmuxClient('1\n0\n'), isTrue);
      expect(hasForegroundTmuxClient('\n0\n'), isTrue);
      expect(hasForegroundTmuxClient(' \n \n'), isFalse);
    });
  });

  group('decideTmuxHeartbeatAction', () {
    const heartbeat = Duration(seconds: 5);
    const maxSilence = Duration(seconds: 30);

    test('noop while control-mode notifications are flowing', () {
      expect(
        decideTmuxHeartbeatAction(
          silence: Duration.zero,
          heartbeatInterval: heartbeat,
          maxSilenceBeforeRestart: maxSilence,
        ),
        TmuxControlHeartbeatAction.noop,
      );
      expect(
        decideTmuxHeartbeatAction(
          silence: const Duration(milliseconds: 4999),
          heartbeatInterval: heartbeat,
          maxSilenceBeforeRestart: maxSilence,
        ),
        TmuxControlHeartbeatAction.noop,
      );
    });

    test('synthesizes a refresh once the channel has been silent for the '
        'heartbeat interval', () {
      expect(
        decideTmuxHeartbeatAction(
          silence: heartbeat,
          heartbeatInterval: heartbeat,
          maxSilenceBeforeRestart: maxSilence,
        ),
        TmuxControlHeartbeatAction.refresh,
      );
      expect(
        decideTmuxHeartbeatAction(
          silence: const Duration(seconds: 20),
          heartbeatInterval: heartbeat,
          maxSilenceBeforeRestart: maxSilence,
        ),
        TmuxControlHeartbeatAction.refresh,
      );
    });

    test('restarts the control session once silence exceeds the dead-channel '
        'threshold', () {
      expect(
        decideTmuxHeartbeatAction(
          silence: maxSilence,
          heartbeatInterval: heartbeat,
          maxSilenceBeforeRestart: maxSilence,
        ),
        TmuxControlHeartbeatAction.restart,
      );
      expect(
        decideTmuxHeartbeatAction(
          silence: const Duration(minutes: 5),
          heartbeatInterval: heartbeat,
          maxSilenceBeforeRestart: maxSilence,
        ),
        TmuxControlHeartbeatAction.restart,
      );
    });
  });
}
