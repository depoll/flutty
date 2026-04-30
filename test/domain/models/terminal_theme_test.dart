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

Color _compositeOver(Color foreground, Color background) =>
    Color.alphaBlend(foreground, background);

void main() {
  group('TerminalThemeData', () {
    test('builds xterm theme mode reports for tmux refreshes', () {
      expect(buildTerminalThemeModeReport(isDark: true), '\x1b[?997;1n');
      expect(buildTerminalThemeModeReport(isDark: false), '\x1b[?997;2n');
    });

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

    test('buildTerminalThemeOscResponse answers special color queries', () {
      const theme = TerminalThemes.defaultLightTheme;

      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '10',
          args: const ['?'],
        ),
        '\x1b]10;rgb:1f1f/2323/2828\x1b\\',
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '11',
          args: const ['?'],
        ),
        '\x1b]11;rgb:ffff/ffff/ffff\x1b\\',
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '12',
          args: const ['?'],
        ),
        '\x1b]12;rgb:0909/6969/dada\x1b\\',
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '17',
          args: const ['?'],
        ),
        '\x1b]17;rgb:1f1f/2323/2828\x1b\\',
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '19',
          args: const ['?'],
        ),
        '\x1b]19;rgb:1f1f/2323/2828\x1b\\',
      );
    });

    test('buildTerminalThemeOscResponse answers ANSI palette queries', () {
      const theme = TerminalThemes.defaultLightTheme;

      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '4',
          args: const ['0', '?', '4', '?', '232', '?'],
        ),
        '\x1b]4;0;rgb:2424/2929/2f2f\x1b\\'
        '\x1b]4;4;rgb:0909/6969/dada\x1b\\'
        '\x1b]4;232;rgb:0808/0808/0808\x1b\\',
      );
    });

    test('buildTerminalThemeOscResponse ignores unsupported OSC values', () {
      const theme = TerminalThemes.defaultLightTheme;

      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '11',
          args: const ['#000000'],
        ),
        isNull,
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '4',
          args: const ['999', '?'],
        ),
        isNull,
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: theme,
          code: '8',
          args: const ['id=1', 'https://example.com'],
        ),
        isNull,
      );
    });

    test('toXtermTheme normalizes unreadable selection backgrounds', () {
      const theme = TerminalThemeData(
        id: 'selection-test',
        name: 'Selection Test',
        isDark: false,
        foreground: Color(0xFF1F2328),
        background: Color(0xFFFFFFFF),
        cursor: Color(0xFF0969DA),
        selection: Color(0xFF1F2328),
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

      expect(
        _contrastRatio(
          theme.foreground,
          _compositeOver(xtermTheme.selection, theme.background),
        ),
        greaterThanOrEqualTo(3.5),
      );
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
      final theme = TerminalThemes.getById(TerminalThemes.defaultDarkThemeId);
      expect(theme, isNotNull);
      expect(theme!.id, TerminalThemes.defaultDarkThemeId);
      expect(theme.name, 'Dracula');
    });

    test('getById returns null when not exists', () {
      final theme = TerminalThemes.getById('nonexistent-theme');
      expect(theme, isNull);
    });

    test('getById resolves legacy built-in theme IDs', () {
      expect(
        TerminalThemes.getById('midnight-purple')?.id,
        TerminalThemes.defaultDarkThemeId,
      );
      expect(
        TerminalThemes.getById('clean-white')?.id,
        TerminalThemes.defaultLightThemeId,
      );
      expect(
        TerminalThemes.getById('github-light')?.id,
        TerminalThemes.defaultLightThemeId,
      );
      expect(
        TerminalThemes.getById('ocean-dark')?.id,
        TerminalThemes.solarizedDark.id,
      );
    });

    test('all themes have unique IDs', () {
      final themes = TerminalThemes.all;
      final ids = themes.map((t) => t.id).toSet();
      expect(ids.length, themes.length);
    });

    test('contains expected themes', () {
      expect(TerminalThemes.getById('iterm2-dracula'), isNotNull);
      expect(TerminalThemes.getById('iterm2-github-light-default'), isNotNull);
      expect(TerminalThemes.getById('iterm2-catppuccin-mocha'), isNotNull);
      expect(
        TerminalThemes.getById('iterm2-iterm2-solarized-light'),
        isNotNull,
      );
    });

    test('all built-in themes are sourced from iTerm2 scheme IDs', () {
      for (final theme in TerminalThemes.all) {
        expect(theme.id, startsWith('iterm2-'));
      }
    });

    test('built-in themes keep default text usable', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(theme.foreground, theme.background),
          greaterThanOrEqualTo(3),
          reason:
              'Theme ${theme.name} should keep default terminal text usable '
              'on its background.',
        );
      }
    });

    test('default built-in themes keep default text highly readable', () {
      expect(
        _contrastRatio(
          TerminalThemes.defaultDarkTheme.foreground,
          TerminalThemes.defaultDarkTheme.background,
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(
          TerminalThemes.defaultLightTheme.foreground,
          TerminalThemes.defaultLightTheme.background,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('all built-in themes keep cursors visible', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(theme.cursor, theme.background),
          greaterThanOrEqualTo(1.4),
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
            _compositeOver(theme.readableSelection, theme.background),
            theme.background,
          ),
          greaterThanOrEqualTo(1.04),
          reason:
              'Theme ${theme.name} should keep the selection visible against '
              'the terminal background.',
        );
      }
    });

    test('all built-in themes keep selected text readable', () {
      for (final theme in TerminalThemes.all) {
        expect(
          _contrastRatio(
            theme.foreground,
            _compositeOver(theme.readableSelection, theme.background),
          ),
          greaterThanOrEqualTo(3.5),
          reason:
              'Theme ${theme.name} should keep selected text readable against '
              'the selection background.',
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
