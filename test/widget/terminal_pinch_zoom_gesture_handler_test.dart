import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_pinch_zoom_gesture_handler.dart';

void main() {
  testWidgets('single-finger drag still scrolls the child', (tester) async {
    final scrollController = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: TerminalPinchZoomGestureHandler(
            child: ListView.builder(
              controller: scrollController,
              itemCount: 40,
              itemExtent: 48,
              itemBuilder: (context, index) => Text('Row $index'),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(0));
  });

  testWidgets('two-finger pinch reports scale changes', (tester) async {
    final scales = <double>[];
    var pinchStarts = 0;
    var pinchEnds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: TerminalPinchZoomGestureHandler(
            onPinchStart: () => pinchStarts += 1,
            onPinchUpdate: scales.add,
            onPinchEnd: () => pinchEnds += 1,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );

    final target = find.byType(TerminalPinchZoomGestureHandler);
    final center = tester.getCenter(target);
    final firstGesture = await tester.createGesture(pointer: 10);
    await firstGesture.down(center - const Offset(30, 0));
    await tester.pump();

    final secondGesture = await tester.createGesture(pointer: 11);
    await secondGesture.down(center + const Offset(30, 0));
    await tester.pump();

    await firstGesture.moveBy(const Offset(-20, 0));
    await secondGesture.moveBy(const Offset(20, 0));
    await tester.pump();

    await firstGesture.up();
    await secondGesture.up();
    await tester.pump();

    expect(pinchStarts, 1);
    expect(scales, isNotEmpty);
    expect(scales.last, greaterThan(1));
    expect(pinchEnds, 1);
  });
}
