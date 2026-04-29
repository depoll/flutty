// ignore_for_file: implementation_imports, public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as app_themes;
import 'package:monkeyssh/presentation/widgets/monkey_terminal_painter.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';

void main() {
  group('MonkeyTerminalPainter', () {
    test(
      'uses terminal foreground for unreadable truecolor on light theme',
      () {
        final theme = app_themes.TerminalThemes.cleanWhite.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(),
          textScaler: TextScaler.noScaling,
        );
        final cellData = CellData(
          foreground: CellColor.rgb | 0xFFFFFF,
          background: CellColor.normal,
          flags: 0,
          content: 0x78,
        );

        expect(painter.resolveCellForegroundColor(cellData), theme.foreground);
      },
    );

    test(
      'preserves truecolor foreground on contrasting explicit background',
      () {
        final theme = app_themes.TerminalThemes.cleanWhite.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(),
          textScaler: TextScaler.noScaling,
        );
        final cellData = CellData(
          foreground: CellColor.rgb | 0xFFFFFF,
          background: CellColor.rgb | 0x000000,
          flags: 0,
          content: 0x78,
        );

        expect(
          painter.resolveCellForegroundColor(cellData),
          const Color(0xFFFFFFFF),
        );
      },
    );

    test('preserves readable truecolor foreground on light theme', () {
      final theme = app_themes.TerminalThemes.cleanWhite.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final cellData = CellData(
        foreground: CellColor.rgb | 0x0969DA,
        background: CellColor.normal,
        flags: 0,
        content: 0x78,
      );

      expect(
        painter.resolveCellForegroundColor(cellData),
        const Color(0xFF0969DA),
      );
    });
  });
}
