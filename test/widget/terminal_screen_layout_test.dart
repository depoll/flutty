import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('terminal layout helpers', () {
    test(
      'keeps horizontal and top breathing room without wasting bottom rows',
      () {
        expect(terminalViewportPadding, const EdgeInsets.fromLTRB(8, 8, 8, 0));
        expect(terminalViewportPadding.bottom, 0);
      },
    );

    test('positions selection actions above the bottom safe area', () {
      const mediaQuery = MediaQueryData(padding: EdgeInsets.only(bottom: 34));

      expect(selectionActionsBottomOffset(mediaQuery), 46);
    });
  });
}
