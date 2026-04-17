import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('terminal layout helpers', () {
    test('keeps the terminal flush with the viewport edges', () {
      expect(terminalViewportPadding, EdgeInsets.zero);
      expect(terminalViewportPadding.bottom, 0);
    });

    test('positions selection actions above the bottom safe area', () {
      const mediaQuery = MediaQueryData(padding: EdgeInsets.only(bottom: 34));

      expect(selectionActionsBottomOffset(mediaQuery), 46);
    });

    test('positions the upsell snackbar above visible bottom chrome only', () {
      const mediaQuery = MediaQueryData(padding: EdgeInsets.only(bottom: 34));

      // Flutter's floating SnackBar already lifts above the home-indicator
      // safe area, so the margin just needs a small visual gap when there is
      // no in-body keyboard toolbar to clear.
      expect(upgradeSnackBarBottomMargin(mediaQuery), 16);
      expect(
        upgradeSnackBarBottomMargin(mediaQuery, showKeyboardToolbar: true),
        100,
      );
    });

    test('tmux bar expansion uses the available terminal height', () {
      expect(resolveTmuxBarMaxContentHeight(320), closeTo(217.6, 0.01));
      expect(resolveTmuxBarMaxContentHeight(24), 0);
      expect(
        resolveTmuxBarMaxContentHeight(0, fallbackAvailableHeight: 320),
        closeTo(217.6, 0.01),
      );
    });

    test('tmux bar reveal stays aligned with terminal padding', () {
      expect(resolveTmuxBarRevealBottomOffset(0), -22);
      expect(resolveTmuxBarRevealBottomOffset(11), -11);
      expect(resolveTmuxBarRevealBottomOffset(22), 0);
      expect(resolveTmuxBarRevealBottomOffset(56), 34);

      expect(resolveTmuxBarRevealOpacity(-10), 0);
      expect(resolveTmuxBarRevealOpacity(0), 0);
      expect(resolveTmuxBarRevealOpacity(11), 0.5);
      expect(resolveTmuxBarRevealOpacity(22), 1);
      expect(resolveTmuxBarRevealOpacity(40), 1);
    });

    test('tmux bar stays inside visible safe insets', () {
      const portraitMediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.only(bottom: 34),
      );
      const portraitKeyboardMediaQuery = MediaQueryData(
        size: Size(390, 844),
        viewPadding: EdgeInsets.only(bottom: 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );
      const landscapeMediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTmuxBarSafeInsets(portraitMediaQuery),
        const EdgeInsets.only(bottom: 34),
      );
      expect(
        resolveTmuxBarSafeInsets(portraitKeyboardMediaQuery),
        EdgeInsets.zero,
      );
      expect(
        resolveTmuxBarSafeInsets(landscapeMediaQuery),
        const EdgeInsets.fromLTRB(44, 0, 34, 21),
      );
    });

    test(
      'tmux detection retries immediately instead of waiting two seconds',
      () {
        expect(resolveTmuxDetectionRetrySchedule(), const <Duration>[
          Duration.zero,
          Duration(milliseconds: 150),
          Duration(milliseconds: 350),
          Duration(milliseconds: 700),
          Duration(milliseconds: 1400),
        ]);
        expect(
          resolveTmuxDetectionRetrySchedule(skipDelay: true),
          const <Duration>[Duration.zero],
        );
      },
    );

    test('resolves preferred tmux session name before remote verification', () {
      expect(
        resolvePreferredTmuxSessionName(
          structuredSessionName: 'workspace',
          autoConnectCommand: 'tmux attach -t ignored',
        ),
        'workspace',
      );
      expect(
        resolvePreferredTmuxSessionName(
          autoConnectCommand: 'tmux new-session -A -s parsed-session',
        ),
        'parsed-session',
      );
      expect(resolvePreferredTmuxSessionName(), isNull);
    });
  });
}
