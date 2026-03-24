// ignore_for_file: implementation_imports, public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('touch scroll falls back to arrow keys in alt buffer', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
    final output = <String>[];
    terminal.onOutput = output.add;

    final expectedOutput = <String>[];
    Terminal()
      ..onOutput = expectedOutput.add
      ..keyInput(TerminalKey.arrowDown);
    final expectedArrowDown = expectedOutput.join();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );

    await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
    await tester.pump();

    expect(output.join(), contains(expectedArrowDown));
  });

  testWidgets('touch scroll sends wheel input for mouse-reporting apps', (
    tester,
  ) async {
    final terminal = Terminal()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );

    await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
    await tester.pump();

    expect(output.join(), contains('\u001b[<65;'));
    expect(output.join(), isNot(contains('\u001b[B')));
  });

  testWidgets('desktop text insertion can be blocked by review callback', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(terminal, onInsertText: (_) async => false),
        ),
      ),
    );

    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .requestKeyboard();
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'echo done',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets('paste intent can be rerouted through reviewed callback', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;
    var pasteCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            onPasteText: () async {
              pasteCalls += 1;
            },
          ),
        ),
      ),
    );

    final actionsWidget = tester
        .widgetList<Actions>(find.byType(Actions))
        .firstWhere((widget) => widget.actions.containsKey(PasteTextIntent));
    final pasteAction = actionsWidget.actions[PasteTextIntent];
    expect(pasteAction, isA<CallbackAction<PasteTextIntent>>());
    (pasteAction! as CallbackAction<PasteTextIntent>).invoke(
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pump();

    expect(pasteCalls, 1);
    expect(output, isEmpty);
  });
}
