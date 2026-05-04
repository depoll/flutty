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
}
