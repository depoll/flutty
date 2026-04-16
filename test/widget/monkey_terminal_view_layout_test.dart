// ignore_for_file: implementation_imports

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';

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
  });
}
