/// Maps the domain-layer ACP session state onto the presentation-layer
/// timeline view models consumed by [AcpMessageThread].
///
/// The mapper is a pure, bounded function of a single [d.AcpSessionState]
/// snapshot. It never performs I/O, never mutates its input, and never
/// persists or logs transcript content: every byte it produces already lives
/// in the in-memory domain timeline. Ordering of user content, streamed
/// Markdown chunks, thoughts, tool calls (with their locations and diffs),
/// plans, usage, and status is preserved exactly as the domain timeline
/// reports it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/acp_content.dart' as d;
import '../../domain/models/acp_protocol.dart' as d;
import '../../domain/models/acp_session_state.dart' as d;
import '../../domain/models/acp_timeline.dart' as d;
import '../../domain/models/acp_updates.dart' as d;
import 'acp_timeline.dart';

/// Maximum decoded image bytes embedded inline while mapping a domain image.
///
/// Larger images fall back to their URI (when present) so a single prompt can
/// never force an unbounded decode into memory.
const int kAcpMapperMaxInlineImageBytes = 5 * 1024 * 1024;

/// Maximum characters of formatted tool input/output surfaced by the mapper.
const int kAcpMapperMaxToolTextChars = 16 * 1024;

/// Maximum characters of diff source text retained per side before the diff
/// widget's own bounding takes over.
const int kAcpMapperMaxDiffSourceChars = 128 * 1024;

final Expando<List<AcpTimelineEntry>> _sharedTimelineMappings =
    Expando<List<AcpTimelineEntry>>('ACP presentation timeline');
final Expando<_CachedTimelinePreview> _sharedTimelinePreviews =
    Expando<_CachedTimelinePreview>('ACP connection preview');

final class _CachedTimelinePreview {
  const _CachedTimelinePreview(this.value);

  final String? value;
}

/// Memoizes one immutable session-to-presentation mapping.
///
/// Theme changes, navigation, and parent mux rebuilds commonly rebuild the
/// chat with the identical session object. Reusing this result avoids walking
/// the full transcript and decoding old image payloads again.
class AcpTimelineMapperCache {
  /// Creates a timeline mapper cache.
  AcpTimelineMapperCache();
  d.AcpSessionState? _session;
  List<AcpTimelineEntry>? _entries;

  /// Returns the cached mapping when [state] is the same immutable snapshot.
  List<AcpTimelineEntry> map(d.AcpSessionState state) {
    if (identical(state, _session)) {
      return _entries!;
    }
    final shared = _sharedTimelineMappings[state];
    if (shared != null) {
      _session = state;
      _entries = shared;
      return shared;
    }
    final entries = mapAcpSessionTimeline(state);
    _sharedTimelineMappings[state] = entries;
    _session = state;
    _entries = entries;
    return entries;
  }

  /// Returns a cached bounded connection preview for [state].
  String? preview(d.AcpSessionState state) {
    final cached = _sharedTimelinePreviews[state];
    if (cached != null) {
      return cached.value;
    }
    final value = buildAcpConversationPreview(map(state));
    _sharedTimelinePreviews[state] = _CachedTimelinePreview(value);
    return value;
  }

  /// Drops the retained local snapshot and mapped entries.
  void clear() {
    _session = null;
    _entries = null;
  }
}

/// Builds a bounded plain-text preview for Hosts/Connections cards.
String? buildAcpConversationPreview(
  List<AcpTimelineEntry> entries, {
  int maxLines = 8,
  int maxChars = 900,
}) {
  final lines = <String>[];

  String clean(String value) => value
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '[image]')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  void collect(Iterable<AcpTimelineEntry> source, {String prefix = ''}) {
    for (final entry in source) {
      final line = switch (entry) {
        AcpUserPromptEntry() =>
          'You: ${clean(entry.parts.whereType<AcpTextPart>().map((part) => part.text).join(' '))}',
        AcpAssistantMessageEntry() => 'Agent: ${clean(entry.markdown)}',
        AcpToolCallEntry() =>
          '${entry.isSubagent ? 'Subagent' : 'Tool'}: '
              '${entry.toolCall.title} · ${entry.toolCall.status.name}',
        AcpPlanEntry() =>
          'Plan: ${entry.plan.completedCount}/${entry.plan.totalCount}',
        AcpUsageEntry() || AcpThoughtEntry() => '',
        AcpStatusEntry() => clean(entry.message),
        AcpSubagentTranscriptEntry() => '',
      };
      if (line.isNotEmpty) {
        lines.add('$prefix${_bound(line, 240)}');
      }
      if (entry is AcpSubagentTranscriptEntry) {
        collect(entry.entries, prefix: 'Subagent · ');
      }
    }
  }

  collect(entries);
  if (lines.isEmpty) {
    return null;
  }
  final selected = lines.length <= maxLines
      ? lines
      : lines.sublist(lines.length - maxLines);
  return _bound(selected.join('\n'), maxChars);
}

