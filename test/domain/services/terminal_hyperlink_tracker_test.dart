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
  });
}
