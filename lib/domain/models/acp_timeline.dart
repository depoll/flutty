import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_content.dart';
import 'acp_updates.dart';

/// Role of a streamed ACP message in the domain timeline.
enum AcpMessageRole {
  /// A prompt authored by the user.
  user,

  /// A response authored by the agent.
  agent,

  /// The agent's reasoning or "thinking" output.
  thought,
}

/// One entry in the normalized domain timeline for a single ACP session.
///
/// Timeline entries are an in-memory, presentation-independent normalization
/// of streamed ACP updates. They deliberately expose raw content blocks and
/// tool data so a later presentation layer can map them, but they are never
/// persisted or written to diagnostics.
@immutable
sealed class AcpTimelineEntry {
  const AcpTimelineEntry();

  /// Monotonic index describing arrival order within the timeline.
  int get order;
}

/// A user, agent, or thought message assembled from one or more streamed
/// content chunks that share a message identifier.
@immutable
final class AcpMessageEntry extends AcpTimelineEntry {
  /// Creates a message entry.
  ///
  /// [content] is defensively copied into an unmodifiable list so a caller can
  /// never mutate this entry after construction.
  AcpMessageEntry({
    required this.role,
    required this.order,
    this.messageId,
    List<AcpContentBlock> content = const <AcpContentBlock>[],
  }) : content = List<AcpContentBlock>.unmodifiable(content);

  /// Message role.
  final AcpMessageRole role;

  @override
  final int order;

  /// Identifier grouping streamed chunks into a single message, when present.
  final String? messageId;

  /// Ordered content blocks accumulated for this message.
  final List<AcpContentBlock> content;

  /// Returns a copy with [block] appended to [content].
  AcpMessageEntry appendContent(AcpContentBlock block) => AcpMessageEntry(
    role: role,
    order: order,
    messageId: messageId,
    content: [...content, block],
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpMessageEntry &&
          role == other.role &&
          order == other.order &&
          messageId == other.messageId &&
          const ListEquality<AcpContentBlock>().equals(content, other.content);

  @override
  int get hashCode => Object.hash(
    role,
    order,
    messageId,
    const ListEquality<AcpContentBlock>().hash(content),
  );
}

/// A single tool call assembled by merging its initial `tool_call` update with
/// every later `tool_call_update` that shares the same tool-call identifier.
@immutable
final class AcpToolCallEntry extends AcpTimelineEntry {
  /// Creates a tool-call entry.
  AcpToolCallEntry({
    required this.toolCallId,
    required this.order,
    this.title,
    this.toolKind,
    this.status,
    List<AcpToolContent> content = const <AcpToolContent>[],
    List<AcpToolLocation> locations = const <AcpToolLocation>[],
    this.rawInput,
    this.rawOutput,
  }) : content = List<AcpToolContent>.unmodifiable(content),
       locations = List<AcpToolLocation>.unmodifiable(locations);

  /// Tool-call identifier.
  final String toolCallId;

  @override
  final int order;

  /// Latest known title.
  final String? title;

  /// Latest known tool kind.
  final AcpToolKind? toolKind;

  /// Latest known status.
  final AcpToolStatus? status;

  /// Latest known content payloads.
  final List<AcpToolContent> content;

  /// Latest known associated file locations.
  final List<AcpToolLocation> locations;

  /// Latest opaque raw input.
  final Object? rawInput;

  /// Latest opaque raw output.
  final Object? rawOutput;

  /// Returns a copy with the non-null fields of [update] merged in.
  ///
  /// Content, locations, input, and output are treated as complete
  /// replacements per the ACP tool-call-update semantics; unspecified fields
  /// retain their previous value.
  AcpToolCallEntry merge(AcpToolCallUpdate update) => AcpToolCallEntry(
    toolCallId: toolCallId,
    order: order,
    title: update.title ?? title,
    toolKind: update.toolKind ?? toolKind,
    status: update.status ?? status,
    content: update.content == null
        ? content
        : List<AcpToolContent>.unmodifiable(update.content!),
    locations: update.locations == null
        ? locations
        : List<AcpToolLocation>.unmodifiable(update.locations!),
    rawInput: update.rawInput ?? rawInput,
    rawOutput: update.rawOutput ?? rawOutput,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpToolCallEntry &&
          toolCallId == other.toolCallId &&
          order == other.order &&
          title == other.title &&
          toolKind == other.toolKind &&
          status == other.status &&
          rawInput == other.rawInput &&
          rawOutput == other.rawOutput &&
          const ListEquality<AcpToolContent>().equals(content, other.content) &&
          const ListEquality<AcpToolLocation>().equals(
            locations,
            other.locations,
          );

  @override
  int get hashCode => Object.hash(
    toolCallId,
    order,
    title,
    toolKind,
    status,
    rawInput,
    rawOutput,
    const ListEquality<AcpToolContent>().hash(content),
    const ListEquality<AcpToolLocation>().hash(locations),
  );
}

/// Immutable snapshot of a session's normalized in-memory timeline.
@immutable
final class AcpTimeline {
  /// Creates a timeline from [entries], defensively copied into an
  /// unmodifiable list.
  AcpTimeline({List<AcpTimelineEntry> entries = const <AcpTimelineEntry>[]})
    : entries = List<AcpTimelineEntry>.unmodifiable(entries);

