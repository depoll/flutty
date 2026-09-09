import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

import '../test/helpers/terminal_input_helpers.dart';

import '../test/helpers/terminal_input_scenarios.dart';

const _deleteDetectionMarker = '\u200B\u200B';

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

      expect(terminalTextFromEvents(terminalOutput), 'hello');

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

      expect(terminalTextFromEvents(terminalOutput), 'the ');

      focusNode.dispose();
    });

    testWidgets(
      'preserves the separator when swipe typing resumes after an input reset',
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
                resolveTextBeforeCursor: () => 'echo ready',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B world',
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange(start: 2, end: 8),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), ' world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims the swipe separator after an input reset when the current line is only a prompt marker',
      (tester) async {
        await swipeSeparatorAfterPromptReset(tester);
      },
    );

    testWidgets(
      'does not duplicate the separator when swipe typing resumes after an input reset',
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
                resolveTextBeforeCursor: () => 'echo ready ',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B world',
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange(start: 2, end: 8),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not prepend whitespace when a suggestion commits after the buffer is cleared',
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

        await commitSwipeText(tester, '$_deleteDetectionMarker hello');

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not prepend whitespace when a suggestion replaces a shortened first word',
      (tester) async {
        await suggestionReplacingShortenedFirstWord(tester);
      },
    );

    testWidgets(
      'touch-driven caret moves clear the IME buffer after a replacement selection collapses elsewhere',
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
            text: '${_deleteDetectionMarker}echo teh world',
            selection: TextSelection.collapsed(offset: 16),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo the world',
            initialCursorOffset: 'echo the'.length,
          ),
          (text: 'echo the world', cursorOffset: 'echo '.length),
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

    testWidgets(
      'preserves the shortened prefix when a delete-reset continuation resumes the same word with the live terminal prefix',
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
                resolveTextBeforeCursor: () => 'didn',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}didnt',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}didn',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker test',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'didntest');

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves the deleted suffix when a trailing-backspace reset resumes the same word and continues into the next word',
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
                resolveTextBeforeCursor: () => 'thin',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}things',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}thin',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker gs are ',
            selection: TextSelection.collapsed(offset: 10),
          ),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'thin',
            initialCursorOffset: 'thin'.length,
          ),
          (text: 'things are ', cursorOffset: 'things are '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the shortened prefix when later delete-reset words only share letters with the deleted suggestion',
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
                resolveTextBeforeCursor: () => 'what do we t',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}what do we thinking',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}what do we t',
            selection: TextSelection.collapsed(offset: 14),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker whatever considering ',
            selection: TextSelection.collapsed(offset: 24),
          ),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'what do we t',
            initialCursorOffset: 'what do we t'.length,
          ),
          (
            text: 'what do we t whatever considering ',
            cursorOffset: 'what do we t whatever considering '.length,
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a leading IME separator during delete-reset replacement when the live terminal prefix is visible',
      (tester) async {
        await imeSeparatorDuringDeleteReset(tester);
      },
    );

    testWidgets(
      'preserves a new separator when a trailing-backspace reset is followed by a same-initial unrelated committed word',
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
                resolveTextBeforeCursor: () => 'shel',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}shell',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}shel',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker story ',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'shel',
            initialCursorOffset: 'shel'.length,
          ),
          (text: 'shel story ', cursorOffset: 'shel story '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves a manual separator when replacing a swiped word after backspacing into it',
      (tester) async {
        await manualSeparatorAfterSwipeBackspace(tester);
      },
    );

    testWidgets(
      'preserves an IME separator when replacing a swiped word after backspacing into it',
      (tester) async {
        await imeSeparatorAfterSwipeBackspace(tester);
      },
    );

    testWidgets(
      'does not force-resync the IME during replacement after deleting a later word',
      (tester) async {
        await replacementAfterDeletingLaterWord(tester);
      },
    );

    testWidgets('reviews unbracketed multiline IME paste before sending it', (
      tester,
    ) async {
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
                return false;
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
              text: '\u200B\u200Becho ready\necho deploy',
              selection: TextSelection.collapsed(offset: 24),
            ),
          );
      await tester.pump();
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.multiline),
      );
      expect(terminalOutput, isEmpty);

      focusNode.dispose();
    });
  });
}
