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

  final plan = _mapPlan(state.plan);
  if (plan != null) {
    entries.add(AcpPlanEntry(id: 'plan', plan: plan));
  }

  final usage = _mapUsage(state.usage);
  if (usage != null) {
    entries.add(AcpUsageEntry(id: 'usage', usage: usage));
  }

  final status = _mapStatus(state);
  if (status != null) {
    entries.add(status);
  }

  return List<AcpTimelineEntry>.unmodifiable(entries);
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
      return AcpUserPromptEntry(id: 'msg-${entry.order}', parts: parts);
    case d.AcpMessageRole.agent:
      return AcpAssistantMessageEntry(
        id: 'msg-${entry.order}',
        markdown: _markdownFromContent(entry.content),
        status: status,
      );
    case d.AcpMessageRole.thought:
      return AcpThoughtEntry(
        id: 'msg-${entry.order}',
        markdown: _markdownFromContent(entry.content),
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
        }
      case d.AcpToolTerminal():
      case d.AcpUnknownToolContent():
        break;
    }
  }

  final rawInput = _formatToolPayload(entry.rawInput);
  var rawOutput = _formatToolPayload(entry.rawOutput);
  if (rawOutput == null && outputBlocks.isNotEmpty) {
    rawOutput = _bound(outputBlocks.join('\n\n'), kAcpMapperMaxToolTextChars);
  }

  return AcpToolCallEntry(
    id: 'tool-${entry.toolCallId}',
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
    ),
  );
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
  final buffer = StringBuffer()
    ..writeln('--- a/$path')
    ..writeln('+++ b/$path')
    ..writeln('@@ -1,${oldLines.length} +1,${newLines.length} @@');
  for (final line in oldLines) {
    buffer.writeln('-$line');
  }
  for (final line in newLines) {
    buffer.writeln('+$line');
  }
  return buffer.toString().trimRight();
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

AcpStatusEntry? _mapStatus(d.AcpSessionState state) {
  final error = state.error;
  if (error != null) {
    return AcpStatusEntry(
      id: 'status-error',
      message: error.message,
      severity: _severityForError(error.kind),
    );
  }

  final connectionStatus = _connectionStatusMessage(state.status);
  if (connectionStatus != null) {
    return AcpStatusEntry(
      id: 'status-connection',
      message: connectionStatus.$1,
      severity: connectionStatus.$2,
    );
  }

  if (state.promptStatus == d.AcpPromptStatus.idle) {
    final stop = _stopReasonMessage(state.lastStopReason);
    if (stop != null) {
      return AcpStatusEntry(
        id: 'status-stop',
        message: stop.$1,
        severity: stop.$2,
      );
    }
  }
  return null;
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