/// Maps [state] into an ordered list of presentation timeline entries.
///
/// The returned list is ordered as: the conversation timeline (user prompts,
/// assistant Markdown, thoughts, and tool calls in first-seen order), followed
/// by the latest plan, the latest usage, and finally any terminal status or
/// error surfaced for the turn.
List<AcpTimelineEntry> mapAcpSessionTimeline(d.AcpSessionState state) {
  final entries = <AcpTimelineEntry>[];
  final domainEntries = state.timeline.entries;
  final streamingTailOrder = _streamingTailOrder(state, domainEntries);

  for (final entry in domainEntries) {
    switch (entry) {
      case d.AcpMessageEntry():
        final mapped = _mapMessage(
          entry,
          streaming: entry.order == streamingTailOrder,
        );
        if (mapped != null) {
          entries.add(mapped);
        }
      case d.AcpToolCallEntry():
        entries.add(_mapToolCall(entry));
    }
  }

  final nestedConversation = _nestSubagentEntries(entries);
  entries
    ..clear()
    ..addAll(nestedConversation);

  final plan = _mapPlan(state.plan);
  if (plan != null) {
    entries.add(AcpPlanEntry(id: 'plan', plan: plan));
  }

  final usage = _mapUsage(state.usage);
  if (usage != null) {
    entries.add(AcpUsageEntry(id: 'usage', usage: usage));
  }

  entries.addAll(_mapStatuses(state));

  return List<AcpTimelineEntry>.unmodifiable(entries);
}

List<AcpTimelineEntry> _nestSubagentEntries(List<AcpTimelineEntry> source) {
  final childrenByParent = <String, List<AcpTimelineEntry>>{};
  final topLevel = <AcpTimelineEntry>[];
  for (final entry in source) {
    final parent = entry.parentToolCallId;
    if (parent == null || parent.isEmpty) {
      topLevel.add(entry);
    } else {
      childrenByParent.putIfAbsent(parent, () => []).add(entry);
    }
  }

  List<AcpTimelineEntry> takeChildren(String parent, int depth) {
    if (depth > 8) {
      return const [];
    }
    final children = childrenByParent.remove(parent);
    if (children == null || children.isEmpty) {
      return const [];
    }
    final nested = <AcpTimelineEntry>[];
    for (final child in children) {
      nested.add(child);
      if (child case AcpToolCallEntry(:final toolCall)) {
        final descendants = takeChildren(toolCall.id, depth + 1);
        if (descendants.isNotEmpty) {
          nested.add(
            AcpSubagentTranscriptEntry(
              id: 'subagent-${toolCall.id}',
              launchToolCallId: toolCall.id,
              entries: descendants,
            ),
          );
        }
      }
    }
    return nested;
  }

  final result = <AcpTimelineEntry>[];
  for (final entry in topLevel) {
    result.add(entry);
    if (entry case AcpToolCallEntry(:final toolCall)) {
      final children = takeChildren(toolCall.id, 0);
      if (children.isNotEmpty) {
        result.add(
          AcpSubagentTranscriptEntry(
            id: 'subagent-${toolCall.id}',
            launchToolCallId: toolCall.id,
            entries: children,
          ),
        );
      }
    }
  }
  for (final parent in childrenByParent.keys.toList(growable: false)) {
    final orphaned = takeChildren(parent, 0);
    if (orphaned.isNotEmpty) {
      result.add(
        AcpSubagentTranscriptEntry(
          id: 'subagent-orphan-$parent',
          launchToolCallId: parent,
          entries: orphaned,
        ),
      );
    }
  }
  return result;
}

/// Returns the [d.AcpTimelineEntry.order] of the message that should render as

