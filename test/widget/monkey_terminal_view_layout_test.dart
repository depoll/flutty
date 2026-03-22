// ignore_for_file: implementation_imports

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';

void main() {
  group('resolveTerminalRenderPadding', () {
    test('drops only the bottom safe-area inset', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.fromLTRB(12, 18, 16, 34),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.fromLTRB(12, 18, 16, 0),
      );
    });

    test('keeps keyboard-open bottom inset cleared', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.fromLTRB(12, 18, 16, 0),
        viewPadding: EdgeInsets.fromLTRB(12, 18, 16, 34),
        viewInsets: EdgeInsets.fromLTRB(0, 0, 0, 320),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.fromLTRB(12, 18, 16, 0),
      );
    });
  });
}
