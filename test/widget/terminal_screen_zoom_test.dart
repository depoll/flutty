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

    test('applies incremental scale deltas in both directions', () {
      expect(applyTerminalScaleDelta(14, 1, 0.85), 11.9);
      expect(applyTerminalScaleDelta(11.9, 0.85, 0.95), closeTo(13.3, 0.1));
      expect(applyTerminalScaleDelta(13.3, 0.95, 0.75), closeTo(10.5, 0.1));
    });
  });
}
