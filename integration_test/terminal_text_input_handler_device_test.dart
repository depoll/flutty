import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalTextInputHandler device validation', () {
    testWidgets('does not prepend whitespace to the first swipe word', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200B\nhello',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });
  });
}