/// still-streaming, or `null` when nothing is streaming.
int? _streamingTailOrder(
  d.AcpSessionState state,
  List<d.AcpTimelineEntry> entries,
) {
  final active =
      state.promptStatus == d.AcpPromptStatus.streaming ||
      state.promptStatus == d.AcpPromptStatus.sending;
  if (!active) {
    return null;
  }
  for (var i = entries.length - 1; i >= 0; i--) {
    final entry = entries[i];
    if (entry is d.AcpMessageEntry &&
        (entry.role == d.AcpMessageRole.agent ||
            entry.role == d.AcpMessageRole.thought)) {
      return entry.order;
    }
  }
  return null;
}

AcpTimelineEntry? _mapMessage(
  d.AcpMessageEntry entry, {
  required bool streaming,
}) {
  final status = streaming
      ? AcpStreamStatus.streaming
      : AcpStreamStatus.complete;
  switch (entry.role) {
    case d.AcpMessageRole.user:
      final parts = _mapPromptParts(entry.content);
      if (parts.isEmpty) {
        return null;
      }
      return AcpUserPromptEntry(
        id: 'msg-${entry.order}',
        parts: parts,
        queued: entry.queued,
      );
    case d.AcpMessageRole.agent:
      return AcpAssistantMessageEntry(
        id: 'msg-${entry.order}',
        markdown: _markdownFromContent(entry.content),
        parentToolCallId: entry.parentToolCallId,
        status: status,
      );
    case d.AcpMessageRole.thought:
      return AcpThoughtEntry(
        id: 'msg-${entry.order}',
        markdown: _markdownFromContent(entry.content),
        parentToolCallId: entry.parentToolCallId,
        status: status,
      );
  }
}

List<AcpPromptPart> _mapPromptParts(List<d.AcpContentBlock> content) {
  final parts = <AcpPromptPart>[];
  for (final block in content) {
    switch (block) {
      case d.AcpTextContent(:final text):
        if (text.isNotEmpty) {
          parts.add(AcpTextPart(text));
        }
      case d.AcpImageContent():
        final image = _mapImage(block);
        if (image != null) {
          parts.add(AcpImagePart(image));
        }
      case d.AcpResourceContent(:final resource):
        parts.add(
          AcpResourcePart(
            AcpResourceRef(uri: resource.uri, mimeType: resource.mimeType),
          ),
        );
      case d.AcpResourceLinkContent():
        parts.add(
          AcpResourcePart(
            AcpResourceRef(
              uri: block.uri,
              name: block.title ?? block.name,
              mimeType: block.mimeType,
              sizeBytes: block.size,
            ),
          ),
        );
      case d.AcpAudioContent():
        parts.add(
          AcpResourcePart(
            AcpResourceRef(
              uri: 'audio',
              name: 'Audio clip',
              mimeType: block.mimeType,
            ),
          ),
        );
      case d.AcpUnknownContent():
        break;
    }
  }
  return parts;
}

AcpImageContent? _mapImage(d.AcpImageContent block) {
  final uri = block.uri;
  final data = block.data;
  // Preflight the decoded size from the base64 length before ever decoding, so
  // an oversized payload can never force an unbounded allocation into memory.
  if (data.isNotEmpty &&
      _base64DecodedLength(data) <= kAcpMapperMaxInlineImageBytes) {
    try {
      final bytes = base64.decode(data);
      if (bytes.length <= kAcpMapperMaxInlineImageBytes) {
        return AcpImageContent(
          bytes: Uint8List.fromList(bytes),
          uri: uri,
          mimeType: block.mimeType.isEmpty ? null : block.mimeType,
        );
      }
    } on FormatException {
      // Fall through to a URI-backed image when the payload is not base64.
    }
  }
  if (uri != null && uri.isNotEmpty) {
    return AcpImageContent(
      uri: uri,
      mimeType: block.mimeType.isEmpty ? null : block.mimeType,
    );
  }
  return null;
}

/// Estimates the number of bytes a base64 [data] string decodes to, without
/// decoding it. Used to bound image decoding before any allocation.
int _base64DecodedLength(String data) {
  final length = data.length;
  if (length < 4) {
    return length == 0 ? 0 : (length * 3) ~/ 4;
  }
  var padding = 0;
  if (data.endsWith('==')) {
    padding = 2;
  } else if (data.endsWith('=')) {
    padding = 1;
  }
  return (length ~/ 4) * 3 - padding;
}

