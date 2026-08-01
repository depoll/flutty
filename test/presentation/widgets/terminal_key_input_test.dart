import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_key_input.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('sendTerminalEnterInput', () {
    test('plain Enter matches keyInput', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );

      expect(output, ['\r']);
    });

    test('Shift+Enter matches keyInput newline encoding', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: true,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );

      // Legacy keytab: Enter+Shift → LF (newline without submit).
      expect(output, ['\n']);
    });

    test('plain Enter under LNM collapses CRLF only on the Enter path', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[20h');

      expect(terminal.lineFeedMode, isTrue);
      expect(terminal.keyInput(TerminalKey.enter), isTrue);
      expect(output, ['\r\n']);
      output.clear();

      // Paste of a single newline under LNM also emits exact CRLF — that must
      // not be rewritten by sendTerminalEnterInput's Enter-only collapse.
      terminal.paste('\n');
      expect(output, ['\r\n']);
      output.clear();

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\r']);
    });

    test('Alt+Enter applies meta-sends-escape when keytab drops Alt', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(terminal.keyInput(TerminalKey.enter, alt: true), isTrue);
      expect(output, ['\r']);
      output.clear();

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\x1b\r']);
    });

    test('uses Kitty keyboard encoding when mode is active', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[>1u');

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: true,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );

      expect(output, ['\x1b[13;2u']);
    });

    test('Kitty report-all mode encodes plain Enter as CSI-u', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[>9u');

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\x1b[13u']);
    });

    test('Kitty Alt+Enter keeps CSI-u encoding', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[>1u');

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\x1b[13;3u']);
    });

    test('ignores non-press Enter events outside Kitty keyboard mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: true,
          altActive: false,
          ctrlActive: false,
          type: TerminalKeyEventType.repeat,
        ),
        isFalse,
      );
      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
          type: TerminalKeyEventType.release,
        ),
        isFalse,
      );

      expect(output, isEmpty);
    });
  });
}