  /// Creates the shared empty timeline.
  const AcpTimeline.empty() : entries = const <AcpTimelineEntry>[];

  /// Ordered timeline entries.
  final List<AcpTimelineEntry> entries;

  /// Whether the timeline currently holds no entries.
  bool get isEmpty => entries.isEmpty;

  /// Number of entries.
  int get length => entries.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpTimeline &&
          const ListEquality<AcpTimelineEntry>().equals(entries, other.entries);

  @override
  int get hashCode => const ListEquality<AcpTimelineEntry>().hash(entries);
}

/// Incrementally builds an [AcpTimeline] from streamed ACP session updates.
///
/// The builder groups user/agent/thought content chunks by message identifier
/// and merges tool calls by tool-call identifier while preserving first-seen
/// ordering. It only handles the content-bearing updates; session-scoped
/// updates such as plans, usage, commands, and configuration are tracked on
/// [AcpSessionState] instead. Unknown updates are ignored so forward-compatible
/// protocol data never corrupts the timeline.
class AcpTimelineBuilder {
  final List<AcpTimelineEntry> _entries = <AcpTimelineEntry>[];
  final Map<String, int> _toolCallIndex = <String, int>{};
  int _nextOrder = 0;
  int? _openMessageIndex;

  /// Applies [update], returning an immutable snapshot when the timeline
  /// changed, or `null` when [update] does not affect the timeline.
  AcpTimeline? apply(AcpSessionUpdate update) {
    switch (update) {
      case AcpContentChunkUpdate():
        _applyContentChunk(update);
        return snapshot();
      case AcpToolCallUpdate():
        _applyToolCall(update);
        return snapshot();
      // Session-scoped updates are normalized on the session state, not here.
      case AcpPlanUpdate():
      case AcpAvailableCommandsUpdate():
      case AcpCurrentModeUpdate():
      case AcpCurrentModelUpdate():
      case AcpConfigOptionsUpdate():
      case AcpSessionInfoUpdate():
      case AcpUsageUpdate():
      case AcpUnknownSessionUpdate():
        return null;
    }
  }

  /// Returns an immutable snapshot of the current timeline.
  AcpTimeline snapshot() => AcpTimeline(entries: _entries);

  void _applyContentChunk(AcpContentChunkUpdate update) {
    final role = _roleFor(update.kind);
    if (role == null) return;
    final messageId = update.messageId;

    // Append to the currently open message when the role matches and either
    // both message IDs are absent (a single unlabeled streaming message) or
    // the IDs are identical.
    final openIndex = _openMessageIndex;
    if (openIndex != null && openIndex < _entries.length) {
      final open = _entries[openIndex];
      if (open is AcpMessageEntry &&
          open.role == role &&
          open.messageId == messageId) {
        _entries[openIndex] = open.appendContent(update.content);
        return;
      }
    }

    // Otherwise reuse the most recent same-role entry that shares a non-null
    // message ID, even if other entries have been appended since.
    if (messageId != null) {
      for (var i = _entries.length - 1; i >= 0; i--) {
        final entry = _entries[i];
        if (entry is AcpMessageEntry &&
            entry.role == role &&
            entry.messageId == messageId) {
          _entries[i] = entry.appendContent(update.content);
          _openMessageIndex = i;
          return;
        }
      }
    }

    _entries.add(
      AcpMessageEntry(
        role: role,
        order: _nextOrder++,
        messageId: messageId,
        content: [update.content],
      ),
    );
    _openMessageIndex = _entries.length - 1;
  }

  void _applyToolCall(AcpToolCallUpdate update) {
    if (update.toolCallId.isEmpty) return;
    final existingIndex = _toolCallIndex[update.toolCallId];
    if (existingIndex != null && existingIndex < _entries.length) {
      final existing = _entries[existingIndex];
      if (existing is AcpToolCallEntry) {
        _entries[existingIndex] = existing.merge(update);
        return;
      }
    }
    final order = _nextOrder++;
    final entry = AcpToolCallEntry(
      toolCallId: update.toolCallId,
      order: order,
    ).merge(update);
    _toolCallIndex[update.toolCallId] = _entries.length;
    _entries.add(entry);
    // A tool call interrupts any open streaming message.
    _openMessageIndex = null;
  }

  static AcpMessageRole? _roleFor(String kind) => switch (kind) {
    'user_message_chunk' => AcpMessageRole.user,
    'agent_message_chunk' => AcpMessageRole.agent,
    'agent_thought_chunk' => AcpMessageRole.thought,
    _ => null,
  };
}
