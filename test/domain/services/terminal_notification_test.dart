import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

void main() {
  late TerminalNotificationParser parser;

  setUp(() => parser = TerminalNotificationParser());

  group('OSC 9 (iTerm2)', () {
    test('plain message becomes the body', () {
      final req = parser.handleOsc('9', ['Build finished']);
      expect(req, isNotNull);
      expect(req!.title, isNull);
      expect(req.body, 'Build finished');
    });

    test('message containing semicolons is rejoined', () {
      final req = parser.handleOsc('9', ['a', 'b', 'c']);
      expect(req!.body, 'a;b;c');
    });

    test('ConEmu structured OSC 9 (numeric subcommand) is ignored', () {
      expect(parser.handleOsc('9', ['4', '1', '50']), isNull);
      expect(parser.handleOsc('9', ['9', '/home/user']), isNull);
    });

    test('a message that merely starts with a number still notifies', () {
      final req = parser.handleOsc('9', ['5 tests failed']);
      expect(req!.body, '5 tests failed');
    });

    test('empty payload yields nothing', () {
      expect(parser.handleOsc('9', []), isNull);
      expect(parser.handleOsc('9', ['']), isNull);
    });
  });

  group('OSC 777 (urxvt)', () {
    test('notify with title and body', () {
      final req = parser.handleOsc('777', ['notify', 'Title', 'Body text']);
      expect(req!.title, 'Title');
      expect(req.body, 'Body text');
    });

    test('notify with only a title demotes it to the body', () {
      final req = parser.handleOsc('777', ['notify', 'Just a title']);
      expect(req!.title, isNull);
      expect(req.body, 'Just a title');
    });

    test('body containing semicolons is rejoined', () {
      final req = parser.handleOsc('777', ['notify', 'T', 'a', 'b']);
      expect(req!.title, 'T');
      expect(req.body, 'a;b');
    });

    test('non-notify subcommand is ignored', () {
      expect(parser.handleOsc('777', ['something', 'x']), isNull);
      expect(parser.handleOsc('777', []), isNull);
    });
  });

  group('OSC 99 (kitty)', () {
    test('single chunk with no metadata is a title-only notification', () {
      final req = parser.handleOsc('99', ['', 'Hello there']);
      expect(req!.title, isNull);
      expect(req.body, 'Hello there');
    });

    test('separate title and body chunks assemble by id', () {
      expect(
        parser.handleOsc('99', ['i=1:d=0', 'My Title']),
        isNull,
        reason: 'd=0 means more chunks follow',
      );
      final req = parser.handleOsc('99', ['i=1:p=body', 'My Body']);
      expect(req!.title, 'My Title');
      expect(req.body, 'My Body');
    });

    test('a title delivered across multiple chunks is concatenated', () {
      expect(parser.handleOsc('99', ['i=7:d=0', 'Hello ']), isNull);
      expect(parser.handleOsc('99', ['i=7:d=0', 'beautiful ']), isNull);
      final req = parser.handleOsc('99', ['i=7:d=1', 'world']);
      expect(req!.body, 'Hello beautiful world');
    });

    test('base64-encoded payload (e=1) is decoded', () {
      final encoded = base64.encode(utf8.encode('Encoded title'));
      final req = parser.handleOsc('99', ['i=2:e=1', encoded]);
      expect(req!.body, 'Encoded title');
    });

    test('same identifiers update and p=close clears a notification', () {
      final created = parser.handleOsc('99', ['i=build-3', 'Started']);
      expect(created?.identifier, 'build-3');
      expect(created?.action, TerminalNotificationAction.show);

      final updated = parser.handleOsc('99', ['i=build-3:p=body', 'Finished']);
      expect(updated?.identifier, 'build-3');
      expect(updated?.body, 'Finished');

      expect(
        parser.handleOsc('99', ['i=build-3:p=close']),
        const TerminalNotificationRequest.close(identifier: 'build-3'),
      );
    });

    test('a=report requests activation feedback', () {
      final request = parser.handleOsc('99', [
        'i=build:a=focus,report',
        'Ready',
      ]);
      expect(request?.reportsActivation, isTrue);
      expect(
        buildKittyNotificationActivationReport(request?.identifier),
        '\x1b]99;i=build;\x1b\\',
      );
    });

    test('unidentified notifications receive distinct local identities', () {
      final first = parser.handleOsc('99', ['', 'One']);
      final second = parser.handleOsc('99', ['', 'Two']);
      expect(first?.identifier, isNull);
      expect(second?.identifier, isNull);
      expect(first?.platformIdentifier, isNot(second?.platformIdentifier));
    });

    test('builds a truthful capability response', () {
      expect(
        buildKittyNotificationCapabilityResponse(const ['i=q1:p=?']),
        '\x1b]99;i=q1:p=?;a=focus,report:o=always:p=title,body\x1b\\',
      );
    });

    test('interleaved ids stay independent', () {
      expect(parser.handleOsc('99', ['i=a:d=0', 'Alpha']), isNull);
      expect(parser.handleOsc('99', ['i=b:d=0', 'Bravo']), isNull);
      expect(parser.handleOsc('99', ['i=a:d=1', ''])!.body, 'Alpha');
      expect(parser.handleOsc('99', ['i=b:d=1', ''])!.body, 'Bravo');
    });
  });

  group('sanitization', () {
    test('control characters are stripped from the message', () {
      final req = parser.handleOsc('9', ['hi\x07\x1b[31mthere']);
      expect(req!.body, isNot(contains('\x1b')));
      expect(req.body, isNot(contains('\x07')));
    });
  });

  test('unrelated OSC codes are ignored', () {
    expect(parser.handleOsc('8', ['', 'https://example.com']), isNull);
    expect(parser.handleOsc('52', ['c', 'ZGF0YQ==']), isNull);
  });
}
