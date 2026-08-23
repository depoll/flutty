// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_code_block.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/cursor_block.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUp(() {
    FluttyTheme.debugUseSystemFonts = true;
    clearAcpInlineImageCache();
  });
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('renders tables, lists and quotes without error', (tester) async {
    await tester.pumpWidget(
      wrap(
        const AcpMarkdown(
          data: '''
# Heading

- item one
- item two

> a quote

| A | B |
|---|---|
| 1 | 2 |
''',
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('item one'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('uses readable proportional paragraph rhythm', (tester) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: 'First paragraph.\n\nSecond paragraph.')),
    );
    await tester.pump();

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.styleSheet?.p?.fontSize, 15);
    expect(markdown.styleSheet?.p?.height, 1.45);
    expect(markdown.styleSheet?.blockSpacing, FluttyTheme.spacingSm);
    expect(
      markdown.styleSheet?.p?.fontFamily,
      isNot(FluttyTheme.monoStyle.fontFamily),
    );
    expect(
      markdown.styleSheet?.code?.fontFamily,
      FluttyTheme.monoStyle.fontFamily,
    );
  });

  testWidgets('keeps headings and explicit machine content monospaced', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '# Heading\n\nhello world')),
    );
    await tester.pump();
    var body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.selectable, isTrue);
    expect(body.styleSheet?.h1?.fontFamily, FluttyTheme.monoStyle.fontFamily);
    expect(
      body.styleSheet?.tableHead?.fontFamily,
      FluttyTheme.monoStyle.fontFamily,
    );

    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: 'literal output', machineContent: true)),
    );
    await tester.pump();
    body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.styleSheet?.p?.fontFamily, FluttyTheme.monoStyle.fontFamily);
  });

  testWidgets('renders a syntax-highlighted code block from markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '```dart\nvoid main() {}\n```')),
    );
    await tester.pump();
    expect(find.byType(AcpCodeBlock), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
  });

  testWidgets('copies code and shows copied state', (tester) async {
    final copied = <String>[];
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

    await tester.pumpWidget(
      wrap(
        AcpCodeBlock(code: 'print("hi")', language: 'dart', onCopy: copied.add),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(copied, ['print("hi")']);
    expect(clipboardCalls, hasLength(1));
    expect((clipboardCalls.first.arguments as Map)['text'], 'print("hi")');
    expect(find.byIcon(Icons.check), findsOneWidget);

    // The copied state reverts after the timeout.
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets('wires custom link handler to MarkdownBody', (tester) async {
    var tappedHref = '';
    await tester.pumpWidget(
      wrap(
        AcpMarkdown(
          data: '[docs](https://example.com)',
          onTapLink: (text, href, title) => tappedHref = href ?? '',
        ),
      ),
    );
    await tester.pump();
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.onTapLink, isNotNull);
    body.onTapLink!('docs', 'https://example.com', '');
    expect(tappedHref, 'https://example.com');
  });

  testWidgets('renders inline image embedded in markdown', (tester) async {
    // A valid tiny transparent PNG as a data URI.
    const dataUri =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '![diagram]($dataUri)')),
    );
    await tester.pump();
    expect(find.byType(AcpInlineImage), findsOneWidget);
  });

  testWidgets('keeps parsed Markdown stable across parent rebuilds', (
    tester,
  ) async {
    const dataUri =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    late StateSetter rebuildParent;
    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return const AcpMarkdown(data: '![diagram]($dataUri)');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.widget<MarkdownBody>(find.byType(MarkdownBody));

    rebuildParent(() {});
    await tester.pump();
    final after = tester.widget<MarkdownBody>(find.byType(MarkdownBody));

    expect(identical(after, before), isTrue);
    expect(identical(after.data, before.data), isTrue);
  });

  testWidgets('reuses data-image decode across remounts', (tester) async {
    const dataUri =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    final image = AcpImageContent(uri: dataUri, label: 'diagram');

    await tester.pumpWidget(wrap(AcpInlineImage(image: image)));
    await tester.pumpAndSettle();
    expect(acpInlineDataImageDecodeCount, 1);
    expect(acpInlineImageCacheEntryCount, 1);

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(wrap(AcpInlineImage(image: image)));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpAndSettle();

    expect(acpInlineDataImageDecodeCount, 1);
    expect(acpInlineImageCacheEntryCount, 1);
  });

  testWidgets('reuses resolved file image across reverse-scroll remounts', (
    tester,
  ) async {
    var resolveCount = 0;
    final image = AcpImageContent(
      uri: 'file:///repo/screenshots/layout.png',
      label: 'layout',
    );
    Future<Uint8List?> resolve(AcpImageContent _) async {
      resolveCount++;
      return Uint8List.fromList(const [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0A,
        0x49,
        0x44,
        0x41,
        0x54,
        0x78,
        0x9C,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);
    }

    await tester.pumpWidget(
      wrap(AcpInlineImage(image: image, resolver: resolve)),
    );
    await tester.pumpAndSettle();
    expect(resolveCount, 1);
    expect(acpInlineImageCacheEntryCount, 1);

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(
      wrap(AcpInlineImage(image: image, resolver: resolve)),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();

    expect(resolveCount, 1);
    expect(acpInlineImageCacheEntryCount, 1);
  });

  testWidgets('renders a provider-wrapped inline data image', (tester) async {
    const wrappedDataUri =
        'data:image/\n'
        'png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC\n'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '![diagram]($wrappedDataUri)')),
    );
    await tester.pump();

    expect(find.textContaining('base64'), findsNothing);
    expect(find.byType(AcpInlineImage), findsOneWidget);
  });

  testWidgets('streaming assistant leaves cursor to chat viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          entries: [
            AcpAssistantMessageEntry(
              id: 'a1',
              markdown: 'thinking',
              status: AcpStreamStatus.streaming,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CursorBlock), findsNothing);
  });

  testWidgets('completed assistant message has no cursor block', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          entries: [AcpAssistantMessageEntry(id: 'a1', markdown: 'done')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CursorBlock), findsNothing);
  });

  testWidgets('buildAcpHighlightSpans is resilient to bad input', (
    tester,
  ) async {
    final spans = buildAcpHighlightSpans(
      'plain text',
      theme: defaultAcpSyntaxTheme(Brightness.dark),
    );
    expect(spans, isNotEmpty);
  });
}
