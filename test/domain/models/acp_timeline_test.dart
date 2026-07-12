// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';

AcpContentChunkUpdate _chunk(String kind, String text, {String? messageId}) =>
    AcpContentChunkUpdate(
      kind: kind,
      content: AcpTextContent(text),
      messageId: messageId,
    );

/// Applies every update in order and returns the final timeline snapshot.
AcpTimeline _run(AcpTimelineBuilder builder, List<AcpSessionUpdate> updates) {
  for (final update in updates) {
    builder.apply(update);
  }
  return builder.snapshot();
}

void main() {
  group('AcpTimelineBuilder content grouping', () {
    test('groups chunks with the same message id into one entry', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'Hello ', messageId: 'm1'),
        _chunk('agent_message_chunk', 'world', messageId: 'm1'),
      ]);
      expect(timeline.entries, hasLength(1));
      final entry = timeline.entries.single as AcpMessageEntry;
      expect(entry.role, AcpMessageRole.agent);
      expect(entry.content, hasLength(2));
      expect((entry.content[0] as AcpTextContent).text, 'Hello ');
      expect((entry.content[1] as AcpTextContent).text, 'world');
    });

    test('separates different roles and message ids', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('user_message_chunk', 'hi', messageId: 'u1'),
        _chunk('agent_message_chunk', 'reply', messageId: 'a1'),
        _chunk('agent_thought_chunk', 'hmm', messageId: 't1'),
      ]);
      expect(timeline.entries, hasLength(3));
      expect(timeline.entries.map((e) => (e as AcpMessageEntry).role), [
        AcpMessageRole.user,
        AcpMessageRole.agent,
        AcpMessageRole.thought,
      ]);
    });

    test('appends unlabeled chunks to the open same-role message', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'a'),
        _chunk('agent_message_chunk', 'b'),
      ]);
      expect(timeline.entries, hasLength(1));
      expect(
        (timeline.entries.single as AcpMessageEntry).content,
        hasLength(2),
      );
    });

    test('resumes an earlier message id after an interruption', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'a', messageId: 'm1'),
        const AcpToolCallUpdate(
          toolCallId: 't1',
          isInitial: true,
          title: 'Read',
        ),
        _chunk('agent_message_chunk', 'b', messageId: 'm1'),
      ]);
      expect(timeline.entries, hasLength(2));
      final message = timeline.entries.whereType<AcpMessageEntry>().single;
      expect(message.content, hasLength(2));
    });
  });

  group('AcpTimelineBuilder tool merging', () {
    test('merges tool_call and tool_call_update by id', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(
          toolCallId: 't1',
          isInitial: true,
          title: 'Read file',
          status: AcpToolStatus.pending,
        ),
        const AcpToolCallUpdate(
          toolCallId: 't1',
          status: AcpToolStatus.completed,
        ),
      ]);
      expect(timeline.entries, hasLength(1));
      final entry = timeline.entries.single as AcpToolCallEntry;
      expect(entry.title, 'Read file');
      expect(entry.status, AcpToolStatus.completed);
    });

    test('keeps distinct tool calls separate and preserves order', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(toolCallId: 't1', isInitial: true),
        const AcpToolCallUpdate(toolCallId: 't2', isInitial: true),
      ]);
      expect(timeline.entries, hasLength(2));
      expect(timeline.entries.map((e) => (e as AcpToolCallEntry).toolCallId), [
        't1',
        't2',
      ]);
    });

    test('ignores empty tool-call ids', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(toolCallId: '', isInitial: true),
      ]);
      expect(timeline.entries, isEmpty);
    });
  });

  group('AcpTimelineBuilder session-scoped updates', () {
    test('does not affect the timeline', () {
      final builder = AcpTimelineBuilder();
      expect(builder.apply(const AcpPlanUpdate()), isNull);
      expect(builder.apply(const AcpUsageUpdate(used: 1, size: 2)), isNull);
      expect(builder.apply(const AcpAvailableCommandsUpdate()), isNull);
    });
  });

  group('AcpTimelineBuilder bounded memory', () {
    test('drops the oldest entries once maxEntries is exceeded', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(maxEntries: 3),
      );
      AcpTimeline? last;
      for (var i = 0; i < 5; i++) {
        last = builder.apply(
          _chunk('agent_message_chunk', 'msg$i', messageId: 'm$i'),
        );
      }
      expect(last!.entries, hasLength(3));
      expect(last.overflowed, isTrue);
      expect(last.droppedEntryCount, 2);
      // The most recent entries are preserved; oldest are gone.
      final texts = last.entries
          .map(
            (e) =>
                ((e as AcpMessageEntry).content.single as AcpTextContent).text,
          )
          .toList();
      expect(texts, ['msg2', 'msg3', 'msg4']);
    });

    test('truncates a single oversized text chunk', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(maxEntryBytes: 16),
      );
      final timeline = _run(builder, [
        _chunk('agent_message_chunk', 'x' * 1000, messageId: 'm1'),
      ]);
      expect(timeline.overflowed, isTrue);
      final entry = timeline.entries.single as AcpMessageEntry;
      final text = (entry.content.single as AcpTextContent).text;
      expect(text.length, lessThan(1000));
      expect(text, contains('truncated'));
    });

    test('drops oldest entries once the total byte budget is exceeded', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntries: 1000,
          maxTotalBytes: 200,
          maxEntryBytes: 1000,
        ),
      );
      AcpTimeline? last;
      for (var i = 0; i < 20; i++) {
        last = builder.apply(
          _chunk('agent_message_chunk', 'x' * 40, messageId: 'm$i'),
        );
      }
      expect(last!.overflowed, isTrue);
      expect(last.entries.length, lessThan(20));
      expect(last.droppedEntryCount, greaterThan(0));
    });

    test('truncates an oversized merged tool-call payload', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(maxEntryBytes: 32),
      );
      final timeline = _run(builder, [
        AcpToolCallUpdate(
          toolCallId: 't1',
          isInitial: true,
          title: 'Read',
          rawOutput: 'y' * 1000,
        ),
      ]);
      expect(timeline.overflowed, isTrue);
      final entry = timeline.entries.single as AcpToolCallEntry;
      expect(entry.title, 'Read');
      expect(entry.rawOutput, isNot('y' * 1000));
    });

    test('never drops below one entry even when it alone exceeds the '
        'total byte budget', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxTotalBytes: 1,
          maxEntryBytes: 1 << 30,
        ),
      );
      final timeline = _run(builder, [
        _chunk('agent_message_chunk', 'single entry', messageId: 'm1'),
      ]);
      expect(timeline.entries, hasLength(1));
    });

    test('keeps unaffected timelines free of overflow state', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'small', messageId: 'm1'),
      ]);
      expect(timeline.overflowed, isFalse);
      expect(timeline.droppedEntryCount, 0);
    });
  });

  group('defensive lists', () {
    test('timeline entries are defensively copied and unmodifiable', () {
      final content = <AcpContentBlock>[const AcpTextContent('a')];
      final entry = AcpMessageEntry(
        role: AcpMessageRole.agent,
        order: 0,
        content: content,
      );
      content.clear();
      expect(entry.content, hasLength(1));
      expect(entry.content.clear, throwsUnsupportedError);
    });

    test(
      'AcpTimeline copies the caller list and exposes an immutable view',
      () {
        final entries = <AcpTimelineEntry>[
          AcpMessageEntry(role: AcpMessageRole.user, order: 0),
        ];
        final timeline = AcpTimeline(entries: entries);
        entries.clear();
        expect(timeline.entries, hasLength(1));
        expect(timeline.entries.clear, throwsUnsupportedError);
      },
    );
  });
}
