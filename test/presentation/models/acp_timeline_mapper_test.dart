// ignore_for_file: public_member_api_docs

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

  test('reports a stop reason when the turn is idle', () {
    final entries = mapAcpSessionTimeline(
      _state(timeline: AcpTimeline(), lastStopReason: AcpStopReason.maxTokens),
    );
    expect(
      entries.whereType<p.AcpStatusEntry>().single.severity,
      p.AcpStatusSeverity.warning,
    );
  });
}
