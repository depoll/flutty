import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}

Color _rawRgbaPixel(ByteData data, int width, int x, int y) {
  final offset = ((y * width) + x) * 4;
  return Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

void main() {
  group('resolveTerminalRenderPadding', () {
    test('keeps portrait terminal rendering edge-to-edge', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 34),
      );

      expect(resolveTerminalRenderPadding(mediaQuery), EdgeInsets.zero);
    });

    test('stays edge-to-edge in portrait when the keyboard is visible', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 0),
        viewPadding: EdgeInsets.fromLTRB(12, 18, 16, 34),
        viewInsets: EdgeInsets.fromLTRB(0, 0, 0, 320),
      );

      expect(resolveTerminalRenderPadding(mediaQuery), EdgeInsets.zero);
    });

    test(
      'stays edge-to-edge when the keyboard shrinks a portrait viewport',
      () {
        const mediaQuery = MediaQueryData(
          size: Size(390, 524),
          padding: EdgeInsets.fromLTRB(12, 18, 16, 0),
          viewPadding: EdgeInsets.fromLTRB(12, 18, 16, 34),
          viewInsets: EdgeInsets.fromLTRB(0, 0, 0, 320),
        );

        expect(resolveTerminalRenderPadding(mediaQuery), EdgeInsets.zero);
      },
    );

    test('keeps horizontal cutout padding in landscape', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
        viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.only(left: 44, right: 34),
      );
    });

    test('uses landscape safe-area insets from viewPadding', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.only(left: 44, right: 34),
      );
    });

    test(
      'prefers larger landscape insets when padding exceeds viewPadding',
      () {
        const mediaQuery = MediaQueryData(
          size: Size(844, 390),
          padding: EdgeInsets.fromLTRB(72, 0, 54, 0),
          viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
          viewInsets: EdgeInsets.only(bottom: 200),
        );

        expect(
          resolveTerminalRenderPadding(mediaQuery),
          const EdgeInsets.only(left: 72, right: 54),
        );
      },
    );
  });

  group('resolveTerminalViewportPadding', () {
    test('keeps portrait viewport padding edge-to-edge', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 34),
      );

      expect(
        resolveTerminalViewportPadding(
          mediaQuery,
          basePadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        ),
        const EdgeInsets.fromLTRB(0, 8, 0, 0),
      );
    });

    test('keeps landscape viewport inside the horizontal safe area', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalViewportPadding(
          mediaQuery,
          basePadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        ),
        const EdgeInsets.fromLTRB(44, 8, 34, 0),
      );
    });
  });

  group('landscape terminal alignment', () {
    test('keeps trailing-edge alignment enabled in landscape', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        viewInsets: EdgeInsets.only(bottom: 200),
      );

      expect(shouldAlignTerminalToTrailingEdges(mediaQuery), isTrue);
    });

    test('shifts partial-cell slack to the leading and top edges', () {
      expect(
        resolveTerminalContentOrigin(
          viewportSize: const Size(844, 390),
          cellSize: const Size(10, 20),
          columns: 70,
          rows: 18,
          padding: const EdgeInsets.only(left: 72, right: 54),
          alignToTrailingEdges: true,
        ),
        const Offset(90, 30),
      );
    });

    test('keeps portrait content anchored to the origin', () {
      expect(
        resolveTerminalContentOrigin(
          viewportSize: const Size(390, 844),
          cellSize: const Size(10, 20),
          columns: 39,
          rows: 42,
        ),
        Offset.zero,
      );
    });
  });

  group('resolveTerminalHorizontalFillScale', () {
    test('fills the final horizontal remainder without shrinking', () {
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 9.5,
          columns: 40,
        ),
        closeTo(1.0263, 0.0001),
      );
    });

    test('returns 1 for invalid dimensions', () {
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 0,
          cellWidth: 9.5,
          columns: 40,
        ),
        1,
      );
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 0,
          columns: 40,
        ),
        1,
      );
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 9.5,
          columns: 0,
        ),
        1,
      );
    });
  });

  group('resolveTerminalResizePixelDimensions', () {
    test('reports the padded terminal viewport in pixels', () {
      expect(
        resolveTerminalResizePixelDimensions(
          viewportSize: const Size(390.4, 844.6),
          padding: const EdgeInsets.fromLTRB(4.2, 8.8, 5.4, 10.1),
        ),
        (width: 381, height: 826),
      );
    });

    test('clamps fully padded viewports to zero', () {
      expect(
        resolveTerminalResizePixelDimensions(
          viewportSize: const Size(10, 12),
          padding: const EdgeInsets.all(20),
        ),
        (width: 0, height: 0),
      );
    });
  });

  group('text attribute rendering', () {
    test('conceal (SGR 8) does not draw the glyph', () async {
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();

      Future<int> foregroundPixels(String sequence) async {
        final terminal = Terminal()
          ..resize(1, 1)
          ..write(sequence);
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        final width = painter.cellSize.width.ceil();
        final height = painter.cellSize.height.ceil();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint()..color = theme.background,
          );

        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

        final image = await recorder.endRecording().toImage(width, height);
        final byteData = (await image.toByteData())!;
        var count = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            if (_rawRgbaPixel(byteData, width, x, y) != theme.background) {
              count++;
            }
          }
        }
        return count;
      }

      final visible = await foregroundPixels('\x1b[37mM');
      final concealed = await foregroundPixels('\x1b[37;8mM');

      expect(visible, greaterThan(0), reason: 'visible glyph should be drawn');
      expect(concealed, 0, reason: 'concealed glyph should not be drawn');
    });
  });

  group('explicit cell background rendering', () {
    test(
      'clears normal-background cells before drawing terminal rows',
      () async {
        final terminal = Terminal()..resize(8, 1);
        final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        final cellSize = painter.cellSize;
        final imageWidth = (cellSize.width * 8).ceil();
        final imageHeight = cellSize.height.ceil();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
            Paint()..color = const Color(0xFFFF0000),
          );

        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

        final image = await recorder.endRecording().toImage(
          imageWidth,
          imageHeight,
        );
        final byteData = await image.toByteData();
        expect(byteData, isNotNull);

        final sample = _rawRgbaPixel(
          byteData!,
          imageWidth,
          imageWidth ~/ 2,
          imageHeight ~/ 2,
        );
        expect(sample, theme.background);
      },
    );

    test('keeps bright-black rows readable on the light theme', () {
      final background = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: TerminalThemes.defaultLightTheme.foreground,
        background: TerminalThemes.defaultLightTheme.brightBlack,
        terminalBackground: TerminalThemes.defaultLightTheme.background,
      );

      expect(
        _contrastRatio(TerminalThemes.defaultLightTheme.foreground, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(background, TerminalThemes.defaultLightTheme.background),
        greaterThanOrEqualTo(1.04),
      );
      expect(background, isNot(TerminalThemes.defaultLightTheme.brightBlack));
      expect(
        background.computeLuminance(),
        greaterThan(
          TerminalThemes.defaultLightTheme.brightBlack.computeLuminance(),
        ),
      );
    });

    test('keeps bright-black backgrounds readable across built-in themes', () {
      for (final themeData in TerminalThemes.all) {
        final theme = themeData.toXtermTheme();
        final background = resolveMonkeyTerminalReadableBackgroundColor(
          foreground: theme.foreground,
          background: theme.brightBlack,
          terminalBackground: theme.background,
        );
        final foreground = resolveMonkeyTerminalReadableForegroundColor(
          foreground: theme.foreground,
          background: background,
          terminalForeground: theme.foreground,
          terminalBackground: theme.background,
        );

        expect(
          _contrastRatio(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: themeData.id,
        );
      }
    });

    test('tones neutral truecolor backgrounds on dark themes', () {
      const theme = TerminalThemes.defaultDarkTheme;
      const geminiBackground = Color(0xFF5F5F5F);
      const typedForeground = Color(0xFFFFFFFF);
      final background = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: typedForeground,
        background: geminiBackground,
        terminalBackground: theme.background,
      );

      expect(background, isNot(geminiBackground));
      expect(
        _contrastRatio(typedForeground, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(background, theme.background),
        lessThanOrEqualTo(1.75),
      );
    });

    test('keeps Gemini neutral rows consistent across composer text', () {
      const theme = TerminalThemes.defaultDarkTheme;
      const geminiBackground = Color(0xFF5F5F5F);
      const promptAccent = Color(0xFFFF87AF);
      const placeholderForeground = Color(0xFFAFAFAF);
      const typedForeground = Color(0xFFFFFFFF);

      final accentBackground = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: promptAccent,
        background: geminiBackground,
        terminalBackground: theme.background,
      );
      final typedBackground = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: typedForeground,
        background: geminiBackground,
        terminalBackground: theme.background,
      );
      final placeholderBackground =
          resolveMonkeyTerminalReadableBackgroundColor(
            foreground: placeholderForeground,
            background: geminiBackground,
            terminalBackground: theme.background,
          );

      expect(accentBackground, typedBackground);
      expect(accentBackground, placeholderBackground);
      expect(
        _contrastRatio(placeholderForeground, placeholderBackground),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('keeps readable semantic truecolor backgrounds unchanged', () {
      const semanticBackground = Color(0xFFA82F45);
      const foreground = Color(0xFFFFFFFF);
      final background = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: foreground,
        background: semanticBackground,
        terminalBackground: TerminalThemes.defaultDarkTheme.background,
      );

      expect(background, semanticBackground);
    });

    test(
      'paints Claude logo block cells as solid terminal rectangles',
      () async {
        const claudePink = Color(0xFFD77757);
        const logoBlack = Color(0xFF000000);
        final terminal = Terminal()
          ..resize(12, 2)
          ..write('\x1b[38;2;215;119;87m ▐\x1b[48;2;0;0;0m▛███▜\x1b[49m▌');
        final theme = TerminalThemes.defaultLightTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 32),
          textScaler: TextScaler.noScaling,
        );
        final cellSize = painter.cellSize;
        final imageWidth = (cellSize.width * 12).ceil() + 2;
        final imageHeight = cellSize.height.ceil() + 2;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
            Paint()..color = theme.background,
          );
        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);
        final image = await recorder.endRecording().toImage(
          imageWidth,
          imageHeight,
        );
        final byteData = await image.toByteData();
        expect(byteData, isNotNull);

        Color sample(double x, double y) => _rawRgbaPixel(
          byteData!,
          imageWidth,
          math.max(0, math.min(imageWidth - 1, x.round())),
          math.max(0, math.min(imageHeight - 1, y.round())),
        );

        expect(
          sample((cellSize.width * 3) + 1, cellSize.height / 2),
          claudePink,
        );
        expect(
          sample(
            (cellSize.width * 3) + cellSize.width - 1,
            cellSize.height / 2,
          ),
          claudePink,
        );
        expect(
          sample((cellSize.width * 2) + (cellSize.width * 0.25), 1),
          claudePink,
        );
        expect(
          sample(
            (cellSize.width * 2) + (cellSize.width * 0.75),
            cellSize.height * 0.75,
          ),
          logoBlack,
        );
      },
    );

    test('extends left-edge highlighted rows to line end', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[100m> fix contrast\x1b[49m');
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultLightTheme.toXtermTheme(),
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );

      final fill = painter.resolveMonkeyTerminalTrailingBackgroundFill(
        terminal.buffer.lines[0],
      );

      expect(fill, isNotNull);
      expect(fill!.startColumn, '> fix contrast'.length);
      expect(
        _contrastRatio(TerminalThemes.defaultLightTheme.foreground, fill.color),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('extends neutral truecolor composer rows to line end', () {
      const neutralBackground = Color(0xFF5F5F5F);
      final terminal = Terminal()
        ..resize(32, 2)
        ..write('\x1b[48;2;95;95;95mAsk Codex\x1b[49m');
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultDarkTheme.toXtermTheme(),
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );

      final fill = painter.resolveMonkeyTerminalTrailingBackgroundFill(
        terminal.buffer.lines[0],
      );

      expect(fill, isNotNull);
      expect(fill!.startColumn, 'Ask Codex'.length);
      expect(fill.color, isNot(neutralBackground));
      expect(
        _contrastRatio(fill.color, TerminalThemes.defaultDarkTheme.background),
        inInclusiveRange(1.04, 1.75),
      );
    });

    test(
      'extends neutral truecolor composer rows after blank leading cells',
      () {
        final terminal = Terminal()
          ..resize(32, 2)
          ..write('\x1b[2C\x1b[48;2;95;95;95mAsk Codex\x1b[49m');
        final painter = MonkeyTerminalPainter(
          theme: TerminalThemes.defaultDarkTheme.toXtermTheme(),
          textStyle: const TerminalStyle(),
          textScaler: TextScaler.noScaling,
        );

        final fill = painter.resolveMonkeyTerminalTrailingBackgroundFill(
          terminal.buffer.lines[0],
        );

        expect(fill, isNotNull);
        expect(fill!.startColumn, 2 + 'Ask Codex'.length);
      },
    );

    test('does not extend inset highlighted runs', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('x \x1b[100mstatus\x1b[49m');
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultLightTheme.toXtermTheme(),
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );

      expect(
        painter.resolveMonkeyTerminalTrailingBackgroundFill(
          terminal.buffer.lines[0],
        ),
        isNull,
      );
    });

    test('does not extend semantic color labels', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[41mERROR\x1b[49m');
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultLightTheme.toXtermTheme(),
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );

      expect(
        painter.resolveMonkeyTerminalTrailingBackgroundFill(
          terminal.buffer.lines[0],
        ),
        isNull,
      );
    });

    test('does not extend saturated truecolor labels', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[48;2;168;47;69mERROR\x1b[49m');
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultLightTheme.toXtermTheme(),
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );

      expect(
        painter.resolveMonkeyTerminalTrailingBackgroundFill(
          terminal.buffer.lines[0],
        ),
        isNull,
      );
    });

    test('lifts low-contrast foreground-only ANSI colors', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[90mforeground only');
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final cellData = CellData.empty();
      terminal.buffer.lines[0].getCellData(0, cellData);

      final foreground = painter.resolveMonkeyTerminalCellForegroundColor(
        cellData,
      );

      expect(
        _contrastRatio(foreground, theme.background),
        greaterThanOrEqualTo(4.5),
      );
      expect(foreground, isNot(theme.brightBlack));
    });

    test('keeps readable foreground-only ANSI colors unchanged', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[96mforeground only');
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final cellData = CellData.empty();
      terminal.buffer.lines[0].getCellData(0, cellData);

      expect(
        painter.resolveMonkeyTerminalCellForegroundColor(cellData),
        theme.brightCyan,
      );
    });
  });
}