/// Builds Markdown for a domain image, preferring a remote URI and otherwise
/// embedding a bounded `data:` URI so inline image data is not lost when no URI
/// is present. Returns `null` when neither a URI nor bounded data is available.
String? _imageMarkdown(d.AcpImageContent block) {
  final uri = block.uri;
  if (uri != null && uri.isNotEmpty) {
    return '\n\n![image]($uri)';
  }
  final data = block.data;
  if (data.isNotEmpty &&
      _base64DecodedLength(data) <= kAcpMapperMaxInlineImageBytes) {
    final mime = block.mimeType.isEmpty
        ? 'application/octet-stream'
        : block.mimeType;
    return '\n\n![image](data:$mime;base64,$data)';
  }
  return null;
}

String _markdownFromContent(List<d.AcpContentBlock> content) {
  final buffer = StringBuffer();
  for (final block in content) {
    switch (block) {
      case d.AcpTextContent(:final text):
        buffer.write(text);
      case d.AcpImageContent():
        final markdown = _imageMarkdown(block);
        if (markdown != null) {
          buffer.write(markdown);
        }
      case d.AcpResourceLinkContent():
        buffer.write('\n\n[${block.title ?? block.name}](${block.uri})');
      case d.AcpResourceContent():
      case d.AcpAudioContent():
      case d.AcpUnknownContent():
        break;
    }
  }
  return buffer.toString();
}

AcpToolCallEntry _mapToolCall(d.AcpToolCallEntry entry) {
  final diffs = <AcpDiff>[];
  final images = _imagesFromRawToolOutput(entry.rawOutput);
  final outputBlocks = <String>[];
  for (final content in entry.content) {
    switch (content) {
      case d.AcpToolDiff():
        diffs.add(
          AcpDiff(
            path: content.path,
            unifiedDiff: _buildUnifiedDiff(
              path: content.path,
              oldText: content.oldText,
              newText: content.newText,
            ),
            oldText: content.oldText,
            newText: content.newText,
          ),
        );
      case d.AcpToolContentBlock():
        final inner = content.content;
        if (inner is d.AcpTextContent && inner.text.isNotEmpty) {
          outputBlocks.add(inner.text);
        } else if (inner is d.AcpImageContent) {
          final image = _mapImage(inner);
          if (image != null && !images.contains(image)) {
            images.add(image);
          }
        }
      case d.AcpToolTerminal():
      case d.AcpUnknownToolContent():
        break;
    }
  }

  final rawInput = _formatToolPayload(entry.rawInput);
  final visibleOutputBlocks = outputBlocks
      .where(
        (text) => images.isEmpty || !_looksLikeSerializedImagePayload(text),
      )
      .toList(growable: true);
  if (images.isNotEmpty) {
    for (final text in _textFromRawToolOutput(entry.rawOutput)) {
      if (!visibleOutputBlocks.contains(text)) {
        visibleOutputBlocks.add(text);
      }
    }
  }
  var rawOutput = images.isEmpty ? _formatToolPayload(entry.rawOutput) : null;
  if (rawOutput == null && visibleOutputBlocks.isNotEmpty) {
    rawOutput = _bound(
      visibleOutputBlocks.join('\n\n'),
      kAcpMapperMaxToolTextChars,
    );
  }

  return AcpToolCallEntry(
    id: 'tool-${entry.toolCallId}',
    parentToolCallId: entry.parentToolCallId,
    isSubagent: entry.isSubagent,
    toolCall: AcpToolCall(
      id: entry.toolCallId,
      title: (entry.title?.isNotEmpty ?? false)
          ? entry.title!
          : entry.toolCallId,
      kind: _mapToolKind(entry.toolKind),
      status: _mapToolStatus(entry.status),
      rawInput: rawInput,
      rawOutput: rawOutput,
      locations: [
        for (final location in entry.locations)
          AcpToolLocation(path: location.path, line: location.line),
      ],
      diffs: diffs,
      images: images,
    ),
  );
}

