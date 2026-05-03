// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

({String text, int cursorOffset}) _terminalStateFromEvents(
  Iterable<String> events, {
  required String initialText,
  required int initialCursorOffset,
}) {
  final visibleCharacters = initialText.characters.toList(growable: true);
  var cursorOffset = initialCursorOffset;

  for (final event in events) {
    var offset = 0;
    while (offset < event.length) {
      if (event.startsWith('\u001b[D', offset)) {
        if (cursorOffset > 0) {
          cursorOffset--;
        }
        offset += 3;
        continue;
      }
      if (event.startsWith('\u001b[C', offset)) {
        if (cursorOffset < visibleCharacters.length) {
          cursorOffset++;
        }
        offset += 3;
        continue;
      }

      final character = event.substring(offset).characters.first;
      offset += character.length;
      if (character == '\x7f') {
        if (cursorOffset > 0) {
          visibleCharacters.removeAt(cursorOffset - 1);
          cursorOffset--;
        }
        continue;
      }

      visibleCharacters.insert(cursorOffset, character);
      cursorOffset++;
    }
  }

  return (text: visibleCharacters.join(), cursorOffset: cursorOffset);
}

void main() {
  group('TerminalTextInputHandler', () {
    testWidgets('clears composing IME state after a touch-driven caret move', (
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
          text: '${_deleteDetectionMarker}hello world',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      await tester.pump();

      terminalOutput.clear();

      await tester.tap(find.byType(TerminalTextInputHandler));
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello world',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 8, end: 13),
        ),
      );
      await tester.pump();

      expect(
        _terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello world',
          initialCursorOffset: 'hello world'.length,
        ),
        (text: 'hello world', cursorOffset: 'hello '.length),
      );

      final client =
          tester.state(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      terminalOutput.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      expect(terminalOutput, ['\x7f']);

      focusNode.dispose();
    });

    testWidgets(
      'sends one backspace when stale IME selection deletes a chunk after touch',
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
            text: '${_deleteDetectionMarker}hello world',
            selection: TextSelection.collapsed(offset: 13),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello ',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello world',
            initialCursorOffset: 'hello world'.length,
          ),
          (text: 'hello orld', cursorOffset: 'hello '.length),
        );

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        focusNode.dispose();
      },
    );
  });
}
