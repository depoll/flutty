import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('input methods notify listeners after emitting output', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    var notifications = 0;
    terminal.addListener(() => notifications++);

    expect(terminal.keyInput(TerminalKey.enter), isTrue);
    terminal.textInput('a');
    expect(terminal.charInput('a'.codeUnitAt(0), ctrl: true), isTrue);

    expect(output, ['\r', 'a', '\x01']);
    expect(notifications, 3);
  });

  test('paste strips controls and normalizes line endings', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.paste(
      'a\x07\x0cb\x1b[7mc\x1b[200~d\x1b[?25le'
      '\x1b]52;c;AAAA\x07f\x1b_Ga=d\x1b\\g\x1bh\r\nh\ri\n',
    );

    expect(output, ['abcdefg\rh\ri\r']);
  });

  test('bracketed paste wraps sanitized text', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?2004h');
    terminal.paste('a\nb');

    expect(output, ['\x1b[200~a\rb\x1b[201~']);
  });

  test('shift enter emits a newline', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    expect(terminal.keyInput(TerminalKey.enter, shift: true), isTrue);

    expect(output, ['\n']);
  });
}