List<AcpImageContent> _imagesFromRawToolOutput(Object? rawOutput) {
  const maxImages = 8;
  const maxNodes = 256;
  final images = <AcpImageContent>[];
  var visitedNodes = 0;

  void visit(Object? value, int depth) {
    if (value == null ||
        depth > 6 ||
        images.length >= maxImages ||
        visitedNodes++ >= maxNodes) {
      return;
    }
    if (value is Map) {
      final map = <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      if (map['type']?.toString().toLowerCase() == 'image') {
        var data = map['data'] is String ? map['data']! as String : '';
        var mimeType = map['mimeType'] is String
            ? map['mimeType']! as String
            : (map['mime_type'] is String ? map['mime_type']! as String : '');
        final uri = map['uri'] is String ? map['uri']! as String : null;
        if (data.startsWith('data:')) {
          final separator = data.indexOf(',');
          final header = separator < 0 ? '' : data.substring(5, separator);
          if (separator >= 0 && header.toLowerCase().endsWith(';base64')) {
            if (mimeType.isEmpty) {
              mimeType = header.substring(0, header.length - ';base64'.length);
            }
            data = data.substring(separator + 1);
          }
        }
        final image = _mapImage(
          d.AcpImageContent(data: data, mimeType: mimeType, uri: uri),
        );
        if (image != null && !images.contains(image)) {
          images.add(image);
        }
        return;
      }
      for (final child in map.values) {
        visit(child, depth + 1);
      }
      return;
    }
    if (value is Iterable) {
      for (final child in value) {
        visit(child, depth + 1);
      }
    }
  }

  visit(rawOutput, 0);
  return images;
}

List<String> _textFromRawToolOutput(Object? rawOutput) {
  const maxNodes = 256;
  final output = <String>[];
  var visitedNodes = 0;

  void visit(Object? value, int depth) {
    if (value == null || depth > 6 || visitedNodes++ >= maxNodes) {
      return;
    }
    if (value is Map) {
      final map = <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      if (map['type']?.toString().toLowerCase() == 'image') {
        return;
      }
      for (final entry in map.entries) {
        final key = entry.key.toLowerCase();
        final child = entry.value;
        if (child is String &&
            const {
              'text',
              'message',
              'output',
              'stdout',
              'stderr',
            }.contains(key) &&
            child.trim().isNotEmpty) {
          final bounded = _bound(child, kAcpMapperMaxToolTextChars);
          if (!output.contains(bounded)) {
            output.add(bounded);
          }
        } else {
          visit(child, depth + 1);
        }
      }
      return;
    }
    if (value is Iterable) {
      for (final child in value) {
        visit(child, depth + 1);
      }
    }
  }

  visit(rawOutput, 0);
  return output;
}

bool _looksLikeSerializedImagePayload(String text) {
  final trimmed = text.trimLeft();
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) {
    return false;
  }
  return text.contains('"type"') &&
      text.contains('"image"') &&
      text.contains('"data"');
}

AcpToolKind _mapToolKind(d.AcpToolKind? kind) => switch (kind?.value) {
  'read' => AcpToolKind.read,
  'edit' => AcpToolKind.edit,
  'delete' => AcpToolKind.delete,
  'move' => AcpToolKind.move,
  'search' => AcpToolKind.search,
  'execute' => AcpToolKind.execute,
  'fetch' => AcpToolKind.fetch,
  'think' => AcpToolKind.think,
  _ => AcpToolKind.other,
};

AcpToolStatus _mapToolStatus(d.AcpToolStatus? status) =>
    switch (status?.value) {
      'pending' => AcpToolStatus.pending,
      'in_progress' => AcpToolStatus.running,
      'completed' => AcpToolStatus.completed,
      'failed' => AcpToolStatus.failed,
      'cancelled' => AcpToolStatus.cancelled,
      _ => AcpToolStatus.pending,
    };

String? _formatToolPayload(Object? payload) {
  if (payload == null) {
    return null;
  }
  if (payload is String) {
    return payload.isEmpty ? null : _bound(payload, kAcpMapperMaxToolTextChars);
  }
  final encoded = const JsonEncoder.withIndent(
    '  ',
  ).convert(_jsonSafe(payload));
  return _bound(encoded, kAcpMapperMaxToolTextChars);
}

/// Recursively coerces [value] into JSON-encodable data, stringifying any
/// value the encoder cannot represent so formatting never throws.
Object? _jsonSafe(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _jsonSafe(entry.value),
    };
  }
  if (value is Iterable) {
    return [for (final element in value) _jsonSafe(element)];
  }
  return value.toString();
}

