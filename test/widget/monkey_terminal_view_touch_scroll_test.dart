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
}
