// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart' as p;
import 'package:monkeyssh/presentation/models/acp_timeline_mapper.dart';

AcpSessionKey _key() => AcpSessionKey.of(
  hostId: 1,
  providerId: 'copilot',
  bridgeId: 'bridge',
  acpSessionId: 'session',
);

AcpSessionState _state({
  required AcpTimeline timeline,
  AcpPromptStatus promptStatus = AcpPromptStatus.idle,
  List<AcpPlanEntry> plan = const <AcpPlanEntry>[],
  AcpUsageUpdate? usage,
  AcpSessionError? error,
  AcpSessionError? warning,
  AcpConnectionStatus status = AcpConnectionStatus.ready,
  AcpStopReason? lastStopReason,
}) {
  final now = DateTime(2026);
  return AcpSessionState(
    key: _key(),
    providerLabel: 'Copilot',
    cwd: '/home',
    status: status,
    createdAt: now,
    lastActivityAt: now,
    promptStatus: promptStatus,
    plan: plan,
    usage: usage,
    error: error,
    warning: warning,
    lastStopReason: lastStopReason,
    timeline: timeline,
  );
}

void main() {
  test('maps ordered user content, assistant markdown, and tool calls', () {
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: const [
            AcpTextContent('hello'),
            AcpResourceLinkContent(name: 'a.txt', uri: 'file:///a.txt'),
          ],
        ),
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 1,
          content: const [AcpTextContent('Hi '), AcpTextContent('there')],
        ),
        AcpToolCallEntry(
          toolCallId: 't1',
          order: 2,
          title: 'Edit file',
          toolKind: AcpToolKind.edit,
          status: AcpToolStatus.completed,
          locations: const [AcpToolLocation(path: 'lib/a.dart', line: 3)],
          content: const [
            AcpToolDiff(path: 'lib/a.dart', oldText: 'a', newText: 'b'),
          ],
        ),
      ],
    );

    final entries = mapAcpSessionTimeline(
      _state(
        timeline: timeline,
        promptStatus: AcpPromptStatus.streaming,
        plan: const [
          AcpPlanEntry(
            content: 'do it',
            priority: AcpPlanPriority.high,
            status: AcpPlanStatus.inProgress,
          ),
        ],
        usage: const AcpUsageUpdate(used: 10, size: 100),
      ),
    );

    final user = entries[0] as p.AcpUserPromptEntry;
    expect(user.parts[0], isA<p.AcpTextPart>());
    expect((user.parts[0] as p.AcpTextPart).text, 'hello');
    expect(user.parts[1], isA<p.AcpResourcePart>());
    expect((user.parts[1] as p.AcpResourcePart).resource.uri, 'file:///a.txt');

    final assistant = entries[1] as p.AcpAssistantMessageEntry;
    expect(assistant.markdown, 'Hi there');
    // The last agent message is the streaming tail while the turn streams.
    expect(assistant.status, p.AcpStreamStatus.streaming);

    final tool = entries[2] as p.AcpToolCallEntry;
    expect(tool.toolCall.kind, p.AcpToolKind.edit);
    expect(tool.toolCall.status, p.AcpToolStatus.completed);
    expect(tool.toolCall.locations.single.line, 3);
    expect(tool.toolCall.diffs.single.unifiedDiff, contains('-a'));
    expect(tool.toolCall.diffs.single.unifiedDiff, contains('+b'));

    expect(
      entries.whereType<p.AcpPlanEntry>().single.plan.items.single.status,
      p.AcpPlanItemStatus.inProgress,
    );
    final usage = entries.whereType<p.AcpUsageEntry>().single.usage;
    expect(usage.contextUsedTokens, 10);
    expect(usage.contextWindow, 100);
  });

  test('renders a small unified hunk for a one-line edit', () {
    final oldLines = [
      for (var index = 1; index <= 1000; index++) 'line $index',
    ];
    final newLines = [...oldLines]..[500] = 'line 501 changed';
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 't1',
          order: 0,
          content: [
            AcpToolDiff(
              path: 'lib/large.dart',
              oldText: oldLines.join('\n'),
              newText: newLines.join('\n'),
            ),
          ],
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    final diff = tool.toolCall.diffs.single.unifiedDiff;

    expect(diff, contains('@@ -498,7 +498,7 @@'));
    expect(diff, contains('-line 501'));
    expect(diff, contains('+line 501 changed'));
    expect(diff, contains(' line 498'));
    expect(diff, contains(' line 504'));
    expect(diff, isNot(contains(' line 497')));
    expect(diff, isNot(contains(' line 505')));
    expect(diff.split('\n'), hasLength(11));
  });

  test('separates distant edits into minimal unified hunks', () {
    final oldLines = [for (var index = 1; index <= 30; index++) 'line $index'];
    final newLines = [...oldLines]
      ..[4] = 'line 5 changed'
      ..[24] = 'line 25 changed';
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 't1',
          order: 0,
          content: [
            AcpToolDiff(
              path: 'lib/two_edits.dart',
              oldText: oldLines.join('\n'),
              newText: newLines.join('\n'),
            ),
          ],
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    final diff = tool.toolCall.diffs.single.unifiedDiff;

    expect(RegExp('^@@ ', multiLine: true).allMatches(diff), hasLength(2));
    expect(diff, contains('@@ -2,7 +2,7 @@'));
    expect(diff, contains('@@ -22,7 +22,7 @@'));
    expect(diff, isNot(contains(' line 15')));
  });

  test('assistant message is complete when the turn is idle', () {
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 0,
          content: const [AcpTextContent('done')],
        ),
      ],
    );
    final entries = mapAcpSessionTimeline(_state(timeline: timeline));
    expect(
      (entries.single as p.AcpAssistantMessageEntry).status,
      p.AcpStreamStatus.complete,
    );
  });

  test('falls back to a URI when image bytes are not decodable inline', () {
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: const [
            AcpImageContent(
              data: 'not-base64!!!',
              mimeType: 'image/png',
              uri: 'file:///pic.png',
            ),
          ],
        ),
      ],
    );
    final user =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpUserPromptEntry;
    final image = (user.parts.single as p.AcpImagePart).image;
    expect(image.uri, 'file:///pic.png');
    expect(image.bytes, isNull);
  });

  test('bounds oversized tool input text', () {
    final huge = 'x' * (kAcpMapperMaxToolTextChars + 100);
    final timeline = AcpTimeline(
      entries: [AcpToolCallEntry(toolCallId: 't', order: 0, rawInput: huge)],
    );
    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    expect(tool.toolCall.rawInput!.length, lessThan(huge.length));
    expect(tool.toolCall.rawInput, endsWith('…'));
  });

  test('surfaces a content-free error status entry', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: AcpTimeline(),
        error: const AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message: 'Connection lost',
        ),
      ),
    );
    final status = entries.whereType<p.AcpStatusEntry>().single;
    expect(status.severity, p.AcpStatusSeverity.error);
    expect(status.message, 'Connection lost');
  });

  test('surfaces replay overflow as a non-fatal warning', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: const AcpTimeline.empty(),
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.replayOverflow,
          message: 'Some detached history could not be replayed.',
        ),
      ),
    );

    final status = entries.whereType<p.AcpStatusEntry>().single;
    expect(status.severity, p.AcpStatusSeverity.warning);
    expect(status.message, contains('history'));
  });

  test('replay overflow does not hide later stop reasons', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: const AcpTimeline.empty(),
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.replayOverflow,
          message: 'Some detached history could not be replayed.',
        ),
        lastStopReason: AcpStopReason.maxTokens,
      ),
    );

    final statuses = entries.whereType<p.AcpStatusEntry>().toList();
    expect(statuses, hasLength(2));
    expect(statuses.first.message, contains('history'));
    expect(statuses.last.message, contains('token limit'));
  });

  test('reports a stop reason when the turn is idle', () {
    final entries = mapAcpSessionTimeline(
      _state(timeline: AcpTimeline(), lastStopReason: AcpStopReason.maxTokens),
    );
    expect(
      entries.whereType<p.AcpStatusEntry>().single.severity,
      p.AcpStatusSeverity.warning,
    );
  });

  test('preserves inline image data as bytes when no URI is present', () {
    final data = base64.encode(List<int>.filled(16, 1));
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: [AcpImageContent(data: data, mimeType: 'image/png')],
        ),
      ],
    );
    final user =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpUserPromptEntry;
    final image = (user.parts.single as p.AcpImagePart).image;
    expect(image.bytes, isNotNull);
    expect(image.uri, isNull);
  });

  test('embeds a bounded data URI for a URI-less assistant image', () {
    final data = base64.encode(List<int>.filled(16, 2));
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 0,
          content: [
            const AcpTextContent('see: '),
            AcpImageContent(data: data, mimeType: 'image/png'),
          ],
        ),
      ],
    );
    final assistant =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpAssistantMessageEntry;
    expect(assistant.markdown, startsWith('see: '));
    expect(assistant.markdown, contains('data:image/png;base64,$data'));
  });

  test('drops oversized image data without a URI and never decodes it', () {
    // A base64 string whose *estimated* decoded size exceeds the inline bound;
    // the mapper must skip it via preflight rather than allocating/decoding.
    final oversized = 'A' * (kAcpMapperMaxInlineImageBytes * 4 ~/ 3 + 8);
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: [AcpImageContent(data: oversized, mimeType: 'image/png')],
        ),
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 1,
          content: [AcpImageContent(data: oversized, mimeType: 'image/png')],
        ),
      ],
    );
    final entries = mapAcpSessionTimeline(_state(timeline: timeline));
    // The user prompt held only an undisplayable image, so it maps to no
    // renderable parts and is omitted.
    expect(entries.whereType<p.AcpUserPromptEntry>(), isEmpty);
    final assistant = entries.whereType<p.AcpAssistantMessageEntry>().single;
    expect(assistant.markdown, isEmpty);
  });

  test('falls back to the URI for an oversized image that has one', () {
    final oversized = 'A' * (kAcpMapperMaxInlineImageBytes * 4 ~/ 3 + 8);
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: [
            AcpImageContent(
              data: oversized,
              mimeType: 'image/png',
              uri: 'file:///big.png',
            ),
          ],
        ),
      ],
    );
    final user =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpUserPromptEntry;
    final image = (user.parts.single as p.AcpImagePart).image;
    expect(image.uri, 'file:///big.png');
    expect(image.bytes, isNull);
  });
}
