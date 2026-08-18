import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

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
      const payload = TerminalNotificationPayload(
        hostId: 7,
        connectionId: 21,
        platformNotificationId: 4321,
        notificationIdentifier: 'build',
        reportsActivation: true,
        focusOnActivation: false,
      );

      expect(TerminalNotificationPayload.decode(payload.encode()), payload);
    });

    test('decodes legacy navigation-only payloads', () {
      expect(
        TerminalNotificationPayload.decode(
          '{"type":"terminal-notification","version":1,'
          '"hostId":7,"connectionId":21}',
        ),
        const TerminalNotificationPayload(hostId: 7, connectionId: 21),
      );
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

  test('Kitty urgency and sound map to native notification details', () {
    final quiet = buildTerminalNotificationDetails(
      urgency: TerminalNotificationUrgency.low,
      sound: TerminalNotificationSound.silent,
      timeout: const Duration(milliseconds: 1250),
    );
    expect(quiet.android?.channelId, terminalNotificationLowSilentChannelId);
    expect(quiet.android?.importance, Importance.low);
    expect(quiet.android?.priority, Priority.low);
    expect(quiet.android?.playSound, isFalse);
    expect(quiet.android?.silent, isTrue);
    expect(quiet.android?.timeoutAfter, 1250);
    expect(quiet.iOS?.presentSound, isFalse);
    expect(quiet.iOS?.interruptionLevel, InterruptionLevel.passive);

    final critical = buildTerminalNotificationDetails(
      urgency: TerminalNotificationUrgency.critical,
      sound: TerminalNotificationSound.system,
    );
    expect(critical.android?.channelId, terminalNotificationCriticalChannelId);
    expect(critical.android?.importance, Importance.max);
    expect(critical.android?.priority, Priority.max);
    expect(critical.android?.playSound, isTrue);
    expect(critical.iOS?.presentSound, isTrue);
    expect(critical.iOS?.interruptionLevel, InterruptionLevel.active);

    final channels = LocalNotificationService.debugTerminalNotificationChannels;
    for (final channelId in <String>{
      terminalNotificationLowSilentChannelId,
      terminalNotificationSilentChannelId,
      terminalNotificationCriticalSilentChannelId,
    }) {
      expect(
        channels.singleWhere((channel) => channel.id == channelId).playSound,
        isFalse,
      );
    }
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
    expect(
      buildTerminalNotificationId(21, identifier: 'build/a'),
      isNot(buildTerminalNotificationId(21, identifier: 'build+a')),
    );
  });

  test('buildTerminalNotificationLocation targets the source connection', () {
    final location = buildTerminalNotificationLocation(
      const TerminalNotificationPayload(hostId: 7, connectionId: 21),
    );

    expect(location, '/terminal/7?connectionId=21');
  });

  group('AcpNotificationPayload', () {
    test('round-trips completion and permission notification fields', () {
      const completion = AcpNotificationPayload(
        kind: AcpNotificationKind.completion,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );
      const permission = AcpNotificationPayload(
        kind: AcpNotificationKind.permission,
        hostId: 3,
        providerId: 'builtin:opencode',
        bridgeId: 'bridge-2',
        acpSessionId: 'session-2',
      );

      expect(AcpNotificationPayload.decode(completion.encode()), completion);
      expect(AcpNotificationPayload.decode(permission.encode()), permission);
    });

    test('ignores malformed and unrelated payloads', () {
      expect(AcpNotificationPayload.decode(null), isNull);
      expect(AcpNotificationPayload.decode('not json'), isNull);
      expect(AcpNotificationPayload.decode('{"type":"tmux-alert"}'), isNull);
      expect(
        AcpNotificationPayload.decode(
          '{"type":"acp-notification","version":1,"kind":"completion"}',
        ),
        isNull,
      );
      expect(
        AcpNotificationPayload.decode(
          '{"type":"acp-notification","version":1,"kind":"unknown-kind",'
          '"hostId":3,"providerId":"builtin:copilot-cli",'
          '"bridgeId":"bridge-1","acpSessionId":"session-1"}',
        ),
        isNull,
      );
    });

    test('does not decode as a tmux alert or terminal notification', () {
      const payload = AcpNotificationPayload(
        kind: AcpNotificationKind.completion,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );
      expect(TmuxAlertNotificationPayload.decode(payload.encode()), isNull);
      expect(TerminalNotificationPayload.decode(payload.encode()), isNull);
    });

    test('encode never includes prompt/tool/path/content fields', () {
      const payload = AcpNotificationPayload(
        kind: AcpNotificationKind.permission,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );
      final encoded = payload.encode();
      for (final forbidden in ['prompt', 'tool', 'path', 'content', 'title']) {
        expect(encoded.toLowerCase(), isNot(contains(forbidden)));
      }
    });
  });

  test('buildAcpNotificationLocation deep-links to the specific chat', () {
    final location = buildAcpNotificationLocation(
      const AcpNotificationPayload(
        kind: AcpNotificationKind.completion,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      ),
    );

    final uri = Uri.parse(location);
    expect(uri.path, acpAgentChatRoutePath);
    expect(uri.queryParameters[acpAgentChatHostQueryKey], '3');
    expect(uri.queryParameters[acpAgentChatSessionQueryKey], 'session-1');
    // Must not target the nonexistent /home route.
    expect(location.startsWith('/home'), isFalse);
  });
}
