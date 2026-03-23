import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('preserves tab in a batched IME delta', (tester) async {
    final terminalOutput = <String>[];
    final terminal = Terminal(onOutput: terminalOutput.add);
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(key: terminalViewKey, terminal),
        ),
      ),
    );

    terminalViewKey.currentState!.requestKeyboard();
    await tester.pump();

    expect(terminalViewKey.currentState!.hasInputConnection, isTrue);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'C\t',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    expect(terminalOutput.join(), 'C\t');
  });
}
