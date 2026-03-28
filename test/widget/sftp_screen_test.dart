import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

void main() {
  group('currentLinePrefixAtTextOffset', () {
    test('returns the current line prefix for a multiline selection', () {
      expect(currentLinePrefixAtTextOffset('alpha\nbeta\ngamma', 10), 'beta');
    });
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

  group('buildRemoteTextEditorScreenForTesting', () {
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
          closeTo(372, 0.1),
        );
        expect(horizontalScrollController.offset, greaterThan(0));
      },
    );
  });
}
