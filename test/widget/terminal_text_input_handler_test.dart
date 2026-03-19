// ignore_for_file: public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

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
  });

  group('shouldRequestKeyboardForTerminalPointerUp', () {
    test('requests the keyboard for a tap-like first touch pointer', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
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
          movedBeyondTapSlop: false,
          readOnly: true,
        ),
        isFalse,
      );
    });
  });
}
