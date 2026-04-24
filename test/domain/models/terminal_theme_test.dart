import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}

Color _compositeOver(Color foreground, Color background) {
  final foregroundArgb = foreground.toARGB32();
  final backgroundArgb = background.toARGB32();
  final alpha = ((foregroundArgb >> 24) & 0xFF) / 255;
  final foregroundRed = (foregroundArgb >> 16) & 0xFF;
  final foregroundGreen = (foregroundArgb >> 8) & 0xFF;
  final foregroundBlue = foregroundArgb & 0xFF;
  final backgroundRed = (backgroundArgb >> 16) & 0xFF;
  final backgroundGreen = (backgroundArgb >> 8) & 0xFF;
  final backgroundBlue = backgroundArgb & 0xFF;
  return Color.fromARGB(
    0xFF,
    (foregroundRed * alpha + backgroundRed * (1 - alpha)).round(),
    (foregroundGreen * alpha + backgroundGreen * (1 - alpha)).round(),
    (foregroundBlue * alpha + backgroundBlue * (1 - alpha)).round(),
  );
}

void main() {
  group('TerminalThemeData', () {
    test('creates with required fields', () {
      const theme = TerminalThemeData(
        id: 'test-id',
        name: 'Test Theme',
        isDark: true,
        foreground: Color(0xFFFFFFFF),
        background: Color(0xFF000000),
        cursor: Color(0xFFFFFFFF),
        selection: Color(0x60FFFFFF),
        black: Color(0xFF000000),
        red: Color(0xFFFF0000),
        green: Color(0xFF00FF00),
        yellow: Color(0xFFFFFF00),
        blue: Color(0xFF0000FF),
        magenta: Color(0xFFFF00FF),
        cyan: Color(0xFF00FFFF),
        white: Color(0xFFFFFFFF),
        brightBlack: Color(0xFF808080),
        brightRed: Color(0xFFFF8080),
        brightGreen: Color(0xFF80FF80),
        brightYellow: Color(0xFFFFFF80),
        brightBlue: Color(0xFF8080FF),
        brightMagenta: Color(0xFFFF80FF),
        brightCyan: Color(0xFF80FFFF),
        brightWhite: Color(0xFFFFFFFF),
      );

      expect(theme.id, 'test-id');
      expect(theme.name, 'Test Theme');
      expect(theme.isDark, true);
      expect(theme.foreground, const Color(0xFFFFFFFF));
      expect(theme.background, const Color(0xFF000000));
    });

    test('toJson returns valid JSON map', () {
      const theme = TerminalThemeData(
        id: 'test-id',
        name: 'Test Theme',
        isDark: true,
        foreground: Color(0xFFFFFFFF),
        background: Color(0xFF000000),
        cursor: Color(0xFFFFFFFF),
        selection: Color(0x60FFFFFF),
        black: Color(0xFF000000),
        red: Color(0xFFFF0000),
        green: Color(0xFF00FF00),
        yellow: Color(0xFFFFFF00),
        blue: Color(0xFF0000FF),
        magenta: Color(0xFFFF00FF),
        cyan: Color(0xFF00FFFF),
        white: Color(0xFFFFFFFF),
        brightBlack: Color(0xFF808080),
        brightRed: Color(0xFFFF8080),
        brightGreen: Color(0xFF80FF80),
        brightYellow: Color(0xFFFFFF80),
        brightBlue: Color(0xFF8080FF),
        brightMagenta: Color(0xFFFF80FF),
        brightCyan: Color(0xFF80FFFF),
        brightWhite: Color(0xFFFFFFFF),
      );

      final json = theme.toJson();

      expect(json['id'], 'test-id');
      expect(json['name'], 'Test Theme');
      expect(json['isDark'], true);
      expect(json['foreground'], 0xFFFFFFFF);
    });

    test('fromJson creates theme from JSON map', () {
      final json = {
        'id': 'json-id',
        'name': 'JSON Theme',
        'isDark': false,
        'foreground': 0xFF000000,
        'background': 0xFFFFFFFF,
        'cursor': 0xFF000000,
        'selection': 0x60000000,
        'black': 0xFF000000,
        'red': 0xFFFF0000,
        'green': 0xFF00FF00,
        'yellow': 0xFFFFFF00,
        'blue': 0xFF0000FF,
        'magenta': 0xFFFF00FF,
        'cyan': 0xFF00FFFF,
        'white': 0xFFFFFFFF,
        'brightBlack': 0xFF808080,
        'brightRed': 0xFFFF8080,
        'brightGreen': 0xFF80FF80,
        'brightYellow': 0xFFFFFF80,
        'brightBlue': 0xFF8080FF,
        'brightMagenta': 0xFFFF80FF,
        'brightCyan': 0xFF80FFFF,
        'brightWhite': 0xFFFFFFFF,
      };

      final theme = TerminalThemeData.fromJson(json);

      expect(theme.id, 'json-id');
      expect(theme.name, 'JSON Theme');
      expect(theme.isDark, false);
    });

    test('toJson and fromJson are symmetric', () {
      const original = TerminalThemeData(
        id: 'roundtrip-id',
        name: 'Roundtrip Theme',
        isDark: true,
        foreground: Color(0xFFABCDEF),
        background: Color(0xFF123456),
        cursor: Color(0xFFFFFFFF),
        selection: Color(0x60FFFFFF),
        black: Color(0xFF000000),
        red: Color(0xFFFF0000),
        green: Color(0xFF00FF00),
        yellow: Color(0xFFFFFF00),
        blue: Color(0xFF0000FF),
        magenta: Color(0xFFFF00FF),
        cyan: Color(0xFF00FFFF),
        white: Color(0xFFFFFFFF),
        brightBlack: Color(0xFF808080),
        brightRed: Color(0xFFFF8080),
        brightGreen: Color(0xFF80FF80),
        brightYellow: Color(0xFFFFFF80),
        brightBlue: Color(0xFF8080FF),
        brightMagenta: Color(0xFFFF80FF),
        brightCyan: Color(0xFF80FFFF),
        brightWhite: Color(0xFFFFFFFF),
      );

      final json = original.toJson();
      final restored = TerminalThemeData.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.isDark, original.isDark);
      expect(restored.foreground, original.foreground);
      expect(restored.background, original.background);
    });

    test('copyWith creates new theme with modified fields', () {
      const original = TerminalThemeData(
        id: 'original-id',
        name: 'Original Theme',
        isDark: true,
        foreground: Color(0xFFFFFFFF),
        background: Color(0xFF000000),
        cursor: Color(0xFFFFFFFF),
        selection: Color(0x60FFFFFF),
        black: Color(0xFF000000),
        red: Color(0xFFFF0000),
        green: Color(0xFF00FF00),
        yellow: Color(0xFFFFFF00),
        blue: Color(0xFF0000FF),
        magenta: Color(0xFFFF00FF),
        cyan: Color(0xFF00FFFF),
        white: Color(0xFFFFFFFF),
        brightBlack: Color(0xFF808080),
        brightRed: Color(0xFFFF8080),
        brightGreen: Color(0xFF80FF80),
        brightYellow: Color(0xFFFFFF80),
        brightBlue: Color(0xFF8080FF),
        brightMagenta: Color(0xFFFF80FF),
        brightCyan: Color(0xFF80FFFF),
        brightWhite: Color(0xFFFFFFFF),
      );

      final modified = original.copyWith(
        id: 'modified-id',
        name: 'Modified Theme',
      );

      expect(modified.id, 'modified-id');
      expect(modified.name, 'Modified Theme');
      expect(modified.isDark, original.isDark);
      expect(modified.foreground, original.foreground);
    });

    test('toXtermTheme converts to xterm TerminalTheme', () {
      const theme = TerminalThemeData(
        id: 'xterm-test',
        name: 'Xterm Test',
        isDark: true,
        foreground: Color(0xFFFFFFFF),
        background: Color(0xFF000000),
        cursor: Color(0xFFFFFFFF),
        selection: Color(0x60FFFFFF),
        black: Color(0xFF000000),
        red: Color(0xFFFF0000),
        green: Color(0xFF00FF00),
        yellow: Color(0xFFFFFF00),
        blue: Color(0xFF0000FF),
        magenta: Color(0xFFFF00FF),
        cyan: Color(0xFF00FFFF),
        white: Color(0xFFFFFFFF),
        brightBlack: Color(0xFF808080),
        brightRed: Color(0xFFFF8080),
        brightGreen: Color(0xFF80FF80),
        brightYellow: Color(0xFFFFFF80),
        brightBlue: Color(0xFF8080FF),
        brightMagenta: Color(0xFFFF80FF),
        brightCyan: Color(0xFF80FFFF),
        brightWhite: Color(0xFFFFFFFF),
      );

      final xtermTheme = theme.toXtermTheme();

      expect(xtermTheme, isNotNull);
    });
  });

  group('TerminalThemes', () {
    test('all returns non-empty list', () {
      final themes = TerminalThemes.all;
      expect(themes, isNotEmpty);
    });

    test('darkThemes returns only dark themes', () {
      final themes = TerminalThemes.darkThemes;
      expect(themes, isNotEmpty);
      for (final theme in themes) {
        expect(theme.isDark, true);
      }
    });

    test('lightThemes returns only light themes', () {
      final themes = TerminalThemes.lightThemes;
      expect(themes, isNotEmpty);
      for (final theme in themes) {
        expect(theme.isDark, false);
      }
    });

    test('getById returns theme when exists', () {
      final theme = TerminalThemes.getById('midnight-purple');
      expect(theme, isNotNull);
      expect(theme!.id, 'midnight-purple');
      expect(theme.name, 'Midnight Purple');
    });

    test('getById returns null when not exists', () {
      final theme = TerminalThemes.getById('nonexistent-theme');
      expect(theme, isNull);
    });

    test('all themes have unique IDs', () {
      final themes = TerminalThemes.all;
      final ids = themes.map((t) => t.id).toSet();
      expect(ids.length, themes.length);
    });

    test('contains expected themes', () {
      expect(TerminalThemes.getById('midnight-purple'), isNotNull);
      expect(TerminalThemes.getById('clean-white'), isNotNull);
      expect(TerminalThemes.getById('vivid'), isNotNull);
      expect(TerminalThemes.getById('ocean-dark'), isNotNull);
    });

    test('all built-in themes keep default text readable', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(theme.foreground, theme.background),
          greaterThanOrEqualTo(4.5),
          reason:
              'Theme ${theme.name} should keep default terminal text readable '
              'on its background.',
        );
      }
    });

    test(
      'all built-in themes keep ANSI text colors readable on background',
      () {
        const ansiColorGetters =
            <({String name, Color Function(TerminalThemeData) color})>[
              (name: 'red', color: _themeRed),
              (name: 'green', color: _themeGreen),
              (name: 'yellow', color: _themeYellow),
              (name: 'blue', color: _themeBlue),
              (name: 'magenta', color: _themeMagenta),
              (name: 'cyan', color: _themeCyan),
              (name: 'white', color: _themeWhite),
              (name: 'brightRed', color: _themeBrightRed),
              (name: 'brightGreen', color: _themeBrightGreen),
              (name: 'brightYellow', color: _themeBrightYellow),
              (name: 'brightBlue', color: _themeBrightBlue),
              (name: 'brightMagenta', color: _themeBrightMagenta),
              (name: 'brightCyan', color: _themeBrightCyan),
              (name: 'brightWhite', color: _themeBrightWhite),
            ];
        for (final theme in TerminalThemes.all) {
          for (final ansiColor in ansiColorGetters) {
            expect(
              _contrastRatio(ansiColor.color(theme), theme.background),
              greaterThanOrEqualTo(4.5),
              reason:
                  'Theme ${theme.name} should keep ANSI ${ansiColor.name} '
                  'readable on the main background.',
            );
          }
        }
      },
    );

    test('dark built-in themes keep bright black readable on background', () {
      for (final theme in TerminalThemes.darkThemes) {
        expect(
          _contrastRatio(theme.brightBlack, theme.background),
          greaterThanOrEqualTo(4.5),
          reason:
              'Dark theme ${theme.name} should keep ANSI bright black '
              'readable on the main background.',
        );
      }
    });

    test('all built-in themes keep dim prompt bars legible', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(theme.brightBlack, theme.black),
          greaterThanOrEqualTo(4.5),
          reason:
              'Theme ${theme.name} should keep dim prompt text readable on '
              'ANSI black bars.',
        );
      }
    });

    test('all built-in themes keep cursors visible', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(theme.cursor, theme.background),
          greaterThanOrEqualTo(3),
          reason:
              'Theme ${theme.name} should keep the cursor visible on the '
              'terminal background.',
        );
      }
    });

    test('all built-in themes keep selections visible', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(
            _compositeOver(theme.selection, theme.background),
            theme.background,
          ),
          greaterThanOrEqualTo(1.25),
          reason:
              'Theme ${theme.name} should keep the selection overlay visible '
              'against the terminal background.',
        );
      }
    });

    test('default search hit colors stay readable', () {
      for (final theme in TerminalThemes.all) {
        final xtermTheme = theme.toXtermTheme();
        expect(
          _contrastRatio(
            xtermTheme.searchHitForeground,
            xtermTheme.searchHitBackground,
          ),
          greaterThanOrEqualTo(4.5),
          reason:
              'Theme ${theme.name} should keep default search hits readable.',
        );
        expect(
          _contrastRatio(
            xtermTheme.searchHitForeground,
            xtermTheme.searchHitBackgroundCurrent,
          ),
          greaterThanOrEqualTo(4.5),
          reason:
              'Theme ${theme.name} should keep current search hits readable.',
        );
      }
    });
  });
}

Color _themeRed(TerminalThemeData theme) => theme.red;
Color _themeGreen(TerminalThemeData theme) => theme.green;
Color _themeYellow(TerminalThemeData theme) => theme.yellow;
Color _themeBlue(TerminalThemeData theme) => theme.blue;
Color _themeMagenta(TerminalThemeData theme) => theme.magenta;
Color _themeCyan(TerminalThemeData theme) => theme.cyan;
Color _themeWhite(TerminalThemeData theme) => theme.white;
Color _themeBrightRed(TerminalThemeData theme) => theme.brightRed;
Color _themeBrightGreen(TerminalThemeData theme) => theme.brightGreen;
Color _themeBrightYellow(TerminalThemeData theme) => theme.brightYellow;
Color _themeBrightBlue(TerminalThemeData theme) => theme.brightBlue;
Color _themeBrightMagenta(TerminalThemeData theme) => theme.brightMagenta;
Color _themeBrightCyan(TerminalThemeData theme) => theme.brightCyan;
Color _themeBrightWhite(TerminalThemeData theme) => theme.brightWhite;
