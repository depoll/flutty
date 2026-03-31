// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

Future<void> _commitSwipeText(WidgetTester tester, String text) async {
  final selection = TextSelection.collapsed(offset: text.length);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: selection,
      composing: TextRange(
        start: _deleteDetectionMarker.length,
        end: text.length,
      ),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    TextEditingValue(text: text, selection: selection),
  );
  await tester.pump();
}

String _terminalTextFromEvents(Iterable<String> events) {
  final state = _terminalStateFromEvents(events);
  return state.text;
}

({String text, int cursorOffset}) _terminalStateFromEvents(
  Iterable<String> events, {
  String initialText = '',
  int? initialCursorOffset,
}) {
  final visibleCharacters = initialText.characters.toList(growable: true);
  var cursorOffset = initialCursorOffset ?? visibleCharacters.length;
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

TextEditingValue _editingValue(
  String userText, {
  required int selectionOffset,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: '$_deleteDetectionMarker$userText',
  selection: TextSelection.collapsed(
    offset: _deleteDetectionMarker.length + selectionOffset,
  ),
  composing: composing == TextRange.empty
      ? TextRange.empty
      : TextRange(
          start: _deleteDetectionMarker.length + composing.start,
          end: _deleteDetectionMarker.length + composing.end,
        ),
);

String _terminalKeyOutput(TerminalKey key) {
  final output = <String>[];
  Terminal(onOutput: output.add).keyInput(key);
  return output.join();
}

void main() {
  group('TerminalTextInputHandler', () {
    testWidgets('preserves swipe typing context across short pauses', (
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
          text: '\u200B\u200Bhello ',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 400));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      focusNode.dispose();
    });

    testWidgets('drops a spurious leading newline before first swipe text', (
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

      await _commitSwipeText(tester, '$_deleteDetectionMarker\nhello');

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });

    testWidgets('drops a leading space before first swipe text', (
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

      await _commitSwipeText(tester, '$_deleteDetectionMarker hello');

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });

    testWidgets('drops a leading swipe space after a committed newline', (
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
          text: '\u200B\u200Becho hi\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      await _commitSwipeText(tester, '$_deleteDetectionMarker next');

      expect(terminalOutput.join(), 'echo hi\nnext');

      focusNode.dispose();
    });

    testWidgets(
      'preserves the swipe separator after an input reset when text already exists',
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

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), ' world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a duplicate swipe separator after an input reset when text already ends with whitespace',
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

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets('preserves leading spaces for first non-swipe commit', (
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
          text: '\u200B\u200B  hello',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), '  hello');

      focusNode.dispose();
    });

    testWidgets('drops a swipe newline followed by a stray leading space', (
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

      await _commitSwipeText(tester, '$_deleteDetectionMarker\n hello');

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });

    testWidgets('preserves later swipe spaces after trimming first input', (
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

      await _commitSwipeText(tester, '$_deleteDetectionMarker hello ');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      focusNode.dispose();
    });

    testWidgets('resyncs delete-detection marker after backspacing past it', (
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
          text: '\u200B\u200Bok',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bre',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'ok\x7fre');

      focusNode.dispose();
    });

    testWidgets('clears all buffered text when the IME loses the marker', (
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
        _editingValue('hello', selectionOffset: 'hello'.length),
      );
      await tester.pump();

      terminalOutput.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );
      await tester.pump();

      expect(
        terminalOutput.join(),
        List.filled(
          'hello'.length,
          _terminalKeyOutput(TerminalKey.backspace),
        ).join(),
      );
      expect(
        _terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello',
          initialCursorOffset: 'hello'.length,
        ),
        (text: '', cursorOffset: 0),
      );
      expect(
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      focusNode.dispose();
    });

    testWidgets('keeps IME replacement selections intact', (tester) async {
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

      expect(_terminalTextFromEvents(terminalOutput), 'teh ');

      tester.testTextInput.log.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
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
    });

    testWidgets(
      'moves the terminal cursor when the IME caret moves without text changes',
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
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(5, _terminalKeyOutput(TerminalKey.arrowLeft)).join(),
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo teh world', cursorOffset: 'echo teh '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves terminal cursor position through mid-line replace and backspace',
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
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo th world', cursorOffset: 'echo th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacement selection is followed by immediate backspace',
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
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo teh world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo th world', cursorOffset: 'echo th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned across repeated non-collapsed replacements before backspace',
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
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo teh world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo then world',
            selection: TextSelection(baseOffset: 7, extentOffset: 11),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo th world', cursorOffset: 'echo th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the terminal cursor aligned at a space boundary before insertion',
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
          _editingValue('foo bar', selectionOffset: 'foo bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo bar',
            initialCursorOffset: 'foo bar'.length,
          ),
          (text: 'foo Xbar', cursorOffset: 'foo X'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'inserts at a moved caret without rewriting the unchanged suffix',
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
          _editingValue('foo bar', selectionOffset: 'foo bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo bar',
            initialCursorOffset: 'foo bar'.length,
          ),
          (text: 'foo Xbar', cursorOffset: 'foo X'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'deletes at a moved caret without rewriting the unchanged suffix',
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
          _editingValue('foo Xbar', selectionOffset: 'foo Xbar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join() +
              _terminalKeyOutput(TerminalKey.backspace),
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo Xbar',
            initialCursorOffset: 'foo Xbar'.length,
          ),
          (text: 'foo bar', cursorOffset: 'foo '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'inserts an identical character at a moved caret without rewriting the unchanged suffix',
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
          _editingValue('aaaa', selectionOffset: 'aaaa'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaa', selectionOffset: 1),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaaa', selectionOffset: 2),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}a',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'aaaa',
            initialCursorOffset: 'aaaa'.length,
          ),
          (text: 'aaaaa', cursorOffset: 2),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'deletes an identical character at a moved caret without rewriting the unchanged suffix',
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
          _editingValue('aaaaa', selectionOffset: 'aaaaa'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaaa', selectionOffset: 2),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaa', selectionOffset: 1),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          '${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'aaaaa',
            initialCursorOffset: 'aaaaa'.length,
          ),
          (text: 'aaaa', cursorOffset: 1),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when inserting and then backspacing at a space boundary',
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
          _editingValue('foo bar', selectionOffset: 'foo bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          'X${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo bar',
            initialCursorOffset: 'foo bar'.length,
          ),
          (text: 'foo bar', cursorOffset: 'foo '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when inserting and then backspacing between repeated spaces',
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
          _editingValue('foo  bar', selectionOffset: 'foo  bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo X bar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(4, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          'X${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo  bar',
            initialCursorOffset: 'foo  bar'.length,
          ),
          (text: 'foo  bar', cursorOffset: 'foo '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'replaces punctuation at a moved caret without rewriting the trailing word',
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
          _editingValue('hello, world', selectionOffset: 'hello, world'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello, world', selectionOffset: 'hello,'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello; world', selectionOffset: 'hello;'.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(6, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          '${_terminalKeyOutput(TerminalKey.backspace)};',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello, world',
            initialCursorOffset: 'hello, world'.length,
          ),
          (text: 'hello; world', cursorOffset: 'hello;'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'replaces the middle repeated word without touching the trailing match',
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
          _editingValue('go go go', selectionOffset: 'go go go'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go go go',
            selection: TextSelection(baseOffset: 5, extentOffset: 7),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'go go go',
            initialCursorOffset: 'go go go'.length,
          ),
          (text: 'go gone go', cursorOffset: 'go gone'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned after replacing a repeated word and then backspacing',
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
          _editingValue('go go go', selectionOffset: 'go go go'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go go go',
            selection: TextSelection(baseOffset: 5, extentOffset: 7),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go gon go', selectionOffset: 'go gon'.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          'ne${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'go go go',
            initialCursorOffset: 'go go go'.length,
          ),
          (text: 'go gon go', cursorOffset: 'go gon'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves replacement text after deleting a later swiped word',
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

        expect(_terminalTextFromEvents(terminalOutput), 'teh world ');

        tester.testTextInput.log.clear();

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
        expect(
          (tester.state(find.byType(TerminalTextInputHandler))
                  as TextInputClient)
              .currentTextEditingValue,
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a stray leading space when replacing a word after deleting a later word',
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

        await _commitSwipeText(tester, '$_deleteDetectionMarker the ');

        expect(_terminalTextFromEvents(terminalOutput), 'the ');

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not force-resync the IME while trimming a replacement-space artifact',
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

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B the ',
            selection: TextSelection.collapsed(offset: 7),
            composing: TextRange(start: 2, end: 7),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B the ',
            selection: TextSelection(baseOffset: 3, extentOffset: 6),
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

    testWidgets(
      'preserves replacement text after a later word delete drops part of the marker',
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

        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200Bteh ',
            selection: TextSelection.collapsed(offset: 5),
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
      },
    );

    testWidgets(
      'does not force-resync the IME when replacement text is already normalized',
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

    testWidgets('keeps ctrl combos working while IME composition is active', (
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
          text: '\u200B\u200Ba',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(terminalOutput.join(), '\u0003');

      focusNode.dispose();
    });

    testWidgets('notifies when soft-keyboard input is sent to the terminal', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      var callbackCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onUserInput: () => callbackCount++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();

      expect(callbackCount, 1);

      focusNode.dispose();
    });

    testWidgets('opens the keyboard after a touch tap', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      focusNode.dispose();
    });

    testWidgets(
      'does not reopen the keyboard when the platform closes it while focused',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.log.clear();
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .connectionClosed();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
      },
    );

    testWidgets('does not open the keyboard after a touch drag', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
    });

    testWidgets('does not open the keyboard after a touch tap when read only', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              readOnly: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
    });

    testWidgets(
      'does not open the keyboard after a touch tap when tapToShowKeyboard '
      'is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        // The handler uses autofocus: true, which triggers _onFocusChange.
        // With tapToShowKeyboard off, the connection is attached but not shown.
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        await tester.tapAt(target);
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        focusNode.dispose();
      },
    );

    testWidgets('does not reopen the keyboard on focus restoration when '
        'tapToShowKeyboard is false', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      final outerFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: outerFocusNode,
                  child: const SizedBox(
                    width: 50,
                    height: 50,
                    key: ValueKey('other'),
                  ),
                ),
                Expanded(
                  child: TerminalTextInputHandler(
                    terminal: terminal,
                    focusNode: focusNode,
                    deleteDetection: true,
                    tapToShowKeyboard: false,
                    child: const SizedBox.expand(
                      key: ValueKey('terminal-child'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      // Move focus away from the terminal.
      outerFocusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // Restore focus to the terminal (simulates popup menu close or
      // programmatic focus restore).  Keyboard must stay hidden.
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
      outerFocusNode.dispose();
    });

    testWidgets(
      'requestKeyboard still shows keyboard when tapToShowKeyboard is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        await tester.pump();
        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        // Explicit requestKeyboard (the toolbar button path) must always work.
        controller.requestKeyboard();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        focusNode.dispose();
      },
    );

    testWidgets('does not open the keyboard after a suppressed touch tap', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      final controller = TerminalTextInputHandlerController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              controller: controller,
              deleteDetection: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      controller.suppressNextTouchKeyboardRequest();
      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tapAt(target);
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      focusNode.dispose();
    });

    testWidgets(
      'does not open the keyboard after a multitouch gesture when the last finger stays still',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.hide();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        final origin =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final firstGesture = await tester.createGesture(pointer: 1);
        await firstGesture.down(origin);
        await tester.pump();

        final secondGesture = await tester.createGesture(pointer: 2);
        await secondGesture.down(origin + const Offset(20, 0));
        await tester.pump();
        await secondGesture.moveBy(const Offset(0, 80));
        await tester.pump();
        await secondGesture.up();
        await tester.pump();
        await firstGesture.up();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        focusNode.dispose();
      },
    );

    testWidgets('reviews suspicious multi-character IME insertion', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final decision = Completer<bool>();
      final reviews = <TerminalCommandReview>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onReviewInsertedText: (review) {
                reviews.add(review);
                return decision.future;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready; rm -rf /',
          selection: TextSelection.collapsed(offset: 21),
        ),
      );
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, 'echo ready; rm -rf /');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.shellChaining),
      );
      expect(terminalOutput, isEmpty);

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(_terminalStateFromEvents(terminalOutput), (
        text: 'echo ready; rm -rf /',
        cursorOffset: 'echo ready; rm -rf '.length,
      ));

      focusNode.dispose();
    });

    testWidgets(
      'reviews a suspicious committed IME payload after composition ends',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
            composing: TextRange(start: 2, end: 21),
          ),
        );
        await tester.pump();

        expect(reviews, isEmpty);
        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, 'echo ready; rm -rf /');
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(_terminalStateFromEvents(terminalOutput), (
          text: 'echo ready; rm -rf /',
          cursorOffset: 'echo ready; rm -rf '.length,
        ));

        focusNode.dispose();
      },
    );

    testWidgets('reviews a committed IME payload with a standalone ampersand', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final decision = Completer<bool>();
      final reviews = <TerminalCommandReview>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onReviewInsertedText: (review) {
                reviews.add(review);
                return decision.future;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready & echo done',
          selection: TextSelection.collapsed(offset: 24),
        ),
      );
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, 'echo ready & echo done');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.shellChaining),
      );
      expect(terminalOutput, isEmpty);

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(terminalOutput.join(), 'echo ready & echo done');

      focusNode.dispose();
    });

    testWidgets(
      'reviews a suspicious committed IME payload while keeping its selection',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        const suspiciousUserText = 'echo ready; rm -rf /';
        const suspiciousText = '\u200B\u200Becho ready; rm -rf /';
        const suspiciousSelection = TextSelection(
          baseOffset: _deleteDetectionMarker.length,
          extentOffset: suspiciousText.length,
        );

        tester.testTextInput.log.clear();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, suspiciousUserText);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
        expect(terminalOutput, isEmpty);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), suspiciousUserText);

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        focusNode.dispose();
      },
    );

    testWidgets('rejects suspicious IME insertion until the user approves', (
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
              onReviewInsertedText: (_) async => false,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready\necho deploy',
          selection: TextSelection.collapsed(offset: 24),
        ),
      );
      await tester.pump();
      await tester.pump();

      final client =
          tester.state(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(terminalOutput, isEmpty);
      expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

      focusNode.dispose();
    });

    testWidgets(
      'reviews IME insertions against the full terminal line context',
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
                  return false;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        const existingCommand = 'echo ready &';
        for (var index = 1; index <= existingCommand.length; index++) {
          final currentCommand = existingCommand.substring(0, index);
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '$_deleteDetectionMarker$currentCommand',
              selection: TextSelection.collapsed(
                offset: _deleteDetectionMarker.length + currentCommand.length,
              ),
            ),
          );
          await tester.pump();
        }

        reviews.clear();

        const combinedCommand = '$existingCommand echo done';
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$combinedCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + combinedCommand.length,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), existingCommand);
        expect(reviews, hasLength(1));
        expect(reviews.single.command, combinedCommand);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'ignores stale review approvals when a newer editing value arrives',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bls',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalOutput.join(), 'ls');

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue?.text,
          '${_deleteDetectionMarker}ls',
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'reviews IME insertions against terminal state after input resets',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final reviews = <TerminalCommandReview>[];
        var readOnly = false;

        Widget buildHandler() => MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              readOnly: readOnly,
              buildReviewTextForInsertedText: (delta, currentText) =>
                  applyTerminalInputDelta(
                    currentText: _terminalTextFromEvents(terminalOutput),
                    cursorOffset: _terminalTextFromEvents(
                      terminalOutput,
                    ).length,
                    deletedCount: delta.deletedCount,
                    appendedText: delta.appendedText,
                  ),
              onReviewInsertedText: (review) async {
                reviews.add(review);
                return false;
              },
              child: const SizedBox.expand(),
            ),
          ),
        );

        await tester.pumpWidget(buildHandler());

        focusNode.requestFocus();
        await tester.pump();

        const existingCommand = 'echo ready &';
        for (var index = 1; index <= existingCommand.length; index++) {
          final currentCommand = existingCommand.substring(0, index);
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '$_deleteDetectionMarker$currentCommand',
              selection: TextSelection.collapsed(
                offset: _deleteDetectionMarker.length + currentCommand.length,
              ),
            ),
          );
          await tester.pump();
        }

        readOnly = true;
        await tester.pumpWidget(buildHandler());
        await tester.pump();

        readOnly = false;
        await tester.pumpWidget(buildHandler());
        await tester.pump();

        reviews.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker echo done',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, 'echo ready & echo done');
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
        expect(_terminalTextFromEvents(terminalOutput), existingCommand);

        focusNode.dispose();
      },
    );
  });

  group('shouldRequestKeyboardForTerminalPointerUp', () {
    test('requests the keyboard for a tap-like first touch pointer', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard after touch movement beyond tap slop', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: true,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard for additional touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 2,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard after a multitouch gesture sequence', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('still requests the keyboard for non-touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.mouse,
          activeTouchPointers: 0,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('never requests the keyboard when input is read only', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: true,
        ),
        isFalse,
      );
    });
  });
}
