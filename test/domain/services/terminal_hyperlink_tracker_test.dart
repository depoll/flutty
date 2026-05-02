import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_hyperlink_tracker.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalHyperlinkTracker', () {
    late Terminal terminal;
    late TerminalHyperlinkTracker tracker;

    setUp(() {
      terminal = Terminal(maxLines: 200);
      tracker = TerminalHyperlinkTracker()..attach(terminal);
      terminal.onPrivateOSC = tracker.handlePrivateOsc;
    });

    test('resolves OSC 8 links whose visible label is not a URL', () {
      terminal.write(
        [
          '\u001b]8;;https://github.com/orgs/community/discussions/1\u0007',
          'Community CLI docs',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'https://github.com/orgs/community/discussions/1',
      );
      expect(tracker.resolveLinkAt(const CellOffset(40, 0)), isNull);
    });

    test('reassembles OSC 8 destinations containing semicolons', () {
      terminal.write(
        [
          '\u001b]8;;https://example.com/docs;topic=tmux\u0007',
          'tmux docs',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(1, 0)),
        'https://example.com/docs;topic=tmux',
      );
    });

    test('keeps hyperlink anchors valid after terminal reflow', () {
      terminal
        ..write(
          [
            '\u001b]8;;https://example.com/reflow\u0007',
            'abcdefghijkl',
            '\u001b]8;;\u0007',
          ].join(),
        )
        ..resize(6, terminal.viewHeight);

      expect(
        tracker.resolveLinkAt(const CellOffset(1, 1)),
        'https://example.com/reflow',
      );
    });

    test('prunes detached hyperlinks while processing later OSC 8 output', () {
      terminal = Terminal(maxLines: 200);
      tracker = TerminalHyperlinkTracker()..attach(terminal);
      terminal
        ..onPrivateOSC = tracker.handlePrivateOsc
        ..write(
          [
            '\u001b]8;;https://example.com/one\u0007',
            'one',
            '\u001b]8;;\u0007\n',
            for (var i = 0; i < 220; i++) 'filler $i\n',
          ].join(),
        );

      expect(tracker.trackedHyperlinkCount, 1);

      terminal.write(
        [
          '\u001b]8;;https://example.com/two\u0007',
          'two',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(tracker.trackedHyperlinkCount, 1);
      String? resolvedLink;
      for (var y = 0; y <= terminal.buffer.absoluteCursorY; y++) {
        for (var x = 0; x < terminal.buffer.viewWidth; x++) {
          resolvedLink ??= tracker.resolveLinkAt(CellOffset(x, y));
        }
      }
      expect(resolvedLink, 'https://example.com/two');
    });

    group('retained-link cap / LRU eviction', () {
      test('caps retained hyperlinks at maxRetainedLinks', () {
        const cap = 3;
        final cappedTracker = TerminalHyperlinkTracker(maxRetainedLinks: cap)
          ..attach(terminal);
        terminal.onPrivateOSC = cappedTracker.handlePrivateOsc;

        for (var i = 0; i < cap + 2; i++) {
          terminal.write(
            '\u001b]8;;https://example.com/$i\u0007'
            'L$i'
            '\u001b]8;;\u0007\n',
          );
        }

        expect(cappedTracker.trackedHyperlinkCount, cap);
      });

      test('oldest links are evicted; newest remain resolvable', () {
        const cap = 2;
        final cappedTracker = TerminalHyperlinkTracker(maxRetainedLinks: cap)
          ..attach(terminal);
        terminal
          ..onPrivateOSC = cappedTracker.handlePrivateOsc
          // Write 3 single-character links on rows 0, 1, 2.
          // Use \r\n (CR+LF) so each link starts at column 0.
          ..write(
            '\u001b]8;;https://a.example.com\u0007A\u001b]8;;\u0007\r\n'
            '\u001b]8;;https://b.example.com\u0007B\u001b]8;;\u0007\r\n'
            '\u001b]8;;https://c.example.com\u0007C\u001b]8;;\u0007\r\n',
          );

        expect(cappedTracker.trackedHyperlinkCount, cap);

        // Link A (oldest) must have been evicted.
        expect(cappedTracker.resolveLinkAt(const CellOffset(0, 0)), isNull);

        // Links B and C (the two most-recent) must still resolve.
        expect(
          cappedTracker.resolveLinkAt(const CellOffset(0, 1)),
          'https://b.example.com',
        );
        expect(
          cappedTracker.resolveLinkAt(const CellOffset(0, 2)),
          'https://c.example.com',
        );
      });

      test('eviction at cap=0 stores no links', () {
        final zeroTracker = TerminalHyperlinkTracker(maxRetainedLinks: 0)
          ..attach(terminal);
        terminal
          ..onPrivateOSC = zeroTracker.handlePrivateOsc
          ..write('\u001b]8;;https://example.com\u0007link\u001b]8;;\u0007');

        expect(zeroTracker.trackedHyperlinkCount, 0);
        expect(zeroTracker.resolveLinkAt(const CellOffset(0, 0)), isNull);
      });
    });

    group('attach / reattach semantics', () {
      test('reattaching to the same terminal preserves tracked hyperlinks', () {
        terminal.write(
          '\u001b]8;;https://example.com/reattach\u0007link\u001b]8;;\u0007\n',
        );

        expect(tracker.trackedHyperlinkCount, 1);
        tracker.attach(terminal); // reattach same terminal
        expect(tracker.trackedHyperlinkCount, 1);

        expect(
          tracker.resolveLinkAt(const CellOffset(0, 0)),
          'https://example.com/reattach',
        );
      });

      test('attaching to a different terminal clears tracked hyperlinks', () {
        terminal.write(
          '\u001b]8;;https://example.com/clear\u0007link\u001b]8;;\u0007\n',
        );

        expect(tracker.trackedHyperlinkCount, 1);

        final newTerminal = Terminal(maxLines: 200);
        tracker.attach(newTerminal);

        expect(tracker.trackedHyperlinkCount, 0);
        // The link from the old terminal must not resolve on the new terminal.
        expect(tracker.resolveLinkAt(const CellOffset(0, 0)), isNull);
      });

      test(
        'reattaching to same terminal preserves pending hyperlink in progress',
        () {
          // Open an OSC 8 but do not close it yet.
          terminal.write('\u001b]8;;https://example.com/pending\u0007partial');

          tracker.attach(terminal); // same terminal – should be a no-op
          // Closing the link after reattach must still work.
          terminal.write('\u001b]8;;\u0007');

          expect(tracker.trackedHyperlinkCount, 1);
          expect(
            tracker.resolveLinkAt(const CellOffset(0, 0)),
            'https://example.com/pending',
          );
        },
      );
    });
  });
}
