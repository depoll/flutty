// Adapted from package:xterm 4.0.0 TerminalPainter so MonkeySSH can apply
// local terminal color fixes while preserving upstream layout behavior.
// ignore_for_file: implementation_imports, public_member_api_docs, directives_ordering, always_put_required_named_parameters_first, use_if_null_to_convert_nulls_to_bools, avoid_bool_literals_in_conditional_expressions

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

const _minimumReadableTerminalContrast = 2.0;

/// Encapsulates the logic for painting MonkeySSH terminal elements.
///
/// This mirrors xterm's [TerminalPainter], with an additional contrast guard for
/// very low-contrast foregrounds. Some TUIs emit truecolor or fixed 256-color
/// whites that bypass the theme's ANSI white remapping; on light terminal
/// themes those colors can become white-on-white. The guard only adjusts colors
/// that are unreadable against the cell's actual background.
class MonkeyTerminalPainter {
  MonkeyTerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  }) : _textStyle = textStyle,
       _theme = theme,
       _textScaler = textScaler;

  late var _colorPalette = PaletteBuilder(_theme).build();

  late var _cellSize = _measureCharSize();

  final _paragraphCache = ParagraphCache(10240);

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.noScaling;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle())
      ..pushStyle(textStyle.getTextStyle(textScaler: _textScaler))
      ..addText(test);

    final paragraph = builder.build()
      ..layout(const ParagraphConstraints(width: double.infinity));
    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );
    paragraph.dispose();
    return result;
  }

  Size get cellSize => _cellSize;

  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, _cellSize.height - 1),
          Offset(offset.dx + _cellSize.width, _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, 0),
          Offset(offset.dx, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset = offset.translate(
      length * _cellSize.width,
      _cellSize.height,
    );

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(Rect.fromPoints(offset, endOffset), paint);
  }

  void paintLine(Canvas canvas, Offset offset, BufferLine line) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      paintCell(canvas, cellOffset, cellData);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;
      var color = resolveCellForegroundColor(cellData);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withValues(alpha: color.a * 0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  @pragma('vm:prefer-inline')
  Color resolveCellForegroundColor(CellData cellData) {
    final foreground = cellData.flags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);
    final background = cellData.flags & CellFlags.inverse == 0
        ? resolveBackgroundColor(cellData.background)
        : resolveForegroundColor(cellData.foreground);
    return resolveReadableTerminalForegroundColor(
      foreground: foreground,
      background: background,
      fallback: _theme.foreground,
    );
  }

  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}

/// Returns a readable foreground for [background] when the requested color is
/// effectively invisible.
Color resolveReadableTerminalForegroundColor({
  required Color foreground,
  required Color background,
  required Color fallback,
}) {
  if (_contrastRatio(foreground, background) >=
      _minimumReadableTerminalContrast) {
    return foreground;
  }

  if (_contrastRatio(fallback, background) >=
      _minimumReadableTerminalContrast) {
    return fallback;
  }

  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  return _contrastRatio(black, background) >= _contrastRatio(white, background)
      ? black
      : white;
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final brightest = math.max(firstLuminance, secondLuminance);
  final darkest = math.min(firstLuminance, secondLuminance);
  return (brightest + 0.05) / (darkest + 0.05);
}
