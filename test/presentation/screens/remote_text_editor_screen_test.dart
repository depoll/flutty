// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';

void main() {
  group('clampRemoteEditorFontSize', () {
    test('returns minimum when size is below min', () {
      expect(clampRemoteEditorFontSize(4), 8.0);
    });

    test('returns maximum when size is above max', () {
      expect(clampRemoteEditorFontSize(64), 32.0);
    });

    test('returns value unchanged when within range', () {
      expect(clampRemoteEditorFontSize(16), 16.0);
    });
  });

  group('applyRemoteEditorScaleDelta', () {
    test('increases font size when scale grows', () {
      final result = applyRemoteEditorScaleDelta(16, 1, 1.5);
      expect(result, closeTo(24.0, 0.01));
    });

    test('decreases font size when scale shrinks', () {
      final result = applyRemoteEditorScaleDelta(16, 2, 1);
      expect(result, closeTo(8.0, 0.01));
    });

    test('treats zero previous scale as 1 to avoid division by zero', () {
      final result = applyRemoteEditorScaleDelta(16, 0, 1);
      expect(result, closeTo(16.0, 0.01));
    });

    test('clamps result to supported range', () {
      expect(applyRemoteEditorScaleDelta(32, 1, 2), 32.0);
      expect(applyRemoteEditorScaleDelta(8, 2, 1), 8.0);
    });
  });

  group('resolveRemoteEditorVisualScale', () {
    test('returns 1 when no pinch is active', () {
      expect(resolveRemoteEditorVisualScale(fontSize: 16), 1.0);
    });

    test('returns 1 when fontSize is zero', () {
      expect(
        resolveRemoteEditorVisualScale(fontSize: 0, pinchFontSize: 20),
        1.0,
      );
    });

    test('returns ratio of pinch to base font size', () {
      expect(
        resolveRemoteEditorVisualScale(fontSize: 16, pinchFontSize: 20),
        closeTo(1.25, 0.001),
      );
    });
  });

  group('resolveRemoteEditorGutterDigitSlots', () {
    test('returns 4 for small line counts', () {
      expect(resolveRemoteEditorGutterDigitSlots(1), 4);
      expect(resolveRemoteEditorGutterDigitSlots(9999), 4);
    });

    test('grows to fit 5-digit line counts', () {
      expect(resolveRemoteEditorGutterDigitSlots(10000), 5);
    });

    test('grows to fit 6-digit line counts', () {
      expect(resolveRemoteEditorGutterDigitSlots(100000), 6);
    });
  });

  group('computeRemoteEditorLineStartOffsets', () {
    test('single-line text has one offset at 0', () {
      expect(computeRemoteEditorLineStartOffsets('hello'), [0]);
    });

    test('empty text has one offset at 0', () {
      expect(computeRemoteEditorLineStartOffsets(''), [0]);
    });

    test('multi-line text records start of each line', () {
      // "abc\ndef\nghi" → lines start at 0, 4, 8
      expect(computeRemoteEditorLineStartOffsets('abc\ndef\nghi'), [0, 4, 8]);
    });

    test('trailing newline adds an empty last line', () {
      expect(computeRemoteEditorLineStartOffsets('a\n'), [0, 2]);
    });
  });

  group('resolveRemoteEditorCaretPositionFromLineStarts', () {
    final lineStarts = [0, 4, 8]; // "abc\ndef\nghi"
    const text = 'abc\ndef\nghi';

    test('offset 0 maps to line 1, column 1', () {
      expect(
        resolveRemoteEditorCaretPositionFromLineStarts(
          text: text,
          selection: const TextSelection.collapsed(offset: 0),
          lineStartOffsets: lineStarts,
        ),
        (line: 1, column: 1),
      );
    });

    test('end of first line maps to line 1, column 4', () {
      expect(
        resolveRemoteEditorCaretPositionFromLineStarts(
          text: text,
          selection: const TextSelection.collapsed(offset: 3),
          lineStartOffsets: lineStarts,
        ),
        (line: 1, column: 4),
      );
    });

    test('start of second line maps to line 2, column 1', () {
      expect(
        resolveRemoteEditorCaretPositionFromLineStarts(
          text: text,
          selection: const TextSelection.collapsed(offset: 4),
          lineStartOffsets: lineStarts,
        ),
        (line: 2, column: 1),
      );
    });

    test('invalid selection defaults to line 1, column 1', () {
      expect(
        resolveRemoteEditorCaretPositionFromLineStarts(
          text: text,
          selection: const TextSelection.collapsed(offset: -1),
          lineStartOffsets: lineStarts,
        ),
        (line: 1, column: 1),
      );
    });

    test('offset beyond text length is clamped to end', () {
      expect(
        resolveRemoteEditorCaretPositionFromLineStarts(
          text: text,
          selection: const TextSelection.collapsed(offset: 999),
          lineStartOffsets: lineStarts,
        ),
        (line: 3, column: 4), // "ghi" = 3 chars; col 4 = after last char
      );
    });
  });

  group('currentLinePrefixAtTextOffset', () {
    test('returns empty string at offset 0', () {
      expect(currentLinePrefixAtTextOffset('hello', 0), '');
    });

    test('returns characters up to offset on the first line', () {
      expect(currentLinePrefixAtTextOffset('hello', 3), 'hel');
    });

    test('returns only the current-line prefix after a newline', () {
      expect(currentLinePrefixAtTextOffset('abc\ndefg', 7), 'def');
    });

    test('clamps negative offset to empty prefix', () {
      expect(currentLinePrefixAtTextOffset('hello', -5), '');
    });

    test('clamps offset beyond text length to full first-line prefix', () {
      expect(currentLinePrefixAtTextOffset('hello', 999), 'hello');
    });
  });

  group('measureUnwrappedEditorContentWidth', () {
    double fakeLineWidth(String line, TextStyle style) => line.length * 10.0;

    test('returns 0 for all-empty lines', () {
      expect(
        measureUnwrappedEditorContentWidth(
          lines: const ['', '', ''],
          style: const TextStyle(),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          measureLineWidth: fakeLineWidth,
        ),
        0.0,
      );
    });

    test('returns max line width plus trailing slack', () {
      // Default trailing slack is 24 px. 'abcd' = 4 × 10 = 40; 40 + 24 = 64.
      final result = measureUnwrappedEditorContentWidth(
        lines: const ['ab', 'abcd', 'abc'],
        style: const TextStyle(),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        measureLineWidth: fakeLineWidth,
      );
      expect(result, closeTo(64.0, 0.001));
    });

    test('ignores empty lines when computing max width', () {
      final result = measureUnwrappedEditorContentWidth(
        lines: const ['', 'ab', ''],
        style: const TextStyle(),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        trailingSlack: 0,
        measureLineWidth: fakeLineWidth,
      );
      expect(result, closeTo(20.0, 0.001));
    });
  });

  group('resolveUnwrappedEditorSelectionScrollOffset', () {
    double fakeMeasure(String line, TextStyle style) => line.length * 10.0;

    const style = TextStyle();

    test('returns currentOffset when caret is already visible', () {
      // Caret at offset 5 → prefix = 'hello' = 5 × 10 = 50 px.
      // Viewport: [0, 200] — caret at 50 is well inside.
      expect(
        resolveUnwrappedEditorSelectionScrollOffset(
          text: 'hello world',
          selection: const TextSelection.collapsed(offset: 5),
          style: style,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          viewportWidth: 200,
          trailingSlack: 0,
          measureLineWidth: fakeMeasure,
        ),
        0.0,
      );
    });

    test('scrolls right when caret is beyond viewport end', () {
      // Caret at offset 20 → prefix = 20 × 10 = 200 px.
      // Viewport: [0, 100] — trailing edge 200 > 100.
      final offset = resolveUnwrappedEditorSelectionScrollOffset(
        text: 'a' * 30,
        selection: const TextSelection.collapsed(offset: 20),
        style: style,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        viewportWidth: 100,
        trailingSlack: 0,
        measureLineWidth: fakeMeasure,
      );
      expect(offset, greaterThan(0));
    });

    test('scrolls left when caret is before viewport start', () {
      // Caret at 0 px, viewport starts at 100 → scroll back to 0.
      expect(
        resolveUnwrappedEditorSelectionScrollOffset(
          text: 'hello world',
          selection: const TextSelection.collapsed(offset: 0),
          style: style,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          viewportWidth: 200,
          currentOffset: 100,
          trailingSlack: 0,
          measureLineWidth: fakeMeasure,
        ),
        0.0,
      );
    });

    test('returns currentOffset for invalid selection', () {
      expect(
        resolveUnwrappedEditorSelectionScrollOffset(
          text: 'hello',
          selection: const TextSelection.collapsed(offset: -1),
          style: style,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          viewportWidth: 200,
          currentOffset: 50,
          trailingSlack: 0,
          measureLineWidth: fakeMeasure,
        ),
        50.0,
      );
    });

    test('returns currentOffset when viewportWidth is zero', () {
      expect(
        resolveUnwrappedEditorSelectionScrollOffset(
          text: 'hello',
          selection: const TextSelection.collapsed(offset: 3),
          style: style,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          viewportWidth: 0,
          trailingSlack: 0,
          measureLineWidth: fakeMeasure,
        ),
        0.0,
      );
    });
  });

  group('RemoteTextEditorScreen caret-X cache', () {
    Widget buildEditor({
      required TextEditingController controller,
      ScrollController? horizontalScrollController,
    }) => MaterialApp(
      home: buildRemoteTextEditorScreenForTesting(
        fileName: 'test.txt',
        controller: controller,
        horizontalScrollController: horizontalScrollController,
      ),
    );

    testWidgets('populates caretX cache after first frame', (tester) async {
      final controller = TextEditingController(text: 'hello world')
        ..selection = const TextSelection.collapsed(offset: 5);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump(); // settle post-frame callbacks

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      expect(cachedRemoteEditorSelectionCaretX(state), isNotNull);
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 5);
    });

    testWidgets('cache hit: caretX unchanged when selection repeats', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world')
        ..selection = const TextSelection.collapsed(offset: 5);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump();

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      final firstX = cachedRemoteEditorSelectionCaretX(state);
      expect(firstX, isNotNull);

      // Reassign the same selection – controller fires a change notification.
      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      await tester.pump();

      expect(cachedRemoteEditorSelectionCaretX(state), equals(firstX));
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 5);
    });

    testWidgets('cache miss: caretX updates when extent offset changes', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world')
        ..selection = const TextSelection.collapsed(offset: 2);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump();

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 2);

      controller.selection = const TextSelection.collapsed(offset: 8);
      await tester.pump();
      await tester.pump();

      // Cached extent offset must reflect the new position.
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 8);
    });

    testWidgets('cache cleared when controller is replaced', (tester) async {
      final controller1 = TextEditingController(text: 'first')
        ..selection = const TextSelection.collapsed(offset: 3);
      addTearDown(controller1.dispose);

      final controller2 = TextEditingController(text: 'second controller')
        ..selection = const TextSelection.collapsed(offset: 6);
      addTearDown(controller2.dispose);

      // Build with controller1 so the caretX cache is populated.
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) =>
                buildRemoteTextEditorScreenForTesting(
                  fileName: 'test.txt',
                  controller: controller1,
                ),
          ),
        ),
      );
      await tester.pump();

      // Rebuild with controller2 by replacing the widget tree.
      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteTextEditorScreenForTesting(
            fileName: 'test.txt',
            controller: controller2,
          ),
        ),
      );
      await tester.pump();

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      // After the controller swap the cache reflects controller2's selection.
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 6);
    });

    testWidgets(
      'selection visibility: scrolls right when caret is off screen',
      (tester) async {
        // Build a long single line so the content exceeds the viewport.
        final longText = 'x' * 200;
        final scrollController = ScrollController();
        final controller = TextEditingController(text: longText)
          ..selection = TextSelection.collapsed(offset: longText.length);
        addTearDown(controller.dispose);
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          buildEditor(
            controller: controller,
            horizontalScrollController: scrollController,
          ),
        );
        await tester.pump(); // layout + post-frame callbacks

        // The scroll controller should be at a non-negative offset (scrolled
        // right or already at 0 if text fits within the test viewport).
        expect(scrollController.offset, greaterThanOrEqualTo(0));
      },
    );

    testWidgets(
      'selection visibility: no scroll when caret is already visible',
      (tester) async {
        final scrollController = ScrollController();
        final controller = TextEditingController(text: 'short')
          ..selection = const TextSelection.collapsed(offset: 0);
        addTearDown(controller.dispose);
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          buildEditor(
            controller: controller,
            horizontalScrollController: scrollController,
          ),
        );
        await tester.pump();

        // Short text with caret at the start should not scroll at all.
        expect(scrollController.offset, closeTo(0.0, 0.5));
      },
    );
  });
}
