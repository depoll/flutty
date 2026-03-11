// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('terminal scroll policy helpers', () {
    test('never simulates alt-buffer scroll on mobile', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isMobile: true,
          isUsingAltBuffer: true,
          preferExplicitMouseReporting: false,
        ),
        isFalse,
      );
    });

    test('never simulates scroll outside the alt buffer', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isMobile: false,
          isUsingAltBuffer: false,
          preferExplicitMouseReporting: false,
        ),
        isFalse,
      );
    });

    test('prefers explicit mouse reporting for tmux-safe scrolling', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isMobile: false,
          isUsingAltBuffer: true,
          preferExplicitMouseReporting: true,
        ),
        isFalse,
      );
    });

    test('can still opt into the synthetic fallback when desired', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isMobile: false,
          isUsingAltBuffer: true,
          preferExplicitMouseReporting: false,
        ),
        isTrue,
      );
    });
  });
}
