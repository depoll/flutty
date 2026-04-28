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

    test(
      'prefers larger landscape insets when padding exceeds viewPadding',
      () {
        const mediaQuery = MediaQueryData(
          size: Size(844, 390),
          padding: EdgeInsets.fromLTRB(72, 0, 54, 0),
          viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
          viewInsets: EdgeInsets.only(bottom: 200),
        );

        expect(
          resolveTerminalRenderPadding(mediaQuery),
          const EdgeInsets.only(left: 72, right: 54),
        );
      },
    );
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

  group('landscape terminal alignment', () {
    test('keeps trailing-edge alignment enabled in landscape', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        viewInsets: EdgeInsets.only(bottom: 200),
      );

      expect(shouldAlignTerminalToTrailingEdges(mediaQuery), isTrue);
    });

    test('shifts partial-cell slack to the leading and top edges', () {
      expect(
        resolveTerminalContentOrigin(
          viewportSize: const Size(844, 390),
          cellSize: const Size(10, 20),
          columns: 70,
          rows: 18,
          padding: const EdgeInsets.only(left: 72, right: 54),
          alignToTrailingEdges: true,
        ),
        const Offset(90, 30),
      );
    });

    test('keeps portrait content anchored to the origin', () {
      expect(
        resolveTerminalContentOrigin(
          viewportSize: const Size(390, 844),
          cellSize: const Size(10, 20),
          columns: 39,
          rows: 42,
        ),
        Offset.zero,
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

  group('resolveTerminalResizePixelDimensions', () {
    test('reports the padded terminal viewport in pixels', () {
      expect(
        resolveTerminalResizePixelDimensions(
          viewportSize: const Size(390.4, 844.6),
          padding: const EdgeInsets.fromLTRB(4.2, 8.8, 5.4, 10.1),
        ),
        (width: 381, height: 826),
      );
    });

    test('clamps fully padded viewports to zero', () {
      expect(
        resolveTerminalResizePixelDimensions(
          viewportSize: const Size(10, 12),
          padding: const EdgeInsets.all(20),
        ),
        (width: 0, height: 0),
      );
    });
  });
}
