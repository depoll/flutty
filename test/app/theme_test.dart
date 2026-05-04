import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/terminal_theme_service.dart';

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
      const terminalTheme = TerminalThemes.tokyoNightNight;

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
      const terminalTheme = TerminalThemes.atomOneDark;

      final theme = FluttyTheme.fromTerminalTheme(
        terminalTheme,
        brightness: Brightness.light,
      );

      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, terminalTheme.background);
    });

    test('builds app theme from active terminal connection override', () {
      const terminalThemeSettings = TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      );
      const overrideTheme = TerminalThemes.tokyoNightNight;

      final theme = buildTerminalAppTheme(
        brightness: Brightness.dark,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: TerminalThemes.all,
        terminalAppThemeOverride: TerminalAppThemeOverride(
          owner: const Object(),
          darkThemeId: overrideTheme.id,
        ),
      );

      expect(theme.scaffoldBackgroundColor, overrideTheme.background);
      expect(theme.colorScheme.onSurface, overrideTheme.foreground);
    });

    test('falls back to global theme when override omits brightness', () {
      const terminalThemeSettings = TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      );
      const globalTheme = TerminalThemes.defaultDarkTheme;

      final theme = buildTerminalAppTheme(
        brightness: Brightness.dark,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: TerminalThemes.all,
        terminalAppThemeOverride: TerminalAppThemeOverride(
          owner: const Object(),
          lightThemeId: TerminalThemes.defaultLightTheme.id,
        ),
      );

      expect(theme.scaffoldBackgroundColor, globalTheme.background);
      expect(theme.colorScheme.onSurface, globalTheme.foreground);
    });

    test(
      'uses the brand-teal cursor as Material primary for MonkeySSH themes',
      () {
        for (final terminalTheme in [
          TerminalThemes.monkeyDark,
          TerminalThemes.monkeyLight,
        ]) {
          final theme = FluttyTheme.fromTerminalTheme(
            terminalTheme,
            brightness: terminalTheme.isDark
                ? Brightness.dark
                : Brightness.light,
          );
          expect(
            theme.colorScheme.primary,
            terminalTheme.cursor,
            reason:
                '${terminalTheme.name} should drive Material primary from '
                'its saturated cursor color.',
          );
        }
      },
    );

    test('falls back to the candidate-scoring algorithm for low-saturation '
        'cursors', () {
      final theme = FluttyTheme.fromTerminalTheme(
        TerminalThemes.dracula,
        brightness: Brightness.dark,
      );
      // Dracula uses a near-white cursor (low saturation), so primary
      // should come from the saturated candidate list instead.
      expect(theme.colorScheme.primary, isNot(TerminalThemes.dracula.cursor));
      expect(
        _terminalAccentCandidates(TerminalThemes.dracula),
        contains(theme.colorScheme.primary),
      );
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
