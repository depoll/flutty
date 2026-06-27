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

    test('primary device attributes report VT220 with ANSI colour', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[c');

      // DA1: VT220 service class (62) advertising ANSI colour (22).
      expect(responses, ['\x1b[?62;22c']);
    });

    test('secondary device attributes report a VT220-class identity', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[>c');

      // DA2: model 1 (VT220), firmware version 0.
      expect(responses, ['\x1b[>1;0;0c']);
    });
  });

  group(r'DECRQM (CSI Ps $ p) mode reports', () {
    test('reports a tracked DEC private mode as set/reset', () {
      final responses = <String>[];
      // Bracketed paste (2004) starts reset, then enable it.
      final terminal = Terminal()
        ..onOutput = responses.add
        ..write('\x1b[?2004\$p');
      expect(responses, ['\x1b[?2004;2\$y']);

      responses.clear();
      terminal
        ..write('\x1b[?2004h')
        ..write('\x1b[?2004\$p');
      expect(responses, ['\x1b[?2004;1\$y']);
    });

    test('reports default-on modes (autowrap, cursor visible) as set', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[?7\$p') // DECAWM, on by default
        ..write('\x1b[?25\$p'); // DECTCEM, on by default

      expect(responses, ['\x1b[?7;1\$y', '\x1b[?25;1\$y']);
    });

    test('reports synchronized output (2026) as not recognized', () {
      final responses = <String>[];
      // MonkeySSH deliberately does not implement synchronized output, so
      // DECRQM must report it as not recognized (value 0) rather than claim
      // support.
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[?2026\$p');

      expect(responses, ['\x1b[?2026;0\$y']);
    });

    test('reports an unknown DEC private mode as not recognized', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[?9999\$p');

      expect(responses, ['\x1b[?9999;0\$y']);
    });

    test('reports tracked ANSI modes (insert) as set/reset', () {
      final responses = <String>[];
      final terminal = Terminal()
        ..onOutput = responses.add
        ..write('\x1b[4\$p'); // IRM off by default
      expect(responses, ['\x1b[4;2\$y']);

      responses.clear();
      terminal
        ..write('\x1b[4h')
        ..write('\x1b[4\$p');
      expect(responses, ['\x1b[4;1\$y']);
    });

    test('reports tracked mouse mode (SGR encoding) accurately', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[?1006h') // enable SGR mouse encoding
        ..write('\x1b[?1006\$p')
        ..write('\x1b[?1015\$p'); // urxvt encoding, not active

      expect(responses, ['\x1b[?1006;1\$y', '\x1b[?1015;2\$y']);
    });

    test('a soft reset (CSI ! p) does not emit a DECRQM reply', () {
      final responses = <String>[];
      // `!` intermediate (DECSTR), not `$`, so it must not be misread as
      // DECRQM and must not produce a mode report.
      Terminal()
        ..onOutput = responses.add
        ..write('\x1b[!p');

      expect(responses, isEmpty);
    });
  });

  group('XTGETTCAP (DCS + q <hex> ST)', () {
    String hex(String value) =>
        value.codeUnits.map((u) => u.toRadixString(16).padLeft(2, '0')).join();

    test('reports the colour count (Co) as 256', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1bP+q${hex('Co')}\x1b\\');

      expect(responses, ['\x1bP1+r${hex('Co')}=${hex('256')}\x1b\\']);
    });

    test('reports terminfo colors and direct-colour (RGB)', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1bP+q${hex('colors')}\x1b\\')
        ..write('\x1bP+q${hex('RGB')}\x1b\\');

      expect(responses, [
        '\x1bP1+r${hex('colors')}=${hex('256')}\x1b\\',
        '\x1bP1+r${hex('RGB')}=${hex('8/8/8')}\x1b\\',
      ]);
    });

    test('reports unknown capabilities as invalid (0+r)', () {
      final responses = <String>[];
      // TN (terminal name) is host/TERM-defined and intentionally not answered.
      Terminal()
        ..onOutput = responses.add
        ..write('\x1bP+q${hex('TN')}\x1b\\');

      expect(responses, ['\x1bP0+r${hex('TN')}\x1b\\']);
    });

    test('answers each capability in a multi-cap request', () {
      final responses = <String>[];
      Terminal()
        ..onOutput = responses.add
        ..write('\x1bP+q${hex('Co')};${hex('bogus')}\x1b\\');

      expect(responses, [
        '\x1bP1+r${hex('Co')}=${hex('256')}\x1b\\',
        '\x1bP0+r${hex('bogus')}\x1b\\',
      ]);
    });

    test('a non-XTGETTCAP DCS is consumed without leaking as text', () {
      final responses = <String>[];
      // DECRQSS-style DCS ($q) must not emit a reply nor render its body.
      final terminal = Terminal()
        ..onOutput = responses.add
        ..write('\x1bP\$q m\x1b\\');

      expect(responses, isEmpty);
      expect(terminal.buffer.getText().trim(), isEmpty);
    });
  });
}
