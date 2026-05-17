// ignore_for_file: implementation_imports, public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_detector.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

int _countOccurrences(String text, String pattern) {
  var count = 0;
  var start = 0;

  while (true) {
    final index = text.indexOf(pattern, start);
    if (index == -1) {
      return count;
    }
    count += 1;
    start = index + pattern.length;
  }
}

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

  testWidgets(
    'mouse-reporting apps require more drag distance per touch scroll step',
    (tester) async {
      final expectedOutput = <String>[];
      Terminal()
        ..onOutput = expectedOutput.add
        ..keyInput(TerminalKey.arrowDown);
      final expectedArrowDown = expectedOutput.join();

      final arrowTerminal = Terminal()..useAltBuffer();
      final arrowOutput = <String>[];
      arrowTerminal.onOutput = arrowOutput.add;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              arrowTerminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
            ),
          ),
        ),
      );

      var detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: const Offset(150, 10),
          localPosition: const Offset(150, 10),
          delta: const Offset(0, -240),
        ),
      );
      await tester.pump();

      final arrowCount = _countOccurrences(
        arrowOutput.join(),
        expectedArrowDown,
      );
      expect(arrowCount, greaterThan(0));

      final wheelTerminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final wheelOutput = <String>[];
      wheelTerminal.onOutput = wheelOutput.add;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              wheelTerminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
            ),
          ),
        ),
      );

      detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: const Offset(150, 10),
          localPosition: const Offset(150, 10),
          delta: const Offset(0, -240),
        ),
      );
      await tester.pump();

      final wheelCount = _countOccurrences(wheelOutput.join(), '\u001b[<65;');
      expect(wheelCount, greaterThan(0));
      expect(wheelCount, lessThan(arrowCount));
    },
  );

  testWidgets('touch scroll keeps moving with inertia after lift-off', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
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

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(150, 100),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: const Offset(150, 40),
        localPosition: const Offset(150, 40),
        delta: const Offset(0, -60),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: const Offset(150, 10),
        localPosition: const Offset(150, 10),
        delta: const Offset(0, -60),
      ),
    );

    final beforeLiftOutputCount = output.length;
    expect(beforeLiftOutputCount, greaterThan(0));

    detector.onTouchScrollEnd!(
      DragEndDetails(
        primaryVelocity: -2000,
        velocity: const Velocity(pixelsPerSecond: Offset(0, -2000)),
      ),
    );
    await tester.pump();

    final afterLiftOutputCount = output.length;
    await tester.pump(const Duration(milliseconds: 200));

    expect(output.length, greaterThan(afterLiftOutputCount));
  });

  testWidgets('double taps invoke the terminal view callback', (tester) async {
    final terminal = Terminal();
    var doubleTapDowns = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            onDoubleTapDown: (tapDetails, cellOffset) => doubleTapDowns += 1,
          ),
        ),
      ),
    );

    final terminalFinder = find.byType(MonkeyTerminalView);
    final tapPosition = tester.getCenter(terminalFinder);
    await tester.tapAt(tapPosition);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(tapPosition);
    await tester.pump();

    expect(doubleTapDowns, 1);
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
