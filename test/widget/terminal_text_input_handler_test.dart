import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalTextInputHandler', () {
    late Terminal terminal;
    late FocusNode focusNode;

    setUp(() {
      terminal = Terminal(maxLines: 100);
      focusNode = FocusNode();
    });

    testWidgets('renders child widget', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const Text('child'),
            ),
          ),
        ),
      );

      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('creates with all parameters', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              keyboardAppearance: Brightness.light,
              readOnly: true,
              child: const Text('child'),
            ),
          ),
        ),
      );

      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('handles focus changes', (tester) async {
      final localFocus = FocusNode();
      addTearDown(localFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: localFocus,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      // Request focus
      localFocus.requestFocus();
      await tester.pumpAndSettle();

      // Unfocus
      localFocus.unfocus();
      await tester.pumpAndSettle();
    });

    testWidgets('handles widget update with new focus node', (tester) async {
      final focusNode2 = FocusNode();
      addTearDown(focusNode2.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      // Rebuild with a different focus node
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode2,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
    });

    testWidgets('handles readOnly toggle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              readOnly: true,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      // Switch to writable
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
    });

    testWidgets('handles hardware key events', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();

      // Send a key-down event for 'a'
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
    });

    testWidgets('handles hardware key events with modifiers', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();

      // Send Enter key
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    });

    testWidgets('performAction sends enter for newline', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();

      (tester.state<State>(find.byType(TerminalTextInputHandler))
              as TextInputClient)
          .performAction(TextInputAction.newline);
      await tester.pump();

      // Terminal should have received enter
      expect(output, isNotEmpty);
    });

    testWidgets('performAction sends enter for done', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();

      (tester.state<State>(find.byType(TerminalTextInputHandler))
              as TextInputClient)
          .performAction(TextInputAction.done);
      await tester.pump();

      expect(output, isNotEmpty);
    });

    testWidgets('deleteDetection uses sentinel text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();
    });

    testWidgets('updateEditingValue handles text input', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();

      (tester.state<State>(find.byType(TerminalTextInputHandler))
              as TextInputClient)
          .updateEditingValue(
            const TextEditingValue(
              text: 'hello',
              selection: TextSelection.collapsed(offset: 5),
            ),
          );
      await tester.pump();

      expect(output, isNotEmpty);
    });

    testWidgets('no-op TextInputClient methods do not throw', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      final client =
          tester.state<State>(find.byType(TerminalTextInputHandler))
              as TextInputClient;

      // These should all be no-ops
      expect(
        () => client
          ..updateFloatingCursor(
            RawFloatingCursorPoint(state: FloatingCursorDragState.Start),
          )
          ..showAutocorrectionPromptRect(0, 0)
          ..connectionClosed()
          ..performPrivateCommand('test', <String, dynamic>{})
          ..insertTextPlaceholder(const Size(10, 10))
          ..removeTextPlaceholder()
          ..showToolbar(),
        returnsNormally,
      );
    });

    testWidgets('currentAutofillScope returns null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      final client =
          tester.state<State>(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(client.currentAutofillScope, isNull);
    });
  });
}
