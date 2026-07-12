import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_content.dart';
import 'acp_updates.dart';

/// Bounds applied to a single session's in-memory [AcpTimeline].
///
/// These limits exist purely to cap memory: a long-running or replayed
/// session must never grow its in-memory timeline without bound. When a limit
/// is reached, the oldest entries are dropped and/or the largest payloads are
/// truncated; [AcpTimeline.overflowed] is set so the UI can show a safe,
/// content-free "earlier history was trimmed" state.
@immutable
final class AcpTimelineLimits {
  /// Creates timeline limits.
  const AcpTimelineLimits({
    this.maxEntries = 500,
    this.maxEntryBytes = 512 * 1024,
    this.maxTotalBytes = 6 * 1024 * 1024,
  });

  /// Maximum retained timeline entries. Oldest entries are dropped first.
  final int maxEntries;

  /// Maximum approximate bytes retained for a single entry's content.
  ///
  /// Applies independently of [maxTotalBytes] so one oversized message or
  /// tool payload cannot be retained in full even when the timeline overall
  /// is otherwise small.
  final int maxEntryBytes;

  /// Maximum approximate total bytes retained across the whole timeline.
  final int maxTotalBytes;
}

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
  AcpTimeline({
    List<AcpTimelineEntry> entries = const <AcpTimelineEntry>[],
    this.overflowed = false,
    this.droppedEntryCount = 0,
  }) : entries = List<AcpTimelineEntry>.unmodifiable(entries);

  /// Creates the shared empty timeline.
  const AcpTimeline.empty()
    : entries = const <AcpTimelineEntry>[],
      overflowed = false,
      droppedEntryCount = 0;

  /// Ordered timeline entries.
  final List<AcpTimelineEntry> entries;

  /// Whether bounded-memory limits ever dropped or truncated content for this
  /// session. Once set, this stays `true` for the life of the session: the
  /// dropped history can never be safely reconstructed.
  final bool overflowed;

  /// Cumulative number of oldest entries dropped to stay within limits.
  final int droppedEntryCount;

  /// Whether the timeline currently holds no entries.
  bool get isEmpty => entries.isEmpty;

  /// Number of entries.
  int get length => entries.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpTimeline &&
          overflowed == other.overflowed &&
          droppedEntryCount == other.droppedEntryCount &&
          const ListEquality<AcpTimelineEntry>().equals(entries, other.entries);

  @override
  int get hashCode => Object.hash(
    overflowed,
    droppedEntryCount,
    const ListEquality<AcpTimelineEntry>().hash(entries),
  );
}

/// A content block was too large to retain in full; a small marker replaces
/// the truncated portion so the timeline stays within its byte budget.
const _truncationMarkerText = '\n… (truncated to stay within memory limits)';

/// Approximates the retained byte footprint of [block] using its JSON
/// encoding. This is only used to bound memory, not for wire transfer.
int approximateContentBlockBytes(AcpContentBlock block) {
  try {
    return utf8.encode(jsonEncode(block.toJson())).length;
  } on Object {
    return 256;
  }
}

int _approximateToolContentBytes(AcpToolContent content) => switch (content) {
  AcpToolContentBlock(:final content) => approximateContentBlockBytes(content),
  AcpToolDiff(:final path, :final oldText, :final newText) =>
    path.length + (oldText?.length ?? 0) + newText.length,
  AcpToolTerminal(:final terminalId) => terminalId.length + 16,
  AcpUnknownToolContent(:final raw) => _approximateJsonBytes(raw),
};

int _approximateJsonBytes(Object? value) {
  try {
    return utf8.encode(jsonEncode(value)).length;
  } on Object {
    return 256;
  }
}

int _approximateMessageBytes(AcpMessageEntry entry) => entry.content.fold<int>(
  0,
  (total, block) => total + approximateContentBlockBytes(block),
);

int _approximateToolCallBytes(AcpToolCallEntry entry) =>
    (entry.title?.length ?? 0) +
    entry.content.fold<int>(
      0,
      (total, content) => total + _approximateToolContentBytes(content),
    ) +
    entry.locations.length * 32 +
    _approximateJsonBytes(entry.rawInput) +
    _approximateJsonBytes(entry.rawOutput);

