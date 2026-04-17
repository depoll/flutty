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

    test('keeps horizontal cutout padding in landscape', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.only(left: 44, right: 34),
      );
    });

    test('uses landscape viewPadding when padding is already consumed', () {
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

  group('resolveTerminalViewportPadding', () {
    test('keeps portrait viewport padding edge-to-edge', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 34),
      );

      expect(
        resolveTerminalViewportPadding(
          mediaQuery,
          basePadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        ),
        const EdgeInsets.fromLTRB(0, 8, 0, 0),
      );
    });

    test('keeps landscape viewport inside the horizontal safe area', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalViewportPadding(
          mediaQuery,
          basePadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        ),
        const EdgeInsets.fromLTRB(44, 8, 34, 0),
      );
    });
  });

  group('resolveTerminalHorizontalFillScale', () {
    test('fills the final horizontal remainder without shrinking', () {
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 9.5,
          columns: 40,
        ),
        closeTo(1.0263, 0.0001),
      );
    });

    test('returns 1 for invalid dimensions', () {
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 0,
          cellWidth: 9.5,
          columns: 40,
        ),
        1,
      );
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 0,
          columns: 40,
        ),
        1,
      );
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 9.5,
          columns: 0,
        ),
        1,
      );
    });
  });
}
