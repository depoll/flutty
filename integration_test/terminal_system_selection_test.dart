import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('terminal render object supports system selection on device', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
    final selectionChanges = <SelectedContent?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: MonkeyTerminalView(
              terminal,
              key: terminalViewKey,
              controller: controller,
              readOnly: true,
              useSystemSelection: true,
              onSystemSelectionChanged: selectionChanges.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    terminal.write('selectable alpha beta gamma');
    await tester.pumpAndSettle();

    final renderTerminal = terminalViewKey.currentState!.renderTerminal;
    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    await tester.longPressAt(cellCenter(const CellOffset(13, 0)));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(controller.selection, isNotNull);
    expect(renderTerminal.getSelectedContent()?.plainText.trim(), 'alpha');
    expect(selectionChanges, isNotEmpty);
    expect(selectionChanges.last?.plainText.trim(), 'alpha');
  });
}