/// Approximates the retained byte footprint of one timeline entry.
int approximateTimelineEntryBytes(AcpTimelineEntry entry) => switch (entry) {
  AcpMessageEntry() => _approximateMessageBytes(entry),
  AcpToolCallEntry() => _approximateToolCallBytes(entry),
};

/// Truncates the text of [block] to at most [maxBytes] UTF-8 bytes, appending
/// a safe marker. Non-text blocks are replaced by a small placeholder because
/// their binary payload cannot be partially truncated safely.
AcpContentBlock _truncatedContentBlock(AcpContentBlock block, int maxBytes) {
  if (block is AcpTextContent) {
    final bytes = utf8.encode(block.text);
    if (bytes.length <= maxBytes) return block;
    final keep = maxBytes < 0 ? 0 : maxBytes;
    final truncatedText =
        utf8.decode(bytes.sublist(0, keep), allowMalformed: true) +
        _truncationMarkerText;
    return AcpTextContent(truncatedText, annotations: block.annotations);
  }
  return const AcpTextContent('[content omitted to stay within memory limits]');
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
  /// Creates a timeline builder bounded by [limits].
  AcpTimelineBuilder({AcpTimelineLimits limits = const AcpTimelineLimits()})
    : _limits = limits;

  final AcpTimelineLimits _limits;
  final List<AcpTimelineEntry> _entries = <AcpTimelineEntry>[];
  final Map<String, int> _toolCallIndex = <String, int>{};
  int _nextOrder = 0;
  int? _openMessageIndex;
  int _totalBytes = 0;
  bool _overflowed = false;
  int _droppedEntryCount = 0;

  /// Applies [update], returning an immutable snapshot when the timeline
  /// changed, or `null` when [update] does not affect the timeline.
  AcpTimeline? apply(AcpSessionUpdate update) {
    switch (update) {
      case AcpContentChunkUpdate():
        _applyContentChunk(update);
        _enforceLimits();
        return snapshot();
      case AcpToolCallUpdate():
        _applyToolCall(update);
        _enforceLimits();
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
  AcpTimeline snapshot() => AcpTimeline(
    entries: _entries,
    overflowed: _overflowed,
    droppedEntryCount: _droppedEntryCount,
  );

  void _applyContentChunk(AcpContentChunkUpdate update) {
    final role = _roleFor(update.kind);
    if (role == null) return;
    final messageId = update.messageId;
    final block = update.content;

    // Append to the currently open message when the role matches and either
    // both message IDs are absent (a single unlabeled streaming message) or
    // the IDs are identical.
    final openIndex = _openMessageIndex;
    if (openIndex != null && openIndex < _entries.length) {
      final open = _entries[openIndex];
      if (open is AcpMessageEntry &&
          open.role == role &&
          open.messageId == messageId) {
        _replaceEntry(openIndex, open.appendContent(block));
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
          _replaceEntry(i, entry.appendContent(block));
          _openMessageIndex = i;
          return;
        }
      }
    }

    final entry = _boundedMessageEntry(
      AcpMessageEntry(
        role: role,
        order: _nextOrder++,
        messageId: messageId,
        content: [block],
      ),
    );
    _totalBytes += approximateTimelineEntryBytes(entry);
    _entries.add(entry);
    _openMessageIndex = _entries.length - 1;
  }

  void _applyToolCall(AcpToolCallUpdate update) {
    if (update.toolCallId.isEmpty) return;
    final existingIndex = _toolCallIndex[update.toolCallId];
    if (existingIndex != null && existingIndex < _entries.length) {
      final existing = _entries[existingIndex];
      if (existing is AcpToolCallEntry) {
        _replaceEntry(existingIndex, existing.merge(update));
        return;
      }
    }
    final order = _nextOrder++;
    final entry = _boundedToolCall(
      AcpToolCallEntry(
        toolCallId: update.toolCallId,
        order: order,
      ).merge(update),
    );
    _toolCallIndex[update.toolCallId] = _entries.length;
    _totalBytes += approximateTimelineEntryBytes(entry);
    _entries.add(entry);
    // A tool call interrupts any open streaming message.
    _openMessageIndex = null;
  }

  void _replaceEntry(int index, AcpTimelineEntry updated) {
    _totalBytes -= approximateTimelineEntryBytes(_entries[index]);
    final bounded = switch (updated) {
      AcpToolCallEntry() => _boundedToolCall(updated),
      AcpMessageEntry() => _boundedMessageEntry(updated),
    };
    _totalBytes += approximateTimelineEntryBytes(bounded);
    _entries[index] = bounded;
  }

  /// Bounds a single message entry's own accumulated size to
  /// [AcpTimelineLimits.maxEntryBytes], regardless of how many streamed
  /// chunks (potentially thousands, all sharing one message id) were merged
  /// into it.
  ///
  /// A per-chunk check alone is not enough: many small chunks that each stay
  /// under the cap can still accumulate without bound onto the same open
  /// message. This drops the oldest content blocks within the message first
  /// (preserving the most recent, most useful context, mirroring how the
  /// whole timeline drops its oldest entries), then truncates a single
  /// remaining oversized block as a last resort.
  AcpMessageEntry _boundedMessageEntry(AcpMessageEntry entry) {
    if (_approximateMessageBytes(entry) <= _limits.maxEntryBytes) {
      return entry;
    }
    _overflowed = true;
    final content = List<AcpContentBlock>.of(entry.content);
    var total = content.fold<int>(
      0,
      (sum, block) => sum + approximateContentBlockBytes(block),
    );
    while (content.length > 1 && total > _limits.maxEntryBytes) {
      total -= approximateContentBlockBytes(content.removeAt(0));
    }
    if (content.length == 1 &&
        approximateContentBlockBytes(content.single) > _limits.maxEntryBytes) {
      content[0] = _truncatedContentBlock(
        content.single,
        _limits.maxEntryBytes,
      );
    }
    return AcpMessageEntry(
      role: entry.role,
      order: entry.order,
      messageId: entry.messageId,
      content: content,
    );
  }

  /// Truncates a merged tool-call entry so its retained payload stays under
  /// [AcpTimelineLimits.maxEntryBytes].
  AcpToolCallEntry _boundedToolCall(AcpToolCallEntry entry) {
    if (_approximateToolCallBytes(entry) <= _limits.maxEntryBytes) {
      return entry;
    }
    _overflowed = true;
    return AcpToolCallEntry(
      toolCallId: entry.toolCallId,
      order: entry.order,
      title: entry.title,
      toolKind: entry.toolKind,
      status: entry.status,
      locations: entry.locations,
      rawInput: entry.rawInput == null
          ? null
          : const <String, Object?>{'_truncated': true},
      rawOutput: entry.rawOutput == null
          ? null
          : const <String, Object?>{'_truncated': true},
    );
  }

  /// Drops the oldest entries so the timeline stays within its entry-count
  /// and total-byte budgets, preserving the most recent context.
  void _enforceLimits() {
    var droppedThisCall = false;
    while (_entries.length > _limits.maxEntries ||
        (_totalBytes > _limits.maxTotalBytes && _entries.length > 1)) {
      final dropped = _entries.removeAt(0);
      _totalBytes -= approximateTimelineEntryBytes(dropped);
      _droppedEntryCount++;
      _overflowed = true;
      droppedThisCall = true;
    }
    if (droppedThisCall) {
      _rebuildIndexes();
    }
  }

  void _rebuildIndexes() {
    _toolCallIndex.clear();
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry is AcpToolCallEntry) {
        _toolCallIndex[entry.toolCallId] = i;
      }
    }
    _openMessageIndex = _entries.isEmpty || _entries.last is! AcpMessageEntry
        ? null
        : _entries.length - 1;
  }

  static AcpMessageRole? _roleFor(String kind) => switch (kind) {
    'user_message_chunk' => AcpMessageRole.user,
    'agent_message_chunk' => AcpMessageRole.agent,
    'agent_thought_chunk' => AcpMessageRole.thought,
    _ => null,
  };
}
