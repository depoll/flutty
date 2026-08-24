import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/system_bottom_inset.dart';

void main() {
  group('resolveSystemBottomInset', () {
    test('reserves the navigation bar while no keyboard inset applies', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.only(bottom: 34),
        viewPadding: EdgeInsets.only(bottom: 34),
      );

      expect(resolveSystemBottomInset(mediaQuery), 34);
    });

    test('reserves nothing once the layout is lifted above the keyboard', () {
      // Scaffold strips the bottom view inset from a body it resized, and the
      // keyboard already covers the navigation bar.
      const mediaQuery = MediaQueryData(
        viewPadding: EdgeInsets.only(bottom: 34),
      );

      expect(resolveSystemBottomInset(mediaQuery), 0);
    });

    test('reserves the navigation bar for an unlifted bottom inset', () {
      // The inset survived into this subtree, so nothing lifted the layout for
      // it: the navigation bar is still on screen even though padding.bottom
      // has been zeroed out by the (stale) keyboard inset.
      const mediaQuery = MediaQueryData(
        viewPadding: EdgeInsets.only(bottom: 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );

      expect(resolveSystemBottomInset(mediaQuery), 34);
    });

    test('reserves nothing when there is no bottom system bar', () {
      expect(
        resolveSystemBottomInset(
          const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 320)),
        ),
        0,
      );
      expect(resolveSystemBottomInset(const MediaQueryData()), 0);
    });
  });

  group('removeSystemBottomInset', () {
    test('drops the bottom inset while keeping the keyboard inset', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.fromLTRB(0, 44, 0, 34),
        viewPadding: EdgeInsets.fromLTRB(0, 44, 0, 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );

      final stripped = removeSystemBottomInset(mediaQuery);

      expect(resolveSystemBottomInset(stripped), 0);
      expect(stripped.padding.top, 44);
      expect(stripped.viewPadding.top, 44);
      expect(stripped.viewInsets.bottom, 320);
    });
  });
}
