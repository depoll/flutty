import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_detector.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_handler.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('tertiary taps invoke tertiary callbacks', (tester) async {
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            key: terminalViewKey,
            Terminal(),
            readOnly: true,
          ),
        ),
      ),
    );

    final terminalViewState = terminalViewKey.currentState!;
    var secondaryTapDowns = 0;
    var secondaryTapUps = 0;
    var tertiaryTapDowns = 0;
    var tertiaryTapUps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalGestureHandler(
            terminalView: terminalViewState,
            terminalController: TerminalController(),
            readOnly: true,
            onSecondaryTapDown: (_) => secondaryTapDowns += 1,
            onSecondaryTapUp: (_) => secondaryTapUps += 1,
            onTertiaryTapDown: (_) => tertiaryTapDowns += 1,
            onTertiaryTapUp: (_) => tertiaryTapUps += 1,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTertiaryTapDown!(
      TapDownDetails(localPosition: const Offset(10, 10)),
    );
    detector.onTertiaryTapUp!(
      TapUpDetails(
        kind: PointerDeviceKind.mouse,
        localPosition: const Offset(10, 10),
      ),
    );

    expect(secondaryTapDowns, 0);
    expect(secondaryTapUps, 0);
    expect(tertiaryTapDowns, 1);
    expect(tertiaryTapUps, 1);
  });

  testWidgets('link taps bypass terminal mouse callbacks', (tester) async {
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            key: terminalViewKey,
            Terminal(),
            readOnly: true,
          ),
        ),
      ),
    );

    final terminalViewState = terminalViewKey.currentState!;
    var tapDowns = 0;
    var tapUps = 0;
    final openedLinks = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalGestureHandler(
            terminalView: terminalViewState,
            terminalController: TerminalController(),
            readOnly: true,
            resolveLinkTap: (_) => 'https://github.com/features/copilot',
            onLinkTap: openedLinks.add,
            onTapDown: (_) => tapDowns += 1,
            onSingleTapUp: (_) => tapUps += 1,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTapDown!(TapDownDetails(localPosition: const Offset(10, 10)));
    detector.onSingleTapUp!(
      TapUpDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(10, 10),
      ),
    );

    expect(openedLinks, ['https://github.com/features/copilot']);
    expect(tapDowns, 0);
    expect(tapUps, 0);
  });

  testWidgets('touch scroll clears any pending link tap', (tester) async {
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            key: terminalViewKey,
            Terminal(),
            readOnly: true,
          ),
        ),
      ),
    );

    final terminalViewState = terminalViewKey.currentState!;
    var tapUps = 0;
    final openedLinks = <String>[];
    var touchScrollStarts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalGestureHandler(
            terminalView: terminalViewState,
            terminalController: TerminalController(),
            readOnly: true,
            resolveLinkTap: (localPosition) => localPosition.dx < 20
                ? 'https://github.com/features/copilot'
                : null,
            onLinkTap: openedLinks.add,
            onSingleTapUp: (_) => tapUps += 1,
            onTouchScrollStart: (_) => touchScrollStarts += 1,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTapDown!(TapDownDetails(localPosition: const Offset(10, 10)));
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(40, 10),
      ),
    );
    detector.onSingleTapUp!(
      TapUpDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(40, 10),
      ),
    );

    expect(openedLinks, isEmpty);
    expect(tapUps, 1);
    expect(touchScrollStarts, 1);
  });
}
