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
}
