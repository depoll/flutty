import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_handler.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
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

    final detector = tester.widget<TerminalGestureDetector>(
      find.byType(TerminalGestureDetector),
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
}
