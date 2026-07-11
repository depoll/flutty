// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_plan.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';
import 'package:monkeyssh/presentation/widgets/acp_status_entry.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';
import 'package:monkeyssh/presentation/widgets/acp_usage.dart';
import 'package:monkeyssh/presentation/widgets/acp_user_prompt.dart';

// A tiny valid 1x1 PNG.
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

Widget wrap(
  Widget child, {
  Brightness brightness = Brightness.dark,
  Size size = const Size(400, 800),
}) => MaterialApp(
  theme: brightness == Brightness.dark ? FluttyTheme.dark : FluttyTheme.light,
  home: MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('preserves user prompt part order', (tester) async {
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpUserPromptEntry(
              id: 'u1',
              parts: [
                const AcpTextPart('first'),
                AcpImagePart(
                  AcpImageContent(bytes: _pngBytes, label: 'diagram'),
                ),
                const AcpTextPart('second'),
                const AcpResourcePart(
                  AcpResourceRef(uri: 'file:///a/main.dart'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // The column of parts must appear top-to-bottom in the given order.
    final firstText = tester.getTopLeft(find.text('first')).dy;
    final image = tester.getTopLeft(find.byType(AcpInlineImage)).dy;
    final secondText = tester.getTopLeft(find.text('second')).dy;
    final chip = tester.getTopLeft(find.byType(AcpResourceChip)).dy;
    expect(firstText, lessThan(image));
    expect(image, lessThan(secondText));
    expect(secondText, lessThan(chip));
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('dispatches each entry type', (tester) async {
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          entries: [
            AcpUserPromptEntry(id: 'u1', parts: [AcpTextPart('hello')]),
            AcpAssistantMessageEntry(id: 'a1', markdown: 'world'),
            AcpPlanEntry(
              id: 'p1',
              plan: AcpPlan(items: [AcpPlanItem(title: 'task')]),
            ),
            AcpToolCallEntry(
              id: 't1',
              toolCall: AcpToolCall(id: 't1', title: 'Read file'),
            ),
            AcpUsageEntry(id: 'us1', usage: AcpUsage(totalTokens: 1200)),
            AcpStatusEntry(id: 's1', message: 'Done'),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AcpUserPromptView), findsOneWidget);
    expect(find.byType(AcpPlanView), findsOneWidget);
    expect(find.byType(AcpToolCallView), findsOneWidget);
    expect(find.byType(AcpUsageView), findsOneWidget);
    expect(find.byType(AcpStatusEntryView), findsOneWidget);
    expect(find.text('Read file'), findsOneWidget);
  });

  testWidgets('renders in light and dark themes', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        wrap(
          brightness: brightness,
          const AcpMessageThread(
            entries: [
              AcpStatusEntry(
                id: 's1',
                message: 'Warning',
                severity: AcpStatusSeverity.warning,
                detail: 'context',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Warning'), findsOneWidget);
    }
  });

  testWidgets('renders in narrow and wide constraints', (tester) async {
    for (final size in [const Size(280, 640), const Size(1100, 800)]) {
      await tester.pumpWidget(
        wrap(
          size: size,
          const AcpMessageThread(
            entries: [
              AcpUserPromptEntry(
                id: 'u1',
                parts: [
                  AcpTextPart(
                    'A fairly long prompt that should wrap on narrow '
                    'screens without overflowing its constraints.',
                  ),
                  AcpResourcePart(
                    AcpResourceRef(
                      uri:
                          'file:///very/long/path/to/some/deeply/nested/file'
                          '/that/keeps/going/component.tsx',
                      sizeBytes: 4096,
                      mimeType: 'text/tsx',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('plan shows progress fraction and items', (tester) async {
    await tester.pumpWidget(
      wrap(
        const AcpPlanView(
          plan: AcpPlan(
            items: [
              AcpPlanItem(title: 'Design', status: AcpPlanItemStatus.completed),
              AcpPlanItem(title: 'Build', status: AcpPlanItemStatus.inProgress),
              AcpPlanItem(title: 'Ship'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('Design'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, closeTo(1 / 3, 0.001));
  });

  testWidgets('usage hides when empty and shows when populated', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const AcpUsageView(usage: AcpUsage())));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpWidget(
      wrap(
        const AcpUsageView(
          usage: AcpUsage(
            inputTokens: 1500,
            outputTokens: 300,
            contextWindow: 1000,
            contextUsedTokens: 400,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('exposes semantics for entries', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          entries: [
            AcpUserPromptEntry(id: 'u1', parts: [AcpTextPart('hi')]),
            AcpStatusEntry(
              id: 's1',
              message: 'Failed',
              severity: AcpStatusSeverity.error,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Your message'), findsOneWidget);
    final statusSemantics = tester.getSemantics(
      find.byType(AcpStatusEntryView),
    );
    expect(statusSemantics.label, contains('Failed'));
    handle.dispose();
  });
}
