// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_diff.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';
import 'package:monkeyssh/presentation/widgets/acp_thought.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';

final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget wrap(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  group('AcpToolCallView', () {
    testWidgets('renders every status with an icon and label', (tester) async {
      const expectations = {
        AcpToolStatus.pending: ('Pending', Icons.schedule),
        AcpToolStatus.running: ('Running', Icons.sync),
        AcpToolStatus.completed: ('Completed', Icons.check_circle_outline),
        AcpToolStatus.failed: ('Failed', Icons.error_outline),
        AcpToolStatus.cancelled: ('Cancelled', Icons.cancel_outlined),
      };
      for (final entry in expectations.entries) {
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              toolCall: AcpToolCall(
                id: '1',
                title: 'Run tests',
                status: entry.key,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text(entry.value.$1), findsOneWidget);
        expect(find.byIcon(entry.value.$2), findsOneWidget);
      }
    });

    testWidgets('expands to show input and output', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AcpToolCallView(
            toolCall: AcpToolCall(
              id: '1',
              title: 'Read file',
              status: AcpToolStatus.completed,
              rawInput: 'path: pubspec.yaml',
              rawOutput: 'name: monkeyssh',
            ),
          ),
        ),
      );
      await tester.pump();
      // Collapsed initially.
      expect(find.text('path: pubspec.yaml'), findsNothing);

      await tester.tap(find.text('Read file'));
      await tester.pump();
      expect(find.text('Input'), findsOneWidget);
      expect(find.text('path: pubspec.yaml'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
      expect(find.text('name: monkeyssh'), findsOneWidget);
    });

    testWidgets('renders locations and fires open callback', (tester) async {
      AcpToolLocation? opened;
      await tester.pumpWidget(
        wrap(
          AcpToolCallView(
            initiallyExpanded: true,
            onOpenLocation: (loc) => opened = loc,
            toolCall: const AcpToolCall(
              id: '1',
              title: 'Edit',
              status: AcpToolStatus.completed,
              locations: [AcpToolLocation(path: 'lib/main.dart', line: 42)],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('lib/main.dart:42'), findsOneWidget);
      await tester.tap(find.text('lib/main.dart:42'));
      expect(opened?.path, 'lib/main.dart');
      expect(opened?.line, 42);
    });

    testWidgets('renders a unified diff inside a tool call', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AcpToolCallView(
            initiallyExpanded: true,
            toolCall: AcpToolCall(
              id: '1',
              title: 'Apply patch',
              kind: AcpToolKind.edit,
              status: AcpToolStatus.completed,
              diffs: [
                AcpDiff(
                  path: 'lib/a.dart',
                  unifiedDiff:
                      '@@ -1,2 +1,2 @@\n-old line\n+new line\n context',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AcpDiffView), findsOneWidget);
      expect(find.text('-old line'), findsOneWidget);
      expect(find.text('+new line'), findsOneWidget);
    });
  });

  group('AcpDiffView', () {
    testWidgets('shows path header and diff lines', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AcpDiffView(
            diff: AcpDiff(
              path: 'src/file.ts',
              unifiedDiff: '@@ -1 +1 @@\n-a\n+b',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('src/file.ts'), findsOneWidget);
      expect(find.text('-a'), findsOneWidget);
      expect(find.text('+b'), findsOneWidget);
    });
  });

  group('AcpThoughtView', () {
    testWidgets('collapsed by default and expands on tap', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AcpThoughtView(
            entry: AcpThoughtEntry(
              id: 'th1',
              markdown: 'secret reasoning here',
              title: 'Analysis',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Analysis'), findsOneWidget);
      expect(find.text('secret reasoning here'), findsNothing);

      await tester.tap(find.text('Analysis'));
      await tester.pump();
      expect(find.text('secret reasoning here'), findsOneWidget);
    });

    testWidgets('shows streaming label while streaming', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AcpThoughtView(
            entry: AcpThoughtEntry(
              id: 'th1',
              markdown: 'x',
              status: AcpStreamStatus.streaming,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Thinking…'), findsOneWidget);
    });
  });

  group('AcpInlineImage', () {
    testWidgets('renders in-memory bytes', (tester) async {
      await tester.pumpWidget(
        wrap(AcpInlineImage(image: AcpImageContent(bytes: _pngBytes))),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('decodes a data URI', (tester) async {
      const dataUri =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      await tester.pumpWidget(
        wrap(const AcpInlineImage(image: AcpImageContent(uri: dataUri))),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('shows placeholder when a network image has no resolver', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const AcpInlineImage(
            image: AcpImageContent(
              uri: 'https://example.com/a.png',
              label: 'remote diagram',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('remote diagram'), findsOneWidget);
    });

    testWidgets('uses the resolver for file/network images', (tester) async {
      var called = false;
      await tester.pumpWidget(
        wrap(
          AcpInlineImage(
            image: const AcpImageContent(uri: 'file:///tmp/a.png'),
            resolver: (image) async {
              called = true;
              return _pngBytes;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(called, isTrue);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('shows an error placeholder when resolver returns null', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          AcpInlineImage(
            image: const AcpImageContent(uri: 'file:///tmp/a.png'),
            resolver: (image) async => null,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Image failed to load'), findsOneWidget);
    });

    testWidgets('fires tap callback', (tester) async {
      AcpImageContent? tapped;
      final image = AcpImageContent(bytes: _pngBytes, label: 'diagram');
      await tester.pumpWidget(
        wrap(AcpInlineImage(image: image, onTap: (i) => tapped = i)),
      );
      await tester.pump();
      await tester.tap(find.byType(AcpInlineImage));
      expect(tapped, image);
    });
  });

  group('AcpResourceChip', () {
    testWidgets('shows name, metadata and fires open/copy callbacks', (
      tester,
    ) async {
      final clipboardCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCalls.add(call);
          }
          return null;
        },
      );

      AcpResourceRef? opened;
      AcpResourceRef? copied;
      await tester.pumpWidget(
        wrap(
          AcpResourceChip(
            resource: const AcpResourceRef(
              uri: 'file:///a/report.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 2048,
            ),
            onOpen: (r) => opened = r,
            onCopy: (r) => copied = r,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('application/pdf · 2 KB'), findsOneWidget);

      await tester.tap(find.text('report.pdf'));
      expect(opened?.uri, 'file:///a/report.pdf');

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(copied?.uri, 'file:///a/report.pdf');
      expect(
        (clipboardCalls.single.arguments as Map)['text'],
        'file:///a/report.pdf',
      );

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  });
}
