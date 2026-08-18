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
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
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

  testWidgets('renders selectable markdown text', (tester) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '# Heading\n\nhello world')),
    );
    await tester.pump();
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.selectable, isTrue);
    expect(body.styleSheet?.p?.fontFamily, FluttyTheme.monoStyle.fontFamily);
    expect(body.styleSheet?.h1?.fontFamily, FluttyTheme.monoStyle.fontFamily);
    expect(
      body.styleSheet?.tableBody?.fontFamily,
      FluttyTheme.monoStyle.fontFamily,
    );
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
