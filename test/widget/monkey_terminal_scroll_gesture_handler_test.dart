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
      final localTargetRect = Offset.zero & targetRect.size;
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
      expect(output, everyElement(startsWith('\x1b[<65;')));
      expect(reportedPositions, hasLength(2));
      for (final position in reportedPositions) {
        expect(position, isNot(Offset.zero));
        expect(localTargetRect.contains(position), isTrue);
      }
    },
  );

  testWidgets(
    'trackpad reversal waits for a full line before sending a reverse step',
    (tester) async {
      final terminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final output = <String>[];
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
                  getCellOffset: (_) => const CellOffset(1, 1),
                  getLineHeight: () => 10,
                  child: const ColoredBox(
                    key: ValueKey('reverse-threshold-target'),
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(
        find.byKey(const ValueKey('reverse-threshold-target')),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );

      await gesture.panZoomStart(center);
      await tester.pump();
      await gesture.panZoomUpdate(
        center + const Offset(0, -10),
        pan: const Offset(0, -10),
      );
      await tester.pump();

      expect(output, hasLength(1));

      await gesture.panZoomUpdate(
        center + const Offset(0, -4),
        pan: const Offset(0, -4),
      );
      await tester.pump();

      expect(output, hasLength(1));

      await gesture.panZoomEnd();
      await tester.pump();
    },
  );

  testWidgets('trackpad scrolling reports SGR wheel up as button 64', (
    tester,
  ) async {
    final terminal = Terminal()
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = <String>[];
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
                getCellOffset: (_) => const CellOffset(1, 1),
                getLineHeight: () => 10,
                child: const ColoredBox(
                  key: ValueKey('sgr-wheel-up-target'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(
      find.byKey(const ValueKey('sgr-wheel-up-target')),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );

    await gesture.panZoomStart(center);
    await tester.pump();
    await gesture.panZoomUpdate(
      center + const Offset(0, 10),
      pan: const Offset(0, 10),
    );
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.single, startsWith('\x1b[<64;'));
  });

  // --- Line coalescing / remainder tests ---
  // The implementation accumulates scroll deltas in scrollRemainder and only
  // emits one wheel event per full line-height of movement.  These tests
  // document that behaviour so it is not accidentally regressed.

  testWidgets(
    'sub-line-height delta does not emit a scroll event (remainder held)',
    (tester) async {
      final terminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final output = <String>[];
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
                  getCellOffset: (_) => const CellOffset(1, 1),
                  getLineHeight: () => 20,
                  child: const ColoredBox(
                    key: ValueKey('sub-line-target'),
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(
        find.byKey(const ValueKey('sub-line-target')),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );

      await gesture.panZoomStart(center);
      await tester.pump();
      // Move 19 px — one shy of the 20 px line height.
      await gesture.panZoomUpdate(
        center + const Offset(0, -19),
        pan: const Offset(0, -19),
      );
      await tester.pump();

      // No full line reached yet; remainder is held.
      expect(output, isEmpty);

      await gesture.panZoomEnd();
      await tester.pump();
    },
  );

  testWidgets(
    'two partial deltas that together exceed one line height emit exactly one event',
    (tester) async {
      final terminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final output = <String>[];
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
                  getCellOffset: (_) => const CellOffset(1, 1),
                  getLineHeight: () => 20,
                  child: const ColoredBox(
                    key: ValueKey('two-partial-target'),
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(
        find.byKey(const ValueKey('two-partial-target')),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );

      await gesture.panZoomStart(center);
      await tester.pump();

      // First partial: 12 px — below the 20 px threshold.
      await gesture.panZoomUpdate(
        center + const Offset(0, -12),
        pan: const Offset(0, -12),
      );
      await tester.pump();
      expect(output, isEmpty);

      // Second partial: +10 px more (total 22 px) — crosses one line height.
      await gesture.panZoomUpdate(
        center + const Offset(0, -22),
        pan: const Offset(0, -22),
      );
      await tester.pump();
      expect(output, hasLength(1));

      await gesture.panZoomEnd();
      await tester.pump();
    },
  );

  testWidgets('large single delta emits one event per full line height', (
    tester,
  ) async {
    final terminal = Terminal()
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = <String>[];
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
                getCellOffset: (_) => const CellOffset(1, 1),
                getLineHeight: () => 10,
                child: const ColoredBox(
                  key: ValueKey('large-delta-target'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(
      find.byKey(const ValueKey('large-delta-target')),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );

    await gesture.panZoomStart(center);
    await tester.pump();

    // 35 px with a 10 px line height → 3 full lines, 5 px remainder held.
    await gesture.panZoomUpdate(
      center + const Offset(0, -35),
      pan: const Offset(0, -35),
    );
    await tester.pump();

    expect(output, hasLength(3));
    // All events should be wheel-up (button 65 in SGR).
    expect(output, everyElement(startsWith('\x1b[<65;')));

    await gesture.panZoomEnd();
    await tester.pump();

    // No extra event emitted at gesture end (remainder < line height).
    expect(output, hasLength(3));
  });
}
