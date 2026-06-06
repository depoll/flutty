import 'package:xterm/src/utils/hash_values.dart';

class CellData {
  CellData({
    required this.foreground,
    required this.background,
    required this.flags,
    required this.content,
  });

  factory CellData.empty() {
    return CellData(
      foreground: 0,
      background: 0,
      flags: 0,
      content: 0,
    );
  }

  int foreground;

  int background;

  int flags;

  int content;

  int getHash() {
    return hashValues(foreground, background, flags, content);
  }

  @override
  String toString() {
    return 'CellData{foreground: $foreground, background: $background, flags: $flags, content: $content}';
  }
}

abstract class CellAttr {
  static const bold = 1 << 0;
  static const faint = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const blink = 1 << 4;
  static const inverse = 1 << 5;
  static const invisible = 1 << 6;
  static const strikethrough = 1 << 7;

  // Underline style occupies bits 8..10 and holds an [UnderlineStyle] index.
  // Must stay in sync with [CellFlags] in cell_flags.dart, which is the
  // painter-facing view of the same attribute integer.
  static const underlineStyleShift = 8;
  static const underlineStyleMask = 7 << underlineStyleShift;

  static const overline = 1 << 11;
}

/// Visual style of an underline, matching the values used by the `CSI 4 : x m`
/// SGR sub-parameter in xterm.js.
enum UnderlineStyle {
  none,
  single,
  double,
  curly,
  dotted,
  dashed,
}

abstract class CellColor {
  static const valueMask = 0xFFFFFF;

  static const typeShift = 25;
  static const typeMask = 3 << typeShift;

  static const normal = 0 << typeShift;
  static const named = 1 << typeShift;
  static const palette = 2 << typeShift;
  static const rgb = 3 << typeShift;
}

abstract class CellContent {
  static const codepointMask = 0x1fffff;

  static const widthShift = 22;
  // static const widthMask = 3 << widthShift;
}
