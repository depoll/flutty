import 'dart:async';

/// Reads marker-framed output, optionally retaining partial output on timeout.
Future<({String output, int? status})> readCommandOutputUntilMarker(
  Stream<String> chunks,
  String marker, {
  bool allowPartialOnTimeout = false,
}) async {
  final pattern = RegExp('^${RegExp.escape(marker)}:([0-9]+)\$');
  final output = StringBuffer();
  final line = StringBuffer();
  var separator = '';
  try {
    await for (final chunk in chunks) {
      final parts = chunk.split('\n');
      for (final part in parts.take(parts.length - 1)) {
        line.write(part);
        final text = line.toString();
        line.clear();
        final match = pattern.firstMatch(text);
        if (match != null) {
          return (
            output: output.toString(),
            status: int.parse(match.group(1)!),
          );
        }
        output
          ..write(separator)
          ..write(text);
        separator = '\n';
      }
      line.write(parts.last);
    }
  } on TimeoutException {
    if (!allowPartialOnTimeout) rethrow;
  }
  return (output: '$output$separator$line', status: null);
}
