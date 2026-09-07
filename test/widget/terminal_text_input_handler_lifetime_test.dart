import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _marker = '\u200B\u200B';

void main() {
  testWidgets('terminal replacement invalidates a pending command approval', (
    tester,
  ) async {
    final originalOutput = <String>[];
    final replacementOutput = <String>[];
    var terminal = Terminal(onOutput: originalOutput.add);
    final focusNode = FocusNode();
    final decision = Completer<bool>();
    var reviews = 0;

    Widget build() => MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          onReviewInsertedText: (_) {
            reviews++;
            return decision.future;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );

    await tester.pumpWidget(build());
    focusNode.requestFocus();
    await tester.pump();
    final originalState = tester.state(find.byType(TerminalTextInputHandler));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '${_marker}echo \$(id)',
        selection: TextSelection.collapsed(offset: 12),
      ),
    );
    await tester.pump();
    expect(reviews, 1);
    expect(originalOutput, isEmpty);

    terminal = Terminal(onOutput: replacementOutput.add);
    await tester.pumpWidget(build());
    expect(
      tester.state(find.byType(TerminalTextInputHandler)),
      same(originalState),
    );
    decision.complete(true);
    await tester.pump();
    await tester.pump();
    expect(originalOutput, isEmpty);
    expect(replacementOutput, isEmpty);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '${_marker}pwd',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    expect(replacementOutput.join(), 'pwd');
    await tester.pumpWidget(const SizedBox.shrink());
    focusNode.dispose();
  });

  testWidgets(
    'terminal replacement stops a held iOS hardware key repeat',
    (tester) async {
      final originalOutput = <String>[];
      final replacementOutput = <String>[];
      var terminal = Terminal(onOutput: originalOutput.add);
      final focusNode = FocusNode();

      Widget build() => MaterialApp(
        home: Scaffold(
          body: TerminalTextInputHandler(
            terminal: terminal,
            focusNode: focusNode,
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.pumpWidget(build());
      focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      expect(originalOutput, isNotEmpty);
      terminal = Terminal(onOutput: replacementOutput.add);
      await tester.pumpWidget(build());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      expect(replacementOutput, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      focusNode.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('terminal replacement clears the previous IME delta baseline', (
    tester,
  ) async {
    final originalOutput = <String>[];
    final replacementOutput = <String>[];
    var terminal = Terminal(onOutput: originalOutput.add);
    final focusNode = FocusNode();

    Widget build() => MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          child: const SizedBox.expand(),
        ),
      ),
    );

    await tester.pumpWidget(build());
    focusNode.requestFocus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '${_marker}old',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    expect(originalOutput.join(), 'old');
    final client =
        tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;
    await tester.pumpWidget(build());
    expect(client.currentTextEditingValue?.text, '${_marker}old');

    tester.testTextInput.log.clear();
    terminal = Terminal(onOutput: replacementOutput.add);
    await tester.pumpWidget(build());
    expect(client.currentTextEditingValue?.text, _marker);
    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(
        anyOf(
          contains('TextInput.clearClient'),
          contains('TextInput.hide'),
          contains('TextInput.setClient'),
        ),
      ),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '${_marker}new',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    expect(replacementOutput.join(), 'new');
    await tester.pumpWidget(const SizedBox.shrink());
    focusNode.dispose();
  });
}
