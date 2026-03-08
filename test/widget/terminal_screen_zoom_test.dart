// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('terminal font zoom helpers', () {
    test('clamps font size to supported minimum and maximum', () {
      expect(clampTerminalFontSize(2), 8);
      expect(clampTerminalFontSize(18), 18);
      expect(clampTerminalFontSize(64), 32);
    });

    test('scales font size and keeps it in range', () {
      expect(scaleTerminalFontSize(14, 1.5), 21);
      expect(scaleTerminalFontSize(14, 0.1), 8);
      expect(scaleTerminalFontSize(14, 3), 32);
    });
  });
}
