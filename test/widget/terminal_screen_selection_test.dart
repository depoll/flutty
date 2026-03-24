import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('trimTerminalSelectionText', () {
    test('trims trailing padding on each line only', () {
      expect(
        trimTerminalSelectionText('  ls -la   \nnext line    \n    '),
        '  ls -la\nnext line\n',
      );
    });

    test('preserves interior spaces', () {
      expect(trimTerminalLinePadding('a  b   c   '), 'a  b   c');
    });
  });

  group('trimTerminalLinkCandidate', () {
    test('removes trailing punctuation around terminal links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/docs).'),
        'https://example.com/docs',
      );
    });

    test('keeps balanced parentheses inside links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path(test)'),
        'https://example.com/path(test)',
      );
    });

    test('keeps balanced square and curly brackets at the end of links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path[tmux]'),
        'https://example.com/path[tmux]',
      );
      expect(
        trimTerminalLinkCandidate('https://example.com/path{tmux}'),
        'https://example.com/path{tmux}',
      );
    });

    test('removes unmatched trailing square and curly brackets', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path[tmux]]'),
        'https://example.com/path[tmux]',
      );
      expect(
        trimTerminalLinkCandidate('https://example.com/path{tmux}}'),
        'https://example.com/path{tmux}',
      );
    });
  });

  group('detectTerminalLinkAtTextOffset', () {
    test('detects an https link at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Visit https://example.com/docs for details.',
        12,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'https://example.com/docs');
    });

    test('normalizes case-insensitive www links to https', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Open WWW.github.com/features/copilot now',
        10,
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://www.github.com/features/copilot',
      );
    });

    test('returns null when the tapped offset is outside a link', () {
      expect(
        detectTerminalLinkAtTextOffset(
          'Visit https://example.com/docs for details.',
          2,
        ),
        isNull,
      );
    });

    test('detects visible tel links at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Call tel:+15551234567 for help.',
        10,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'tel:+15551234567');
    });
  });

  group('normalizeTerminalLinkCandidate', () {
    test('prepends https for uppercase www links', () {
      expect(
        normalizeTerminalLinkCandidate('WWW.example.com/docs'),
        'https://WWW.example.com/docs',
      );
    });
  });

  group('isLaunchableTerminalUri', () {
    test('allows supported external link schemes', () {
      expect(isLaunchableTerminalUri(Uri.parse('https://example.com')), isTrue);
      expect(
        isLaunchableTerminalUri(Uri.parse('mailto:test@example.com')),
        isTrue,
      );
      expect(isLaunchableTerminalUri(Uri.parse('tel:+15551234567')), isTrue);
    });

    test('rejects unsupported schemes', () {
      expect(
        isLaunchableTerminalUri(Uri.parse('file:///tmp/test.txt')),
        isFalse,
      );
      expect(
        isLaunchableTerminalUri(Uri.parse('intent://example.com')),
        isFalse,
      );
    });
  });

  group('selectedNativeOverlayText', () {
    test('returns the selected overlay substring', () {
      expect(
        selectedNativeOverlayText(
          const TextEditingValue(
            text: 'copilot cli',
            selection: TextSelection(baseOffset: 0, extentOffset: 7),
          ),
        ),
        'copilot',
      );
    });

    test('returns empty text for a collapsed overlay selection', () {
      expect(
        selectedNativeOverlayText(
          const TextEditingValue(
            text: 'copilot cli',
            selection: TextSelection.collapsed(offset: 7),
          ),
        ),
        isEmpty,
      );
    });
  });

  group('applyTerminalCursorInsertion', () {
    test('appends inserted text at the current cursor offset', () {
      final nextValue = applyTerminalCursorInsertion(
        currentText: 'echo ready &',
        cursorOffset: 12,
        insertedText: ' echo done',
      );

      expect(nextValue, 'echo ready & echo done');
    });

    test('inserts text in the middle of the current terminal input', () {
      final nextValue = applyTerminalCursorInsertion(
        currentText: 'echo done',
        cursorOffset: 5,
        insertedText: 'ready && ',
      );

      expect(nextValue, 'echo ready && done');
    });
  });

  group('shouldShowNativeSelectionOverlay', () {
    test(
      'shows overlay when touch scrolling is not routed to the terminal',
      () {
        expect(
          shouldShowNativeSelectionOverlay(
            isNativeSelectionMode: true,
            routesTouchScrollToTerminal: false,
            revealOverlayInTouchScrollMode: false,
          ),
          isTrue,
        );
      },
    );

    test(
      'shows overlay during tmux touch scrolling after selection begins',
      () {
        expect(
          shouldShowNativeSelectionOverlay(
            isNativeSelectionMode: true,
            routesTouchScrollToTerminal: true,
            revealOverlayInTouchScrollMode: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'keeps overlay hidden during tmux touch scrolling until selection',
      () {
        expect(
          shouldShowNativeSelectionOverlay(
            isNativeSelectionMode: true,
            routesTouchScrollToTerminal: true,
            revealOverlayInTouchScrollMode: false,
          ),
          isFalse,
        );
      },
    );
  });
}
