import 'package:flutter/foundation.dart';
import 'package:kterm/kterm.dart';

/// A value-equal snapshot of terminal rows used by connection preview cards.
@immutable
class TerminalPreviewSnapshot {
  /// Creates a [TerminalPreviewSnapshot].
  const TerminalPreviewSnapshot({required this.lines, required this.plainText});

  /// Preview rows in display order.
  final List<TerminalPreviewLine> lines;

  /// Plain-text fallback matching the rendered preview rows.
  final String plainText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPreviewSnapshot &&
          plainText == other.plainText &&
          listEquals(lines, other.lines);

  @override
  int get hashCode => Object.hash(plainText, Object.hashAll(lines));
}

/// One terminal display row in a [TerminalPreviewSnapshot].
@immutable
class TerminalPreviewLine {
  /// Creates a [TerminalPreviewLine].
  const TerminalPreviewLine({required this.text, required this.cells});

  /// Sanitized plain text for the row.
  final String text;

  /// Copied kterm cell data for this display row.
  final BufferLine cells;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPreviewLine &&
          text == other.text &&
          _bufferLineEquals(cells, other.cells);

  @override
  int get hashCode => Object.hash(text, _bufferLineHash(cells));
}

bool _bufferLineEquals(BufferLine a, BufferLine b) {
  if (a.length != b.length || a.isWrapped != b.isWrapped) {
    return false;
  }
  final cellDataLength = a.length * 4;
  for (var index = 0; index < cellDataLength; index++) {
    if (a.data[index] != b.data[index]) {
      return false;
    }
  }
  return true;
}

int _bufferLineHash(BufferLine line) {
  var result = Object.hash(line.length, line.isWrapped);
  final cellDataLength = line.length * 4;
  for (var index = 0; index < cellDataLength; index++) {
    result = Object.hash(result, line.data[index]);
  }
  return result;
}
