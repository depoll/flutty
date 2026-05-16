import 'dart:math' as math;

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

  group('explicit cell background rendering', () {
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

    test('keeps foreground-only ANSI colors unchanged', () {
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

      expect(
        painter.resolveMonkeyTerminalCellForegroundColor(cellData),
        theme.brightBlack,
      );
    });
  });
}
