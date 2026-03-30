import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';

void main() {
  group('currentLinePrefixAtTextOffset', () {
    test('returns the current line prefix for a multiline selection', () {
      expect(currentLinePrefixAtTextOffset('alpha\nbeta\ngamma', 10), 'beta');
    });
  });

  group('resolveRemoteEditorGutterDigitSlots', () {
    test('keeps four digits by default and grows for larger files', () {
      expect(resolveRemoteEditorGutterDigitSlots(1), 4);
      expect(resolveRemoteEditorGutterDigitSlots(9999), 4);
      expect(resolveRemoteEditorGutterDigitSlots(10000), 5);
    });
  });

  group('remote editor zoom helpers', () {
    test('clamps remote editor font size to the supported range', () {
      expect(clampRemoteEditorFontSize(2), 8);
      expect(clampRemoteEditorFontSize(18), 18);
      expect(clampRemoteEditorFontSize(64), 32);
    });

    test(
      'applies pinch scale deltas safely when previous scale is nonpositive',
      () {
        expect(applyRemoteEditorScaleDelta(16, 0, 2), 32);
        expect(applyRemoteEditorScaleDelta(16, -1, 0.5), 8);
      },
    );
  });

  group('resolveUnwrappedEditorSelectionScrollOffset', () {
    test('scrolls right when the caret moves beyond the viewport', () {
      expect(
        resolveUnwrappedEditorSelectionScrollOffset(
          text: '0123456789',
          selection: const TextSelection.collapsed(offset: 10),
          style: const TextStyle(),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          viewportWidth: 40,
          trailingSlack: 5,
          measureLineWidth: (line, _) => (line.length * 10).toDouble(),
        ),
        65,
      );
    });

    test('scrolls left when the caret moves before the viewport', () {
      expect(
        resolveUnwrappedEditorSelectionScrollOffset(
          text: '0123456789',
          selection: const TextSelection.collapsed(offset: 2),
          style: const TextStyle(),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          viewportWidth: 40,
          currentOffset: 70,
          trailingSlack: 5,
          measureLineWidth: (line, _) => (line.length * 10).toDouble(),
        ),
        15,
      );
    });
  });

  group('resolveRemoteEditorCaretPosition', () {
    test('returns the current line and column from the selection offset', () {
      expect(
        resolveRemoteEditorCaretPosition(
          'alpha\nbeta\ngamma',
          const TextSelection.collapsed(offset: 7),
        ),
        (line: 2, column: 2),
      );
    });
  });

  group('buildRemoteTextEditorScreenForTesting', () {
    test('uses Menlo for the system monospace font on iOS', () {
      expect(
        resolveRemoteEditorTextStyle(
          'monospace',
          platform: TargetPlatform.iOS,
        ).fontFamily,
        'Menlo',
      );
    });

    test('uses the configured terminal font family when provided', () {
      expect(
        resolveRemoteEditorTextStyle(
          'Custom Mono',
          platform: TargetPlatform.android,
        ).fontFamily,
        'Custom Mono',
      );
    });

    testWidgets(
      'keeps the nowrap viewport fixed while scrolling the selection into view',
      (tester) async {
        final longLine = List<String>.filled(80, '0123456789').join();
        final controller = TextEditingController(text: longLine)
          ..selection = TextSelection.collapsed(offset: longLine.length);
        final horizontalScrollController = ScrollController();

        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          horizontalScrollController.dispose();
          controller.dispose();
        });

        await tester.binding.setSurfaceSize(const Size(420, 720));
        await tester.pumpWidget(
          MaterialApp(
            home: buildRemoteTextEditorScreenForTesting(
              fileName: 'notes.txt',
              controller: controller,
              horizontalScrollController: horizontalScrollController,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .getSize(
                find.byKey(
                  const ValueKey<String>('remoteTextEditorNowrapViewport'),
                ),
              )
              .width,
          closeTo(333.2, 0.1),
        );
        expect(
          tester
              .getSize(
                find.byKey(const ValueKey<String>('remoteTextEditorSurface')),
              )
              .width,
          closeTo(396, 0.1),
        );
        expect(
          tester
              .getTopRight(
                find.byKey(
                  const ValueKey<String>('remoteTextEditorNowrapViewport'),
                ),
              )
              .dx,
          lessThanOrEqualTo(
            tester
                .getTopRight(
                  find.byKey(const ValueKey<String>('remoteTextEditorSurface')),
                )
                .dx,
          ),
        );
        expect(horizontalScrollController.offset, greaterThan(0));
        expect(find.byType(InputDecorator), findsNothing);
      },
    );

    testWidgets('shows status details plus wrap and zoom controls', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'alpha\nbeta')
        ..selection = const TextSelection.collapsed(offset: 7);

      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: buildRemoteTextEditorScreenForTesting(
            fileName: 'notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Line 2, Column 2'), findsOneWidget);
      expect(find.text('Wrap off'), findsOneWidget);
      expect(find.text('14 pt'), findsOneWidget);
      expect(find.byTooltip('Enable line wrap'), findsOneWidget);
      expect(find.byTooltip('Zoom out'), findsOneWidget);
      expect(find.byTooltip('Zoom in'), findsOneWidget);

      await tester.tap(find.byTooltip('Enable line wrap'));
      await tester.pumpAndSettle();

      expect(find.text('Wrap on'), findsOneWidget);
      expect(find.byTooltip('Disable line wrap'), findsOneWidget);
    });

    testWidgets('hides zoom buttons on touch-first platforms', (tester) async {
      final controller = TextEditingController(text: 'alpha\nbeta');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: buildRemoteTextEditorScreenForTesting(
            fileName: 'notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Zoom out'), findsNothing);
      expect(find.byTooltip('Zoom in'), findsNothing);
    });
  });
}
