import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    test('uses persistent predictive back transitions on Android', () {
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
        expect(builder, isA<PersistentPredictiveBackPageTransitionsBuilder>());
        final predictiveBuilder =
            builder! as PersistentPredictiveBackPageTransitionsBuilder;
        expect(predictiveBuilder.fallbackColor, theme.scaffoldBackgroundColor);
      }
    });

    testWidgets(
      'keeps persistent transition mounted when Android gesture starts at zero',
      (tester) async {
        await _pumpPredictiveBackApp(tester);

        expect(_findPersistentPredictiveBackTransition(), findsWidgets);
        expect(_findFadeForwardsPageTransition(), findsWidgets);

        await _sendBackGesture(
          const MethodCall('startBackGesture', {
            'touchOffset': <double>[5, 300],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        );
        await tester.pump();

        expect(_findPersistentPredictiveBackTransition(), findsWidgets);
        expect(_findFadeForwardsPageTransition(), findsWidgets);

        await _sendBackGesture(const MethodCall('cancelBackGesture'));
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'keeps right-edge Android back gestures moving left after release',
      (tester) async {
        await _pumpPredictiveBackApp(tester);

        await _sendBackGesture(
          const MethodCall('startBackGesture', {
            'touchOffset': <double>[795, 300],
            'progress': 0.0,
            'swipeEdge': 1,
          }),
        );
        await tester.pump();
        await _sendBackGesture(
          const MethodCall('updateBackGestureProgress', {
            'touchOffset': <double>[700, 315],
            'progress': 0.5,
            'swipeEdge': 1,
          }),
        );
        await tester.pump();

        expect(_persistentBackTranslationX(tester), lessThan(0));

        await _sendBackGesture(const MethodCall('commitBackGesture'));
        await tester.pump();

        expect(_persistentBackTranslationX(tester), lessThan(0));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'does not slide the revealed route during Android predictive back',
      (tester) async {
        await _pumpPredictiveBackApp(tester);

        await _sendBackGesture(
          const MethodCall('startBackGesture', {
            'touchOffset': <double>[795, 300],
            'progress': 0.0,
            'swipeEdge': 1,
          }),
        );
        await tester.pump();
        await _sendBackGesture(
          const MethodCall('updateBackGestureProgress', {
            'touchOffset': <double>[700, 315],
            'progress': 0.5,
            'swipeEdge': 1,
          }),
        );
        await tester.pump();

        expect(_persistentBackTranslationX(tester), lessThan(0));
        expect(
          _nonZeroFractionalTranslationsOf(tester, find.byKey(_homePageKey)),
          isEmpty,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

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

const _homePageKey = ValueKey<String>('home-page');

Finder _findPersistentPredictiveBackTransition() => find.descendant(
  of: find.byType(MaterialApp),
  matching: find.byWidgetPredicate(
    (widget) =>
        '${widget.runtimeType}' == '_PersistentPredictiveBackTransition',
  ),
);

Finder _findFadeForwardsPageTransition() => find.descendant(
  of: find.byType(MaterialApp),
  matching: find.byWidgetPredicate(
    (widget) => '${widget.runtimeType}' == '_FadeForwardsPageTransition',
  ),
);

Future<void> _pumpPredictiveBackApp(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            for (final platform in TargetPlatform.values)
              platform: const PersistentPredictiveBackPageTransitionsBuilder(),
          },
        ),
      ),
      routes: {
        '/': (context) => Material(
          key: _homePageKey,
          child: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              _TestLiveMaterialPageRoute<void>(
                child: const Material(child: Text('terminal')),
              ),
            ),
            child: const Text('push'),
          ),
        ),
      },
    ),
  );

  await tester.tap(find.text('push'));
  await tester.pumpAndSettle();
}

double _persistentBackTranslationX(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(
    find.descendant(
      of: _findPersistentPredictiveBackTransition(),
      matching: find.byType(Transform),
    ),
  );
  for (final transform in transforms) {
    final translation = transform.transform.getTranslation();
    if (translation.x != 0 || translation.y != 0) {
      return translation.x;
    }
  }
  fail('Could not find a translated predictive back transform.');
}

List<Offset> _nonZeroFractionalTranslationsOf(
  WidgetTester tester,
  Finder finder,
) => tester
    .widgetList<FractionalTranslation>(
      find.ancestor(of: finder, matching: find.byType(FractionalTranslation)),
    )
    .map((widget) => widget.translation)
    .where((translation) => translation != Offset.zero)
    .toList(growable: false);

Future<void> _sendBackGesture(MethodCall methodCall) async {
  final message = const StandardMethodCodec().encodeMethodCall(methodCall);
  await TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('flutter/backgesture', message, (_) {});
}

class _TestLiveMaterialPageRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  _TestLiveMaterialPageRoute({required this.child})
    : super(allowSnapshotting: false);

  final Widget child;

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Widget buildContent(BuildContext context) => child;
}
