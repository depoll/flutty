import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
    });

    group('SGR extended color', () {
      test('legacy semicolon truecolor foreground', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38;2;255;128;0m');
        verify(parser.handler.setForegroundColorRgb(255, 128, 0));
      });

      test('legacy semicolon indexed background', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[48;5;160m');
        verify(parser.handler.setBackgroundColor256(160));
      });

      test('colon truecolor foreground with empty color space', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38:2::255:128:0m');
        verify(parser.handler.setForegroundColorRgb(255, 128, 0));
      });

      test('colon truecolor foreground without color space', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38:2:255:128:0m');
        verify(parser.handler.setForegroundColorRgb(255, 128, 0));
      });

      test('colon indexed foreground', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38:5:160m');
        verify(parser.handler.setForegroundColor256(160));
      });

      test('colon truecolor background with explicit color space id', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[48:2:1:10:20:30m');
        verify(parser.handler.setBackgroundColorRgb(10, 20, 30));
      });

      test('colon SGR does not bleed into following attributes', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[1;38:5:208;4m');
        verify(parser.handler.setCursorBold());
        verify(parser.handler.setForegroundColor256(208));
        verify(parser.handler.setCursorUnderline());
      });

      test('missing extended color arguments do not throw', () {
        final parser = EscapeParser(MockEscapeHandler());
        expect(() => parser.write('\x1b[38m'), returnsNormally);
        expect(() => parser.write('\x1b[48;2m'), returnsNormally);
        expect(() => parser.write('\x1b[38;5m'), returnsNormally);
        // Missing rgb arguments fall back to 0 instead of throwing.
        verify(parser.handler.setBackgroundColorRgb(0, 0, 0));
      });
    });

    group('SGR underline and overline', () {
      test('legacy single underline (4)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4m');
        verify(parser.handler.setCursorUnderline());
      });

      test('curly underline (4:3)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:3m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.curly));
      });

      test('dotted underline (4:4)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:4m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.dotted));
      });

      test('underline off via sub-parameter (4:0)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:0m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.none));
      });

      test('double underline (21)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[21m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.double));
      });

      test('22 clears both bold and faint', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[22m');
        verify(parser.handler.unsetCursorBold());
        verify(parser.handler.unsetCursorFaint());
      });

      test('overline on and off (53 / 55)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[53m');
        verify(parser.handler.setCursorOverline());
        parser.write('\x1b[55m');
        verify(parser.handler.unsetCursorOverline());
      });
    });

    group('SGR underline color', () {
      test('indexed underline color (58:5:n)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[58:5:160m');
        verify(parser.handler.setUnderlineColor256(160));
      });

      test('legacy indexed underline color (58;5;n)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[58;5;160m');
        verify(parser.handler.setUnderlineColor256(160));
      });

      test('truecolor underline color (58:2::r:g:b)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[58:2::10:20:30m');
        verify(parser.handler.setUnderlineColorRgb(10, 20, 30));
      });

      test('reset underline color (59)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[59m');
        verify(parser.handler.resetUnderlineColor());
      });

      test('combined curly underline with color does not bleed', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:3;58:2::255:0:0mX');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.curly));
        verify(parser.handler.setUnderlineColorRgb(255, 0, 0));
        verify(parser.handler.writeChar(0x58));
      });
    });
  });
}
