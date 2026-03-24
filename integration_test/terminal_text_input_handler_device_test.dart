import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

String _terminalTextFromEvents(Iterable<String> events) {
  final visibleCharacters = <String>[];
  for (final event in events) {
    for (final rune in event.runes) {
      if (rune == 0x7f) {
        if (visibleCharacters.isNotEmpty) {
          visibleCharacters.removeLast();
        }
        continue;
      }
      visibleCharacters.add(String.fromCharCode(rune));
    }
  }
  return visibleCharacters.join();
}

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

      expect(_terminalTextFromEvents(terminalOutput), 'hello');

      focusNode.dispose();
    });

    testWidgets('preserves the full replacement word after swipe typing', (
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
          text: '\u200B\u200Bteh ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();

      expect(_terminalTextFromEvents(terminalOutput), 'the ');

      focusNode.dispose();
    });

    testWidgets(
      'does not force-resync the IME during replacement after deleting a later word',
      (tester) async {
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
            text: '\u200B\u200Bteh world ',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bteh ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        tester.testTextInput.log.clear();

        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .updateEditingValue(
              const TextEditingValue(
                text: '\u200B\u200Bthe ',
                selection: TextSelection(baseOffset: -1, extentOffset: 0),
              ),
            );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'the ');
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        focusNode.dispose();
      },
    );
  });
}
