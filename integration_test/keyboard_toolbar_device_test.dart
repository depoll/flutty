import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:xterm/xterm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'preserves Ctrl modifier state across toolbar rebuilds for system keyboard input',
    (tester) async {
      final terminal = Terminal();
      final controller = KeyboardToolbarController();

      Widget buildToolbar() => MaterialApp(
        home: Scaffold(
          body: KeyboardToolbar(terminal: terminal, controller: controller),
        ),
      );

      await tester.pumpWidget(buildToolbar());

      await tester.tap(find.text('Ctrl'));
      await tester.pump();

      expect(controller.isCtrlActive, isTrue);

      await tester.pumpWidget(buildToolbar());
      await tester.pump();

      expect(controller.applySystemKeyboardModifiers('b'), '\u0002');
      expect(controller.isCtrlActive, isFalse);
    },
  );
}
