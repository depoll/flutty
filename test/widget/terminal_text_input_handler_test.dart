// ignore_for_file: public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
          text: '  hello ',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 400));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      focusNode.dispose();
    });
  });

  group('shouldRequestKeyboardForTerminalPointerDown', () {
    test('requests the keyboard for the first touch pointer', () {
      expect(
        shouldRequestKeyboardForTerminalPointerDown(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard for additional touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerDown(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 2,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('still requests the keyboard for non-touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerDown(
          pointerKind: PointerDeviceKind.mouse,
          activeTouchPointers: 0,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('never requests the keyboard when input is read only', () {
      expect(
        shouldRequestKeyboardForTerminalPointerDown(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          readOnly: true,
        ),
        isFalse,
      );
    });
  });
}
