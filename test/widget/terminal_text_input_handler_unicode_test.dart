// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

void main() {
  group('TerminalTextInputHandler unicode behavior', () {
    testWidgets('deletes a single emoji with one backspace', (tester) async {
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
          text: '$_deleteDetectionMarker👍',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), '👍\x7f');

      focusNode.dispose();
    });

    testWidgets(
      'deletes a single combining-character grapheme with one backspace',
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
            text:
                '$_deleteDetectionMarker'
                'e\u0301',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();

        expect(terminalOutput.join(), 'e\u0301\x7f');

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not review a single emoji insertion as suspicious paste',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) async {
                  reviews.add(review);
                  return true;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .updateEditingValue(
              const TextEditingValue(
                text: '$_deleteDetectionMarker👍',
                selection: TextSelection.collapsed(offset: 4),
              ),
            );
        await tester.pump();
        await tester.pump();

        expect(reviews, isEmpty);
        expect(terminalOutput.join(), '👍');

        focusNode.dispose();
      },
    );
  });
}
