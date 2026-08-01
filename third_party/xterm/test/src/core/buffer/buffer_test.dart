import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('Buffer.getText()', () {
    test('should return the text', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.getText(), startsWith('Hello World'));
    });

    test('can handle line wrap', () {
      final terminal = Terminal();
      terminal.resize(10, 10);

      final line1 = 'This is a long line that should wrap';
      final line2 = 'This is a short line';
      final line3 = 'This is a long long long long line that should wrap';
      final line4 = 'Short';

      terminal.write('$line1\r\n');
      terminal.write('$line2\r\n');
      terminal.write('$line3\r\n');
      terminal.write('$line4\r\n');

      final lines = terminal.buffer.getText().split('\n');
      expect(lines[0], line1);
      expect(lines[1], line2);
      expect(lines[2], line3);
      expect(lines[3], line4);
    });

    test('can handle negative start', () {
      final terminal = Terminal();

      terminal.write('Hello World');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(-100, -100), CellOffset(100, 100)),
        ),
        startsWith('Hello World'),
      );
    });

    test('can handle invalid end', () {
      final terminal = Terminal();

      terminal.write('Hello World');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(0, 0), CellOffset(100, 100)),
        ),
        startsWith('Hello World'),
      );
    });

    test('can handle reversed range', () {
      final terminal = Terminal();

      terminal.write('Hello World');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(5, 5), CellOffset(0, 0)),
        ),
        startsWith('Hello World'),
      );
    });

    test('can handle block range', () {
      final terminal = Terminal();

      terminal.write('Hello World\r\n');
      terminal.write('Nice to meet you\r\n');

      expect(
        terminal.buffer.getText(
          BufferRangeBlock(CellOffset(2, 0), CellOffset(5, 1)),
        ),
        startsWith('llo\nce '),
      );
    });
  });

  group('Buffer.resize()', () {
    test('should resize the buffer', () {
      final terminal = Terminal();
      terminal.resize(10, 10);

      expect(terminal.viewWidth, 10);
      expect(terminal.viewHeight, 10);

      for (var i = 0; i < terminal.lines.length; i++) {
        final line = terminal.lines[i];
        expect(line.length, 10);
      }

      terminal.resize(20, 20);

      expect(terminal.viewWidth, 20);
      expect(terminal.viewHeight, 20);

      for (var i = 0; i < terminal.lines.length; i++) {
        final line = terminal.lines[i];
        expect(line.length, 20);
      }
    });

    test('preserves rows below the cursor when shrinking (TUI footer)', () {
      // Full-screen TUIs such as Copilot CLI park the cursor on their input
      // line and keep live status rows below it. A height shrink must not
      // destroy those rows: the program still owns them and repaints with
      // cursor-relative movements, so deleting them desynchronizes every
      // later repaint. On the alt buffer, rows shed to make room must come
      // from the top (as xterm.js does), never from below the cursor.
      final terminal = Terminal();
      terminal.resize(10, 10);
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 10; i++) {
        terminal.write('\x1b[${i + 1};1HL$i');
      }
      terminal.write('\x1b[8;1H'); // cursor on row index 7, above L8/L9

      terminal.resize(10, 6);

      final buffer = terminal.buffer;
      expect(buffer.height, 6);
      for (var i = 0; i < 6; i++) {
        expect(buffer.lines[i].getText(), 'L${i + 4}');
      }
      // The cursor stays on its own line, with the footer intact below it.
      expect(buffer.lines[buffer.absoluteCursorY].getText(), 'L7');
      expect(buffer.lines[buffer.absoluteCursorY + 1].getText(), 'L8');
      expect(buffer.lines[buffer.absoluteCursorY + 2].getText(), 'L9');

      terminal.resize(10, 10);

      expect(buffer.height, 10);
      for (var i = 0; i < 6; i++) {
        expect(buffer.lines[i].getText(), 'L${i + 4}');
      }
      expect(buffer.lines[buffer.absoluteCursorY].getText(), 'L7');
    });

    test('round-trips a keyboard-animation resize flurry losslessly', () {
      // A mobile on-screen keyboard animates the viewport through many
      // intermediate heights. On the main buffer, replaying such a flurry
      // must return the exact original screen once the keyboard closes.
      final terminal = Terminal();
      terminal.resize(69, 55);
      for (var i = 0; i < 55; i++) {
        terminal.write('\x1b[${i + 1};1Htranscript row $i');
      }
      terminal.write('\x1b[53;1H'); // input line with two footer rows below

      final before = [
        for (var i = 0; i < terminal.buffer.height; i++)
          terminal.buffer.lines[i].getText(),
      ];
      final cursorRowBefore = terminal.buffer.absoluteCursorY;

      for (final rows in [41, 34, 33, 30, 29, 28, 29, 38, 50, 54, 55]) {
        terminal.resize(69, rows);
      }

      final buffer = terminal.buffer;
      expect(buffer.height, before.length);
      expect(buffer.scrollBack, 0);
      for (var i = 0; i < before.length; i++) {
        expect(buffer.lines[i].getText(), before[i]);
      }
      expect(buffer.absoluteCursorY, cursorRowBefore);
    });

    test('reclaims trailing blank rows instead of creating scrollback', () {
      // A shell with a prompt at the top and nothing below it should not have
      // its blank region converted into scrollback lines on shrink.
      final terminal = Terminal();
      terminal.resize(10, 10);
      terminal.write('user@host>');
      terminal.write('\x1b[1;1H');

      terminal.resize(10, 5);

      final buffer = terminal.buffer;
      expect(buffer.height, 5);
      expect(buffer.scrollBack, 0);
      expect(buffer.lines[0].getText(), 'user@host>');
      expect(buffer.absoluteCursorY, 0);
    });

    test('does not reclaim rows whose text is hidden by a width shrink', () {
      // With reflow off, a width shrink retains the cells past the new width
      // so they reappear when the width grows back. A row whose only text
      // lives in that hidden range must not be read as blank and destroyed by
      // a later height shrink.
      final terminal = Terminal(reflowEnabled: false);
      terminal.resize(10, 10);
      terminal.write('\x1b[6;7HTAIL'); // row index 5, columns 6-9
      terminal.write('\x1b[3;1H'); // cursor on row index 2

      terminal.resize(6, 10); // hides TAIL beyond column 5
      terminal.resize(6, 5); // must not pop the row holding hidden cells
      terminal.resize(10, 5); // hidden cells reappear

      final buffer = terminal.buffer;
      expect(buffer.lines[5].getText(), 'TAIL');
      expect(buffer.lines[5].getTrimmedLength(), 10);
      expect(buffer.absoluteCursorY, 2);
    });

    test('does not reclaim rows holding image placement anchors', () {
      // A row whose only content is a Kitty image placement has no code
      // points, but popping it would detach the anchor and lose the image.
      final terminal = Terminal();
      terminal.resize(10, 10);
      terminal.write('\x1b[8;1H'); // cursor on row index 7

      final buffer = terminal.buffer;
      final anchor = buffer.createAnchor(0, 8);
      buffer.graphics.retainPendingPlacementAnchor(anchor);

      terminal.resize(10, 6);

      expect(anchor.attached, isTrue);
      expect(anchor.y, 8);
      expect(buffer.height, 9); // only the blank, unanchored row 9 was popped
      expect(buffer.absoluteCursorY, 7);
    });
  });

  group('Buffer.deleteLines()', () {
    test('works', () {
      final terminal = Terminal();
      terminal.resize(10, 10);

      for (var i = 1; i <= 10; i++) {
        terminal.write('line$i');

        if (i < 10) {
          terminal.write('\r\n');
        }
      }

      terminal.setMargins(3, 7);
      terminal.setCursor(0, 5);

      terminal.buffer.deleteLines(1);

      expect(terminal.buffer.lines[2].toString(), 'line3');
      expect(terminal.buffer.lines[3].toString(), 'line4');
      expect(terminal.buffer.lines[4].toString(), 'line5');
      expect(terminal.buffer.lines[5].toString(), 'line7');
      expect(terminal.buffer.lines[6].toString(), 'line8');
      expect(terminal.buffer.lines[7].toString(), '');
      expect(terminal.buffer.lines[8].toString(), 'line9');
      expect(terminal.buffer.lines[9].toString(), 'line10');
    });
  });

  group('Buffer.insertLines()', () {
    test('works', () {
      final terminal = Terminal();

      for (var i = 0; i < 10; i++) {
        terminal.write('line$i\r\n');
      }

      print(terminal.buffer);

      terminal.setMargins(2, 6);
      terminal.setCursor(0, 4);

      print(terminal.buffer.absoluteCursorY);

      terminal.buffer.insertLines(1);

      print(terminal.buffer);

      expect(terminal.buffer.lines[3].toString(), 'line3');
      expect(terminal.buffer.lines[4].toString(), ''); // inserted
      expect(terminal.buffer.lines[5].toString(), 'line4'); // moved
      expect(terminal.buffer.lines[6].toString(), 'line5'); // moved
      expect(terminal.buffer.lines[7].toString(), 'line7');
    });

    test('has no effect if cursor is out of scroll region', () {
      final terminal = Terminal();

      for (var i = 0; i < 10; i++) {
        terminal.write('line$i\r\n');
      }

      terminal.setMargins(2, 6);
      terminal.setCursor(0, 1);

      terminal.buffer.insertLines(1);

      expect(terminal.buffer.lines[2].toString(), 'line2');
      expect(terminal.buffer.lines[3].toString(), 'line3');
      expect(terminal.buffer.lines[4].toString(), 'line4');
      expect(terminal.buffer.lines[5].toString(), 'line5');
      expect(terminal.buffer.lines[6].toString(), 'line6');
      expect(terminal.buffer.lines[7].toString(), 'line7');
    });
  });

  group('Buffer.getWordBoundary supports custom word separators', () {
    test('can set word separators', () {
      final terminal = Terminal(wordSeparators: {'o'.codeUnitAt(0)});

      terminal.write('Hello World');

      expect(
        terminal.mainBuffer.getWordBoundary(CellOffset(0, 0)),
        BufferRangeLine(CellOffset(0, 0), CellOffset(4, 0)),
      );

      expect(
        terminal.mainBuffer.getWordBoundary(CellOffset(5, 0)),
        BufferRangeLine(CellOffset(5, 0), CellOffset(7, 0)),
      );
    });
  });

  test('does not delete lines beyond the scroll region', () {
    final terminal = Terminal();
    terminal.resize(10, 10);

    for (var i = 1; i <= 10; i++) {
      terminal.write('line$i');

      if (i < 10) {
        terminal.write('\r\n');
      }
    }

    terminal.setMargins(3, 7);
    terminal.setCursor(0, 5);

    terminal.buffer.deleteLines(20);

    expect(terminal.buffer.lines[2].toString(), 'line3');
    expect(terminal.buffer.lines[3].toString(), 'line4');
    expect(terminal.buffer.lines[4].toString(), 'line5');
    expect(terminal.buffer.lines[5].toString(), '');
    expect(terminal.buffer.lines[6].toString(), '');
    expect(terminal.buffer.lines[7].toString(), '');
    expect(terminal.buffer.lines[8].toString(), 'line9');
    expect(terminal.buffer.lines[9].toString(), 'line10');
  });

  group('Buffer.eraseDisplayFromCursor()', () {
    test('works', () {
      final terminal = Terminal();
      terminal.resize(3, 3);
      terminal.write('123\r\n456\r\n789');

      terminal.setCursor(1, 1);
      terminal.buffer.eraseDisplayFromCursor();

      expect(terminal.buffer.lines[0].toString(), '123');
      expect(terminal.buffer.lines[1].toString(), '4');
      expect(terminal.buffer.lines[2].toString(), '');
    });
  });
}