String _buildUnifiedDiff({
  required String path,
  required String newText,
  String? oldText,
}) {
  final oldSource = _bound(oldText ?? '', kAcpMapperMaxDiffSourceChars);
  final newSource = _bound(newText, kAcpMapperMaxDiffSourceChars);
  final oldLines = oldSource.isEmpty ? const <String>[] : oldSource.split('\n');
  final newLines = newSource.isEmpty ? const <String>[] : newSource.split('\n');
  final lines = _buildDiffLines(oldLines, newLines);
  final buffer = StringBuffer()
    ..writeln('--- a/$path')
    ..writeln('+++ b/$path');
  for (final hunk in _buildDiffHunks(lines)) {
    buffer.writeln(
      '@@ -${hunk.oldStart},${hunk.oldCount} '
      '+${hunk.newStart},${hunk.newCount} @@',
    );
    for (final line in hunk.lines) {
      buffer
        ..write(line.kind.prefix)
        ..writeln(line.text);
    }
  }
  return buffer.toString().trimRight();
}

const int _diffContextLines = 3;
const int _maxMyersEditDistance = 256;

enum _DiffLineKind {
  context(' '),
  deletion('-'),
  addition('+');

  const _DiffLineKind(this.prefix);

  final String prefix;
}

final class _DiffLine {
  const _DiffLine(this.kind, this.text);

  final _DiffLineKind kind;
  final String text;
}

final class _DiffHunk {
  const _DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<_DiffLine> lines;
}

List<_DiffLine> _buildDiffLines(List<String> oldLines, List<String> newLines) {
  var prefixLength = 0;
  while (prefixLength < oldLines.length &&
      prefixLength < newLines.length &&
      oldLines[prefixLength] == newLines[prefixLength]) {
    prefixLength++;
  }

  var suffixLength = 0;
  while (suffixLength < oldLines.length - prefixLength &&
      suffixLength < newLines.length - prefixLength &&
      oldLines[oldLines.length - suffixLength - 1] ==
          newLines[newLines.length - suffixLength - 1]) {
    suffixLength++;
  }

  final oldMiddle = oldLines.sublist(
    prefixLength,
    oldLines.length - suffixLength,
  );
  final newMiddle = newLines.sublist(
    prefixLength,
    newLines.length - suffixLength,
  );
  final middle =
      _buildMyersDiff(oldMiddle, newMiddle) ??
      <_DiffLine>[
        for (final line in oldMiddle) _DiffLine(_DiffLineKind.deletion, line),
        for (final line in newMiddle) _DiffLine(_DiffLineKind.addition, line),
      ];

  return [
    for (var index = 0; index < prefixLength; index++)
      _DiffLine(_DiffLineKind.context, oldLines[index]),
    ...middle,
    for (
      var index = oldLines.length - suffixLength;
      index < oldLines.length;
      index++
    )
      _DiffLine(_DiffLineKind.context, oldLines[index]),
  ];
}

List<_DiffLine>? _buildMyersDiff(List<String> oldLines, List<String> newLines) {
  if (oldLines.isEmpty) {
    return [
      for (final line in newLines) _DiffLine(_DiffLineKind.addition, line),
    ];
  }
  if (newLines.isEmpty) {
    return [
      for (final line in oldLines) _DiffLine(_DiffLineKind.deletion, line),
    ];
  }

  final maximumDistance = oldLines.length + newLines.length;
  final distanceLimit = maximumDistance < _maxMyersEditDistance
      ? maximumDistance
      : _maxMyersEditDistance;
  final frontier = <int, int>{1: 0};
  final trace = <Map<int, int>>[];

  for (var distance = 0; distance <= distanceLimit; distance++) {
    trace.add(Map<int, int>.of(frontier));
    for (var diagonal = -distance; diagonal <= distance; diagonal += 2) {
      final fromDeletion = frontier[diagonal - 1] ?? -1;
      final fromAddition = frontier[diagonal + 1] ?? -1;
      var oldIndex =
          diagonal == -distance ||
              (diagonal != distance && fromDeletion < fromAddition)
          ? fromAddition
          : fromDeletion + 1;
      if (oldIndex < 0) {
        oldIndex = 0;
      }
      var newIndex = oldIndex - diagonal;
      while (oldIndex < oldLines.length &&
          newIndex < newLines.length &&
          oldLines[oldIndex] == newLines[newIndex]) {
        oldIndex++;
        newIndex++;
      }
      frontier[diagonal] = oldIndex;
      if (oldIndex >= oldLines.length && newIndex >= newLines.length) {
        return _backtrackMyersDiff(trace, oldLines, newLines);
      }
    }
  }
  return null;
}

