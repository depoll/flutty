import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FluttyTheme.debugUseSystemFonts = true;
  });

  tearDownAll(() {
    FluttyTheme.debugUseSystemFonts = false;
  });

  group('FluttyTheme', () {
    test('builds app colors from a terminal palette', () {
      const terminalTheme = TerminalThemes.cityLights;

      final theme = FluttyTheme.fromTerminalTheme(
        terminalTheme,
        brightness: Brightness.dark,
      );

      expect(theme.scaffoldBackgroundColor, terminalTheme.background);
      expect(theme.appBarTheme.backgroundColor, terminalTheme.background);
      expect(theme.colorScheme.surface, terminalTheme.background);
      expect(theme.colorScheme.onSurface, terminalTheme.foreground);
      expect(theme.textTheme.titleLarge?.color, terminalTheme.foreground);
      expect(
        _terminalAccentCandidates(terminalTheme),
        contains(theme.colorScheme.primary),
      );
    });

    test('keeps the requested brightness for the Material theme slot', () {
      const terminalTheme = TerminalThemes.slate;

      final theme = FluttyTheme.fromTerminalTheme(
        terminalTheme,
        brightness: Brightness.light,
      );

      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, terminalTheme.background);
    });
  });
}

Set<Color> _terminalAccentCandidates(TerminalThemeData theme) => {
  theme.blue,
  theme.cyan,
  theme.magenta,
  theme.green,
  theme.brightBlue,
  theme.brightCyan,
  theme.brightMagenta,
  theme.cursor,
  theme.yellow,
  theme.red,
};
