import 'package:flutter/foundation.dart';

/// Visual role of one bounded native-agent preview row.
enum AcpNativePreviewKind {
  /// User-authored prompt content.
  user,

  /// Agent-authored response content.
  agent,

  /// Agent tool invocation.
  tool,

  /// Informational lifecycle content.
  status,
}

/// One content-safe row in a live native-agent connection preview.
@immutable
class AcpNativePreviewLine {
  /// Creates a preview row.
  const AcpNativePreviewLine({
    required this.kind,
    required this.text,
    this.active = false,
  });

  /// Conversation role used for icon, color, and hierarchy.
  final AcpNativePreviewKind kind;

  /// Bounded display text. This is never logged or persisted.
  final String text;

  /// Whether this row is still streaming/running.
  final bool active;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpNativePreviewLine &&
          kind == other.kind &&
          text == other.text &&
          active == other.active;

  @override
  int get hashCode => Object.hash(kind, text, active);
}

/// Bounded in-memory snapshot of the visible native-agent conversation.
@immutable
class AcpNativePreviewSnapshot {
  /// Creates a native preview snapshot.
  AcpNativePreviewSnapshot({
    required List<AcpNativePreviewLine> lines,
    this.progressFraction,
    this.indeterminate = false,
  }) : lines = List.unmodifiable(lines);

  /// Most recent role-aware conversation rows.
  final List<AcpNativePreviewLine> lines;

  /// Determinate plan progress, when available.
  final double? progressFraction;

  /// Whether the agent is actively working without determinate progress.
  final bool indeterminate;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpNativePreviewSnapshot &&
          listEquals(lines, other.lines) &&
          progressFraction == other.progressFraction &&
          indeterminate == other.indeterminate;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(lines), progressFraction, indeterminate);
}