List<_DiffLine> _backtrackMyersDiff(
  List<Map<int, int>> trace,
  List<String> oldLines,
  List<String> newLines,
) {
  var oldIndex = oldLines.length;
  var newIndex = newLines.length;
  final reversed = <_DiffLine>[];

  for (var distance = trace.length - 1; distance >= 0; distance--) {
    final frontier = trace[distance];
    final diagonal = oldIndex - newIndex;
    final fromDeletion = frontier[diagonal - 1] ?? -1;
    final fromAddition = frontier[diagonal + 1] ?? -1;
    final previousDiagonal =
        diagonal == -distance ||
            (diagonal != distance && fromDeletion < fromAddition)
        ? diagonal + 1
        : diagonal - 1;
    final previousOldIndex = frontier[previousDiagonal] ?? 0;
    final previousNewIndex = previousOldIndex - previousDiagonal;

    while (oldIndex > previousOldIndex && newIndex > previousNewIndex) {
      reversed.add(_DiffLine(_DiffLineKind.context, oldLines[oldIndex - 1]));
      oldIndex--;
      newIndex--;
    }
    if (distance == 0) {
      break;
    }
    if (oldIndex == previousOldIndex) {
      reversed.add(_DiffLine(_DiffLineKind.addition, newLines[newIndex - 1]));
      newIndex--;
    } else {
      reversed.add(_DiffLine(_DiffLineKind.deletion, oldLines[oldIndex - 1]));
      oldIndex--;
    }
  }

  return reversed.reversed.toList(growable: false);
}

List<_DiffHunk> _buildDiffHunks(List<_DiffLine> lines) {
  final changedIndices = <int>[
    for (var index = 0; index < lines.length; index++)
      if (lines[index].kind != _DiffLineKind.context) index,
  ];
  if (changedIndices.isEmpty) {
    return const [];
  }

  final oldPositions = List<int>.filled(lines.length + 1, 1);
  final newPositions = List<int>.filled(lines.length + 1, 1);
  final oldConsumed = List<int>.filled(lines.length + 1, 0);
  final newConsumed = List<int>.filled(lines.length + 1, 0);
  for (var index = 0; index < lines.length; index++) {
    final kind = lines[index].kind;
    oldPositions[index + 1] =
        oldPositions[index] + (kind == _DiffLineKind.addition ? 0 : 1);
    newPositions[index + 1] =
        newPositions[index] + (kind == _DiffLineKind.deletion ? 0 : 1);
    oldConsumed[index + 1] =
        oldConsumed[index] + (kind == _DiffLineKind.addition ? 0 : 1);
    newConsumed[index + 1] =
        newConsumed[index] + (kind == _DiffLineKind.deletion ? 0 : 1);
  }

  final hunks = <_DiffHunk>[];
  var groupStart = 0;
  while (groupStart < changedIndices.length) {
    var groupEnd = groupStart;
    while (groupEnd + 1 < changedIndices.length &&
        changedIndices[groupEnd + 1] - changedIndices[groupEnd] - 1 <=
            _diffContextLines * 2) {
      groupEnd++;
    }

    var start = changedIndices[groupStart];
    var leadingContext = 0;
    while (start > 0 &&
        leadingContext < _diffContextLines &&
        lines[start - 1].kind == _DiffLineKind.context) {
      start--;
      leadingContext++;
    }
    var end = changedIndices[groupEnd] + 1;
    var trailingContext = 0;
    while (end < lines.length &&
        trailingContext < _diffContextLines &&
        lines[end].kind == _DiffLineKind.context) {
      end++;
      trailingContext++;
    }

    final oldCount = oldConsumed[end] - oldConsumed[start];
    final newCount = newConsumed[end] - newConsumed[start];
    final oldPosition = oldPositions[start];
    final newPosition = newPositions[start];
    hunks.add(
      _DiffHunk(
        oldStart: oldCount == 0 ? oldPosition - 1 : oldPosition,
        oldCount: oldCount,
        newStart: newCount == 0 ? newPosition - 1 : newPosition,
        newCount: newCount,
        lines: lines.sublist(start, end),
      ),
    );
    groupStart = groupEnd + 1;
  }
  return hunks;
}

AcpPlan? _mapPlan(List<d.AcpPlanEntry> plan) {
  if (plan.isEmpty) {
    return null;
  }
  return AcpPlan(
    items: [
      for (final entry in plan)
        AcpPlanItem(
          title: entry.content,
          status: _mapPlanStatus(entry.status),
          priority: _mapPlanPriority(entry.priority),
        ),
    ],
  );
}

