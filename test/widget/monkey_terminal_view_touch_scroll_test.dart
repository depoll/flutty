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

class _RecordingScrollBehavior extends ScrollBehavior {
  const _RecordingScrollBehavior(this.ballisticVelocities);

  final List<double> ballisticVelocities;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      _RecordingScrollPhysics(ballisticVelocities.add);
}

class _RecordingScrollPhysics extends ScrollPhysics {
  const _RecordingScrollPhysics(this.recordVelocity, {super.parent});

  final ValueChanged<double> recordVelocity;

  @override
  _RecordingScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _RecordingScrollPhysics(recordVelocity, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    recordVelocity(velocity);
    return super.createBallisticSimulation(position, velocity);
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
    'forced touch scroll sends SGR wheel before mouse mode is known',
    (tester) async {
      final terminal = Terminal();
      final output = <String>[];
      terminal.onOutput = output.add;

      final arrowOutput = <String>[];
      Terminal()
        ..onOutput = arrowOutput.add
        ..keyInput(TerminalKey.arrowDown);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
              simulateScroll: false,
              forceSgrTouchScroll: true,
            ),
          ),
        ),
      );

      await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
      await tester.pump();

      expect(output.join(), contains('\u001b[<65;'));
      expect(output.join(), isNot(contains(arrowOutput.join())));
    },
  );

  testWidgets('forced SGR touch scroll emits one event per dragged row', (
    tester,
  ) async {
    final terminal = Terminal();
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
            simulateScroll: false,
            forceSgrTouchScroll: true,
          ),
        ),
      ),
    );

    final terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    expect(lineHeight, greaterThan(0));

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
        globalPosition: Offset(150, 100 - lineHeight * 0.75),
        localPosition: Offset(150, 100 - lineHeight * 0.75),
        delta: Offset(0, -lineHeight * 0.75),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);

    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - lineHeight),
        localPosition: Offset(150, 100 - lineHeight),
        delta: Offset(0, -lineHeight * 0.25),
      ),
    );
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.single, startsWith('\u001b[<65;'));
  });

  testWidgets(
    'mouse reporting and arrow fallback use the same touch scroll steps',
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
      expect(wheelCount, arrowCount);
    },
  );

  testWidgets('direct terminal scrollback accelerates touch drags', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(scrollController.offset, greaterThan(100));
    final gesture = await tester.createGesture();
    await gesture.down(tester.getCenter(find.byType(MonkeyTerminalView)));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    final offsetAfterDragStart = scrollController.offset;
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    expect(offsetAfterDragStart - scrollController.offset, closeTo(60, 0.01));
    await gesture.up();
  });

  testWidgets('direct touch fling uses the same accelerated gain', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    final ballisticVelocities = <double>[];
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ScrollConfiguration(
          behavior: _RecordingScrollBehavior(ballisticVelocities),
          child: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              scrollController: scrollController,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.fling(
      find.byType(MonkeyTerminalView),
      const Offset(0, 80),
      1000,
    );
    await tester.pump();

    expect(ballisticVelocities, isNotEmpty);
    expect(
      ballisticVelocities.any((velocity) => velocity.abs() > 2000),
      isTrue,
    );
  });

  testWidgets('direct terminal scrollback keeps trackpad drags at 1x', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(MonkeyTerminalView));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(center);
    await gesture.panZoomUpdate(
      center + const Offset(0, 20),
      pan: const Offset(0, 20),
    );
    await tester.pump();

    final offsetAfterFirstUpdate = scrollController.offset;
    await gesture.panZoomUpdate(
      center + const Offset(0, 40),
      pan: const Offset(0, 40),
    );
    await tester.pump();

    expect(offsetAfterFirstUpdate - scrollController.offset, closeTo(20, 0.01));
    await gesture.panZoomEnd();
  });

  testWidgets('direct terminal scrollback keeps mouse wheels at 1x', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final offsetBeforeWheel = scrollController.offset;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(MonkeyTerminalView)),
        scrollDelta: const Offset(0, -20),
      ),
    );
    await tester.pump();

    expect(offsetBeforeWheel - scrollController.offset, closeTo(20, 0.01));
  });

  testWidgets('direct scroll physics leaves ambient parenting to Scrollable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(Terminal(), hardwareKeyboardOnly: true),
        ),
      ),
    );

    final scrollable = tester.widget<Scrollable>(find.byType(Scrollable));
    expect(scrollable.physics?.parent, isNull);
  });

  testWidgets('scroll reset clears pending touch scroll distance', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
    final output = <String>[];
    terminal.onOutput = output.add;

    Widget buildTerminal(int scrollResetGeneration) => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 200,
        child: MonkeyTerminalView(
          terminal,
          hardwareKeyboardOnly: true,
          touchScrollToTerminal: true,
          scrollResetGeneration: scrollResetGeneration,
        ),
      ),
    );

    await tester.pumpWidget(buildTerminal(0));
    var terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    expect(lineHeight, greaterThan(0));
    final partialDelta = lineHeight * 0.75;

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
        globalPosition: Offset(150, 100 - partialDelta),
        localPosition: Offset(150, 100 - partialDelta),
        delta: Offset(0, -partialDelta),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);

    await tester.pumpWidget(buildTerminal(1));
    terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    expect(terminalState.renderTerminal.lineHeight, lineHeight);

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
        globalPosition: Offset(150, 100 - partialDelta),
        localPosition: Offset(150, 100 - partialDelta),
        delta: Offset(0, -partialDelta),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets('scroll reset clears pending trackpad scroll distance', (
    tester,
  ) async {
    final terminal = Terminal()
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = <String>[];
    terminal.onOutput = output.add;

    Widget buildTerminal(int scrollResetGeneration) => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 200,
        child: MonkeyTerminalView(
          terminal,
          hardwareKeyboardOnly: true,
          simulateScroll: false,
          scrollResetGeneration: scrollResetGeneration,
        ),
      ),
    );

    await tester.pumpWidget(buildTerminal(0));
    final terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    expect(lineHeight, greaterThan(0));
    final partialDelta = lineHeight * 0.75;

    final terminalFinder = find.byType(MonkeyTerminalView);
    final center = tester.getCenter(terminalFinder);
    var gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(center);
    await tester.pump();
    await gesture.panZoomUpdate(
      center + Offset(0, -partialDelta),
      pan: Offset(0, -partialDelta),
    );
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump();

    expect(output, isEmpty);

    await tester.pumpWidget(buildTerminal(1));

    gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(center);
    await tester.pump();
    await gesture.panZoomUpdate(
      center + Offset(0, -partialDelta),
      pan: Offset(0, -partialDelta),
    );
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump();

    expect(output, isEmpty);
  });

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
