import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/app/theme.dart';
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
        _minimumContrastRatio(theme.colorScheme.primary, [
          theme.scaffoldBackgroundColor,
          theme.colorScheme.surfaceContainerHighest,
        ]),
        greaterThanOrEqualTo(4.5),
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

    test('uses Flutter predictive back transitions on Android', () {
      const terminalThemeSettings = TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      );
      final themes = [
        FluttyTheme.dark,
        buildTerminalAppTheme(
          brightness: Brightness.dark,
          terminalThemeSettings: terminalThemeSettings,
          terminalThemes: TerminalThemes.all,
        ),
      ];

      for (final theme in themes) {
        final builder =
            theme.pageTransitionsTheme.builders[TargetPlatform.android];
        expect(builder, isA<PredictiveBackPageTransitionsBuilder>());
        final predictiveBuilder =
            builder! as PredictiveBackPageTransitionsBuilder;
        expect(predictiveBuilder.fallbackColor, theme.scaffoldBackgroundColor);
      }
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
          final primary = theme.colorScheme.primary;
          expect(
            _hueDistance(primary, terminalTheme.cursor),
            lessThan(1),
            reason: '${terminalTheme.name} should retain its cursor hue.',
          );
          expect(
            _minimumContrastRatio(primary, [
              theme.scaffoldBackgroundColor,
              theme.colorScheme.surfaceContainerHighest,
            ]),
            greaterThanOrEqualTo(4.5),
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
        HSLColor.fromColor(theme.colorScheme.primary).saturation,
        greaterThan(0.4),
      );
    });

    test(
      'keeps text-facing theme roles opaque and WCAG AA across palettes',
      () {
        final themes = <ThemeData>[
          FluttyTheme.light,
          FluttyTheme.dark,
          for (final terminalTheme in TerminalThemes.all)
            FluttyTheme.fromTerminalTheme(
              terminalTheme,
              brightness: terminalTheme.isDark
                  ? Brightness.dark
                  : Brightness.light,
            ),
        ];

        for (final theme in themes) {
          final surfaces = [
            theme.scaffoldBackgroundColor,
            theme.colorScheme.surface,
            theme.colorScheme.surfaceContainerHighest,
          ];
          final textColors = [
            theme.colorScheme.primary,
            theme.colorScheme.onSurfaceVariant,
            theme.inputDecorationTheme.hintStyle!.color!,
            theme.textTheme.bodyMedium!.color!,
            theme.textTheme.bodySmall!.color!,
          ];

          for (final color in textColors) {
            expect(color.a, 1);
            expect(
              _minimumContrastRatio(color, surfaces),
              greaterThanOrEqualTo(4.5),
              reason:
                  '${theme.colorScheme.brightness} theme role $color should '
                  'remain readable on every app surface.',
            );
          }
        }
      },
    );
  });
}

double _hueDistance(Color a, Color b) {
  final difference = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue)
      .abs();
  return difference > 180 ? 360 - difference : difference;
}

double _minimumContrastRatio(Color color, List<Color> backgrounds) =>
    backgrounds
        .map((background) => _contrastRatio(color, background))
        .reduce((a, b) => a < b ? a : b);

double _contrastRatio(Color a, Color b) {
  final lighter = a.computeLuminance() > b.computeLuminance() ? a : b;
  final darker = identical(lighter, a) ? b : a;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
