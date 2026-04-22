import 'package:flutter_test/flutter_test.dart';
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

  group('shouldReloadTmuxWindowsFromControlLine', () {
    const subscriptionName = 'flutty-1-42';

    test('returns true for matching subscription notifications', () {
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          r'%subscription-changed flutty-1-42 $1 @1 1 %1 : updated',
          subscriptionName: subscriptionName,
        ),
        isTrue,
      );
    });

    test('returns false for other subscriptions', () {
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          r'%subscription-changed other-subscription $1 @1 1 %1 : updated',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
    });

    test('returns true for window lifecycle notifications', () {
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          '%window-renamed @1 🔥 test-emoji',
          subscriptionName: subscriptionName,
        ),
        isTrue,
      );
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          '%window-close @1',
          subscriptionName: subscriptionName,
        ),
        isTrue,
      );
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          r'%session-window-changed $1 @1',
          subscriptionName: subscriptionName,
        ),
        isTrue,
      );
    });

    test(
      'returns true for control-mode notifications carrying window state',
      () {
        expect(
          shouldReloadTmuxWindowsFromControlLine(
            '%layout-change @1 even-horizontal even-horizontal *',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldReloadTmuxWindowsFromControlLine(
            r'%client-session-changed /dev/ttys001 $1 dev',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldReloadTmuxWindowsFromControlLine(
            '%pane-mode-changed %1',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
      },
    );

    test('returns false for control block markers and noise', () {
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          '%begin 1 2 0',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          '%output %1 hello',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
      expect(
        shouldReloadTmuxWindowsFromControlLine(
          '',
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
