abstract class CellFlags {
  static const bold = 1 << 0;
  static const faint = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const blink = 1 << 4;
  static const inverse = 1 << 5;
  static const invisible = 1 << 6;
  static const strikethrough = 1 << 7;

  // Underline style occupies bits 8..10 and holds an [UnderlineStyle] index.
  // Must stay in sync with [CellAttr] in cell.dart.
  static const underlineStyleShift = 8;
  static const underlineStyleMask = 7 << underlineStyleShift;

  static const overline = 1 << 11;
}
