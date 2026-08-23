/// Normalizes line-wrapped base64 image destinations in assistant Markdown.
///
/// Models commonly wrap long `data:image/...;base64,...` destinations across
/// display lines. CommonMark treats those newlines as syntax boundaries, so the
/// image is rendered as literal text. Base64 whitespace is insignificant; this
/// helper removes ASCII whitespace only when the complete destination is a
/// validated base64 image data URI. Other links and prose remain byte-for-byte
/// unchanged.
String normalizeAcpMarkdownDataImages(String source) {
  if (!source.contains('data:image/')) return source;

  StringBuffer? output;
  var copiedThrough = 0;
  var searchFrom = 0;
  var fenceScanFrom = 0;
  String? fenceMarker;

  void scanFencesThrough(int limit) {
    while (fenceScanFrom < limit) {
      final lineEnd = source.indexOf('\n', fenceScanFrom);
      if (lineEnd < 0 || lineEnd >= limit) return;
      final line = source.substring(fenceScanFrom, lineEnd).trimLeft();
      final marker = line.startsWith('```')
          ? '```'
          : line.startsWith('~~~')
          ? '~~~'
          : null;
      if (marker != null) {
        if (fenceMarker == null) {
          fenceMarker = marker;
        } else if (fenceMarker == marker) {
          fenceMarker = null;
        }
      }
      fenceScanFrom = lineEnd + 1;
    }
  }

  while (searchFrom < source.length) {
    final imageStart = source.indexOf('![', searchFrom);
    if (imageStart < 0) break;
    scanFencesThrough(imageStart);
    final destinationStartMarker = source.indexOf('](', imageStart + 2);
    if (destinationStartMarker < 0) break;
    if (fenceMarker != null) {
      searchFrom = destinationStartMarker + 2;
      continue;
    }
    final destinationStart = destinationStartMarker + 2;
    if (!source.startsWith('data:image/', destinationStart)) {
      searchFrom = destinationStart;
      continue;
    }
    final destinationEnd = source.indexOf(')', destinationStart);
    if (destinationEnd < 0) break;

    final raw = source.substring(destinationStart, destinationEnd);
    final compact = _withoutAsciiWhitespace(raw);
    if (!_isBase64ImageDataUri(compact)) {
      searchFrom = destinationEnd + 1;
      continue;
    }

    output ??= StringBuffer();
    output
      ..write(source.substring(copiedThrough, destinationStart))
      ..write(compact);
    copiedThrough = destinationEnd;
    searchFrom = destinationEnd + 1;
  }

  if (output == null) return source;
  output.write(source.substring(copiedThrough));
  return output.toString();
}

/// Whether [line] contains a complete normalized inline base64 image.
///
/// Virtual Markdown segmentation keeps such lines atomic so a data URI never
/// gets split into separate `MarkdownBody` instances.
bool containsAcpMarkdownDataImage(String line) =>
    line.contains('](data:image/') && line.contains(';base64,');

String _withoutAsciiWhitespace(String value) {
  var firstWhitespace = -1;
  for (var index = 0; index < value.length; index++) {
    if (_isAsciiWhitespace(value.codeUnitAt(index))) {
      firstWhitespace = index;
      break;
    }
  }
  if (firstWhitespace < 0) return value;

  final output = StringBuffer(value.substring(0, firstWhitespace));
  for (var index = firstWhitespace; index < value.length; index++) {
    final codeUnit = value.codeUnitAt(index);
    if (!_isAsciiWhitespace(codeUnit)) output.writeCharCode(codeUnit);
  }
  return output.toString();
}

bool _isBase64ImageDataUri(String value) {
  const prefix = 'data:image/';
  const marker = ';base64,';
  if (!value.startsWith(prefix)) return false;
  final markerIndex = value.indexOf(marker, prefix.length);
  if (markerIndex <= prefix.length || markerIndex > 256) return false;

  for (var index = prefix.length; index < markerIndex; index++) {
    final codeUnit = value.codeUnitAt(index);
    final valid =
        (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        codeUnit == 0x2B || // +
        codeUnit == 0x2D || // -
        codeUnit == 0x2E; // .
    if (!valid) return false;
  }

  final payloadStart = markerIndex + marker.length;
  if (payloadStart >= value.length) return false;
  for (var index = payloadStart; index < value.length; index++) {
    final codeUnit = value.codeUnitAt(index);
    final valid =
        (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        codeUnit == 0x2B || // +
        codeUnit == 0x2F || // /
        codeUnit == 0x3D || // =
        codeUnit == 0x2D || // base64url -
        codeUnit == 0x5F; // base64url _
    if (!valid) return false;
  }
  return true;
}

bool _isAsciiWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D ||
    codeUnit == 0x0C;
