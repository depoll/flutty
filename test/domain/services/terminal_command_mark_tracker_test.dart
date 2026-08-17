import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_command_mark_tracker.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('tracks OSC 133/633 command starts and iTerm2 marks', () {
    final terminal = Terminal()..resize(20, 4);
    final tracker = TerminalCommandMarkTracker()..attach(terminal);

    terminal.write('prompt\r\n');
    tracker.handlePrivateOsc('133', const ['C']);
    terminal.write('output\r\nnext\r\n');
    tracker.handlePrivateOsc('633', const ['C']);
    terminal.write('more\r\n');
    tracker.handlePrivateOsc('1337', const ['SetMark']);

    expect(tracker.debugMarkRows, [1, 3, 4]);
    expect(tracker.previousMarkRow(4), 3);
    expect(tracker.previousMarkRow(3), 1);
    expect(tracker.previousMarkRow(1), 4, reason: 'navigation wraps');
  });

  test('deduplicates rows and evicts oldest marks over the cap', () {
    final terminal = Terminal()..resize(20, 2);
    final tracker = TerminalCommandMarkTracker(maxRetainedMarks: 2)
      ..attach(terminal);

    void mark(String code, List<String> args) =>
        tracker.handlePrivateOsc(code, args);
    mark('133', const ['C']);
    mark('1337', const ['SetMark']);
    terminal.write('\r\none\r\ntwo');
    mark('133', const ['C']);
    terminal.write('\r\nthree');
    mark('133', const ['C']);

    expect(tracker.markCount, 2);
    expect(tracker.debugMarkRows, [2, 3]);
  });
}
