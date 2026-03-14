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
          terminalReportsMouseWheel: false,
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
          terminalReportsMouseWheel: false,
        ),
        isFalse,
      );
    });

    test(
      'prefers explicit mouse reporting when the terminal reports wheel input',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isMobile: false,
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'falls back when explicit reporting is preferred but not active yet',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isMobile: false,
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: false,
          ),
          isTrue,
        );
      },
    );

    test('can still opt into the synthetic fallback when desired', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isMobile: false,
          isUsingAltBuffer: true,
          preferExplicitMouseReporting: false,
          terminalReportsMouseWheel: true,
        ),
        isTrue,
      );
    });
  });

  group('terminal output follow helpers', () {
    test('follows output when no scroll clients are attached yet', () {
      expect(
        shouldFollowTerminalOutput(
          hasScrollClients: false,
          currentOffset: 0,
          maxScrollExtent: 0,
        ),
        isTrue,
      );
    });

    test('keeps following when already at the bottom', () {
      expect(
        shouldFollowTerminalOutput(
          hasScrollClients: true,
          currentOffset: 99.5,
          maxScrollExtent: 100,
        ),
        isTrue,
      );
    });

    test(
      'stops following when the viewport is scrolled away from the bottom',
      () {
        expect(
          shouldFollowTerminalOutput(
            hasScrollClients: true,
            currentOffset: 72,
            maxScrollExtent: 100,
          ),
          isFalse,
        );
      },
    );
  });

  group('terminal scroll policy change helper', () {
    test('rebuilds when alt-buffer usage changes', () {
      expect(
        didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: false,
          nextIsUsingAltBuffer: true,
          previousReportsMouseWheel: false,
          nextReportsMouseWheel: false,
        ),
        isTrue,
      );
    });

    test('rebuilds when mouse-wheel reporting changes', () {
      expect(
        didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: true,
          nextIsUsingAltBuffer: true,
          previousReportsMouseWheel: false,
          nextReportsMouseWheel: true,
        ),
        isTrue,
      );
    });

    test('does not rebuild when scroll policy inputs are unchanged', () {
      expect(
        didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: true,
          nextIsUsingAltBuffer: true,
          previousReportsMouseWheel: true,
          nextReportsMouseWheel: true,
        ),
        isFalse,
      );
    });
  });
}
