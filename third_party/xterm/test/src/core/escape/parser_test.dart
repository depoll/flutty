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
  });
}
