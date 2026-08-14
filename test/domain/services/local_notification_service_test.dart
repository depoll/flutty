import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/services/local_notification_service.dart';

void main() {
  group('TmuxAlertNotificationPayload', () {
    test('round-trips tmux alert routing fields', () {
      const payload = TmuxAlertNotificationPayload(
        hostId: 12,
        connectionId: 34,
        tmuxSessionName: 'work',
        windowIndex: 5,
        windowId: '@9',
      );

      expect(TmuxAlertNotificationPayload.decode(payload.encode()), payload);
    });

    test('ignores malformed and unrelated payloads', () {
      expect(TmuxAlertNotificationPayload.decode(null), isNull);
      expect(TmuxAlertNotificationPayload.decode('not json'), isNull);
      expect(TmuxAlertNotificationPayload.decode('{"type":"other"}'), isNull);
      expect(
        TmuxAlertNotificationPayload.decode(
          '{"type":"tmux-alert","version":1,"hostId":12}',
        ),
        isNull,
      );
      expect(
        TmuxAlertNotificationPayload.decode(
          '{"type":"tmux-alert","version":1,"hostId":12,'
          '"connectionId":34,"tmuxSessionName":"work","windowIndex":5,'
          '"windowId":"not-a-window-id"}',
        ),
        isNull,
      );
    });
  });

  test('buildTmuxAlertTerminalLocation targets the source connection window', () {
    final location = buildTmuxAlertTerminalLocation(
      const TmuxAlertNotificationPayload(
        hostId: 12,
        connectionId: 34,
        tmuxSessionName: 'project main',
        windowIndex: 5,
        windowId: '@9',
      ),
    );

    expect(
      location,
      '/terminal/12?connectionId=34&tmuxSession=project+main&tmuxWindow=5&tmuxWindowId=%409',
    );
  });

  group('TerminalNotificationPayload', () {
    test('round-trips terminal notification routing fields', () {
      const payload = TerminalNotificationPayload(hostId: 7, connectionId: 21);

      expect(TerminalNotificationPayload.decode(payload.encode()), payload);
    });

    test('ignores malformed and unrelated payloads', () {
      expect(TerminalNotificationPayload.decode(null), isNull);
      expect(TerminalNotificationPayload.decode('not json'), isNull);
      expect(
        TerminalNotificationPayload.decode('{"type":"tmux-alert"}'),
        isNull,
      );
      expect(
        TerminalNotificationPayload.decode(
          '{"type":"terminal-notification","version":1,"hostId":7}',
        ),
        isNull,
      );
    });

    test('does not decode as a tmux alert and vice versa', () {
      const terminal = TerminalNotificationPayload(hostId: 7, connectionId: 21);
      expect(TmuxAlertNotificationPayload.decode(terminal.encode()), isNull);
    });
  });

  test('Kitty identifiers replace within a connection without collisions', () {
    expect(
      buildTerminalNotificationId(21, identifier: 'build'),
      buildTerminalNotificationId(21, identifier: 'build'),
    );
    expect(
      buildTerminalNotificationId(21, identifier: 'build'),
      isNot(buildTerminalNotificationId(21, identifier: 'deploy')),
    );
    expect(
      buildTerminalNotificationId(21, identifier: 'build'),
      isNot(buildTerminalNotificationId(22, identifier: 'build')),
    );
  });

  test('buildTerminalNotificationLocation targets the source connection', () {
    final location = buildTerminalNotificationLocation(
      const TerminalNotificationPayload(hostId: 7, connectionId: 21),
    );

    expect(location, '/terminal/7?connectionId=21');
  });
}