AcpPlanItemStatus _mapPlanStatus(d.AcpPlanStatus status) =>
    switch (status.value) {
      'in_progress' => AcpPlanItemStatus.inProgress,
      'completed' => AcpPlanItemStatus.completed,
      _ => AcpPlanItemStatus.pending,
    };

AcpPlanPriority? _mapPlanPriority(d.AcpPlanPriority priority) =>
    switch (priority.value) {
      'high' => AcpPlanPriority.high,
      'medium' => AcpPlanPriority.medium,
      'low' => AcpPlanPriority.low,
      _ => null,
    };

AcpUsage? _mapUsage(d.AcpUsageUpdate? usage) {
  if (usage == null) {
    return null;
  }
  final window = usage.size > 0 ? usage.size : null;
  final used = usage.used > 0 ? usage.used : null;
  if (window == null && used == null) {
    return null;
  }
  return AcpUsage(contextWindow: window, contextUsedTokens: used);
}

AcpStatusEntry? _mapFatalStatus(d.AcpSessionState state) {
  final error = state.error;
  if (error != null) {
    return AcpStatusEntry(
      id: 'status-error',
      message: error.message,
      severity: _severityForError(error.kind),
    );
  }
  return null;
}

List<AcpStatusEntry> _mapStatuses(d.AcpSessionState state) {
  final fatal = _mapFatalStatus(state);
  if (fatal != null) {
    return <AcpStatusEntry>[fatal];
  }

  final statuses = <AcpStatusEntry>[];
  final warning = state.warning;
  if (warning != null) {
    statuses.add(
      AcpStatusEntry(
        id: 'status-warning',
        message: warning.message,
        severity: AcpStatusSeverity.warning,
      ),
    );
  }

  final connectionStatus = _connectionStatusMessage(state.status);
  if (connectionStatus != null) {
    statuses.add(
      AcpStatusEntry(
        id: 'status-connection',
        message: connectionStatus.$1,
        severity: connectionStatus.$2,
      ),
    );
  }

  if (state.promptStatus == d.AcpPromptStatus.idle) {
    final stop = _stopReasonMessage(state.lastStopReason);
    if (stop != null) {
      statuses.add(
        AcpStatusEntry(id: 'status-stop', message: stop.$1, severity: stop.$2),
      );
    }
  }
  return statuses;
}

AcpStatusSeverity _severityForError(d.AcpSessionErrorKind kind) =>
    switch (kind) {
      d.AcpSessionErrorKind.unsupportedCapability => AcpStatusSeverity.warning,
      _ => AcpStatusSeverity.error,
    };

(String, AcpStatusSeverity)? _connectionStatusMessage(
  d.AcpConnectionStatus status,
) => switch (status) {
  d.AcpConnectionStatus.reconnecting => (
    'Reconnecting to the agent…',
    AcpStatusSeverity.warning,
  ),
  d.AcpConnectionStatus.detached => (
    'Detached from this session.',
    AcpStatusSeverity.info,
  ),
  d.AcpConnectionStatus.authenticationRequired => (
    'This agent requires authentication.',
    AcpStatusSeverity.warning,
  ),
  d.AcpConnectionStatus.bridgeExpired => (
    'The remote bridge has expired.',
    AcpStatusSeverity.error,
  ),
  d.AcpConnectionStatus.providerExited => (
    'The agent process exited.',
    AcpStatusSeverity.error,
  ),
  d.AcpConnectionStatus.failed => (
    'The session failed.',
    AcpStatusSeverity.error,
  ),
  d.AcpConnectionStatus.closed => (
    'The session is closed.',
    AcpStatusSeverity.info,
  ),
  _ => null,
};

(String, AcpStatusSeverity)? _stopReasonMessage(d.AcpStopReason? reason) {
  if (reason == null) {
    return null;
  }
  return switch (reason.value) {
    'max_tokens' => (
      'Response stopped: token limit reached.',
      AcpStatusSeverity.warning,
    ),
    'max_turn_requests' => (
      'Response stopped: request limit reached.',
      AcpStatusSeverity.warning,
    ),
    'refusal' => ('The agent declined to continue.', AcpStatusSeverity.warning),
    'cancelled' => ('The turn was cancelled.', AcpStatusSeverity.info),
    _ => null,
  };
}

String _bound(String value, int maxChars) {
  if (value.length <= maxChars) {
    return value;
  }
  return '${value.substring(0, maxChars)}\n…';
}
