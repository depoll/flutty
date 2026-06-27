import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('terminal capability query responses', () {
    test('XTVERSION (CSI > q) reports a kitty-family identity', () {
      // CLIs such as the GitHub Copilot CLI gate their richer rendering (e.g.
      // full-width prompt/composer backgrounds) on a recognized XTVERSION name.
      // MonkeySSH implements the kitty graphics + keyboard protocols, so it
      // answers with a kitty identity to unlock that path.
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[>q');

      expect(responses, ['\x1bP>|kitty(0.32.0)\x1b\\']);
    });

    test('XTVERSION reply starts with a name Copilot CLI recognizes', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[>q');

      // DCS `ESC P > | <name> ESC \`; the payload must start with "kitty".
      final reply = responses.single;
      expect(reply.startsWith('\x1bP>|kitty'), isTrue);
      expect(reply.endsWith('\x1b\\'), isTrue);
    });

    test('a bare CSI q (no > prefix) does not emit an XTVERSION reply', () {
      final responses = <String>[];
      // Space-intermediate form (DECSCUSR cursor style) must not be treated as
      // XTVERSION.
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[ q');

      expect(responses, isEmpty);
    });

    test('primary device attributes still answer', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[c');

      expect(responses, ['\x1b[?1;2c']);
    });
  });
}
