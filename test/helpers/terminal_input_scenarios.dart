// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

import 'terminal_input_helpers.dart';

const _deleteDetectionMarker = '\u200B\u200B';

Future<void> swipeSeparatorAfterPromptReset(WidgetTester tester) async {
  final terminalOutput = <String>[];
  final terminal = Terminal(onOutput: terminalOutput.add);
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
          resolveTextBeforeCursor: () => '>',
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();

  controller.clearImeBuffer();
  await tester.pump();

  await commitSwipeText(tester, '$_deleteDetectionMarker world');

  expect(terminalTextFromEvents(terminalOutput), 'world');

  focusNode.dispose();
}

Future<void> suggestionReplacingShortenedFirstWord(WidgetTester tester) async {
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

  terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bte',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200B the ',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  focusNode.dispose();
}

Future<void> imeSeparatorDuringDeleteReset(WidgetTester tester) async {
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
          resolveTextBeforeCursor: () => 'te',
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

  terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bte',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200B the ',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  focusNode.dispose();
}

Future<void> manualSeparatorAfterSwipeBackspace(WidgetTester tester) async {
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

  await commitSwipeText(tester, '$_deleteDetectionMarker teh');

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}teh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}te',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  focusNode.dispose();
}

Future<void> imeSeparatorAfterSwipeBackspace(WidgetTester tester) async {
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

  await commitSwipeText(tester, '${_deleteDetectionMarker}teh ');

  terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}te',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  focusNode.dispose();
}

Future<void> replacementAfterDeletingLaterWord(WidgetTester tester) async {
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

  expect(terminalTextFromEvents(terminalOutput), 'the ');
  expect(
    tester.testTextInput.log.where(
      (call) => call.method == 'TextInput.setEditingState',
    ),
    isEmpty,
  );

  focusNode.dispose();
}
