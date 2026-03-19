// ignore_for_file: implementation_imports, public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_scroll_gesture_handler.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets(
    'trackpad scrolling preserves the gesture location in alt buffer',
    (tester) async {
      final terminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final output = <String>[];
      final reportedPositions = <Offset>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: MonkeyTerminalScrollGestureHandler(
                  terminal: terminal,
                  simulateScroll: false,
                  getCellOffset: (offset) {
                    reportedPositions.add(offset);
                    return CellOffset(offset.dx ~/ 10, offset.dy ~/ 10);
                  },
                  getLineHeight: () => 10,
                  child: const ColoredBox(
                    key: ValueKey('trackpad-target'),
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(
        find.byKey(const ValueKey('trackpad-target')),
      );
      final targetRect = tester.getRect(
        find.byKey(const ValueKey('trackpad-target')),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );

      await gesture.panZoomStart(center + const Offset(20, -10));
      await tester.pump();
      await gesture.panZoomUpdate(
        center + const Offset(20, -30),
        pan: const Offset(0, -20),
      );
      await tester.pump();
      await gesture.panZoomEnd();
      await tester.pump();

      expect(output, hasLength(2));
      expect(reportedPositions, hasLength(2));
      for (final position in reportedPositions) {
        expect(position, isNot(Offset.zero));
        expect(targetRect.contains(position), isTrue);
      }
    },
  );
}
