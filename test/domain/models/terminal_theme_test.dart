import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutty/domain/models/terminal_theme.dart';
import 'package:flutty/domain/models/terminal_themes.dart';

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
  });
}
