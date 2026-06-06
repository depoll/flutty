import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('CursorStyle underline styles', () {
    test('setUnderlineStyle stores the style and sets the underline bit', () {
      final style = CursorStyle();
      style.setUnderlineStyle(UnderlineStyle.curly);

      expect(style.underlineStyle, UnderlineStyle.curly);
      expect(style.attrs & CellFlags.underline, isNot(0));
      final index = (style.attrs & CellFlags.underlineStyleMask) >>
          CellFlags.underlineStyleShift;
      expect(index, UnderlineStyle.curly.index);
    });

    test('setUnderlineStyle(none) clears the underline', () {
      final style = CursorStyle()..setUnderlineStyle(UnderlineStyle.dashed);
      style.setUnderlineStyle(UnderlineStyle.none);

      expect(style.underlineStyle, UnderlineStyle.none);
      expect(style.attrs & CellFlags.underline, 0);
      expect(style.attrs & CellFlags.underlineStyleMask, 0);
    });

    test('legacy setUnderline reports a single style', () {
      final style = CursorStyle()..setUnderlineStyle(UnderlineStyle.curly);
      // A following plain underline should reset the style back to single.
      style.setUnderline();

      expect(style.underlineStyle, UnderlineStyle.single);
      expect(style.attrs & CellFlags.underlineStyleMask, 0);
    });

    test('unsetUnderline clears both the bit and the style field', () {
      final style = CursorStyle()..setUnderlineStyle(UnderlineStyle.dotted);
      style.unsetUnderline();

      expect(style.underlineStyle, UnderlineStyle.none);
      expect(style.attrs & CellFlags.underlineStyleMask, 0);
    });
  });

  group('CursorStyle overline and strikethrough', () {
    test('overline can be toggled', () {
      final style = CursorStyle()..setOverline();
      expect(style.isOverline, isTrue);
      expect(style.attrs & CellFlags.overline, isNot(0));

      style.unsetOverline();
      expect(style.isOverline, isFalse);
      expect(style.attrs & CellFlags.overline, 0);
    });

    test('strikethrough bit is visible to the painter flags', () {
      final style = CursorStyle()..setStrikethrough();
      expect(style.isStrikethrough, isTrue);
      expect(style.attrs & CellFlags.strikethrough, isNot(0));
    });
  });

  group('CellAttr and CellFlags layout', () {
    test('attribute bit positions stay in sync', () {
      expect(CellAttr.bold, CellFlags.bold);
      expect(CellAttr.faint, CellFlags.faint);
      expect(CellAttr.italic, CellFlags.italic);
      expect(CellAttr.underline, CellFlags.underline);
      expect(CellAttr.blink, CellFlags.blink);
      expect(CellAttr.inverse, CellFlags.inverse);
      expect(CellAttr.invisible, CellFlags.invisible);
      expect(CellAttr.strikethrough, CellFlags.strikethrough);
      expect(CellAttr.underlineStyleShift, CellFlags.underlineStyleShift);
      expect(CellAttr.underlineStyleMask, CellFlags.underlineStyleMask);
      expect(CellAttr.overline, CellFlags.overline);
    });

    test('underline style field does not collide with other flags', () {
      const otherFlags = CellFlags.bold |
          CellFlags.faint |
          CellFlags.italic |
          CellFlags.underline |
          CellFlags.blink |
          CellFlags.inverse |
          CellFlags.invisible |
          CellFlags.strikethrough |
          CellFlags.overline;
      expect(CellFlags.underlineStyleMask & otherFlags, 0);
    });
  });
}
