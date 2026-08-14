import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

/// Maximum decoded payload accepted from an iTerm2 inline-file sequence.
///
/// This matches the Kitty graphics transmission cap in the vendored xterm
/// renderer, preventing OSC 1337 from becoming a less-bounded path to the same
/// image decoder.
const int maxIterm2InlineImageBytes = 16 * 1024 * 1024;

/// Parses and displays an iTerm2 `OSC 1337 ; File=...` inline image.
///
/// Returns `true` for every `File=` command, including unsupported downloads or
/// malformed payloads, so the caller can consume the command without logging
/// user-controlled file metadata. Only `inline=1` payloads are decoded; remote
/// file downloads are deliberately not supported.
bool handleIterm2InlineImageOsc(Terminal terminal, List<String> args) {
  if (args.isEmpty || !args.first.startsWith('File=')) {
    return false;
  }

  final rawCommand = args.join(';');
  final separator = rawCommand.indexOf(':');
  if (separator < 0) {
    return true;
  }
  final metadata = _parseIterm2FileMetadata(
    rawCommand.substring('File='.length, separator),
  );
  if (metadata['inline'] != '1') {
    return true;
  }

  final encoded = rawCommand.substring(separator + 1);
  if (encoded.isEmpty || encoded.length > _maxEncodedImageLength) {
    return true;
  }

  final Uint8List imageBytes;
  try {
    imageBytes = base64Decode(encoded);
  } on FormatException {
    return true;
  }
  if (imageBytes.isEmpty || imageBytes.length > maxIterm2InlineImageBytes) {
    return true;
  }

  final graphicsArgs = <String, String>{
    'a': 'T',
    // The vendored renderer uses f=98 for Flutter-supported encoded image
    // containers, including PNG, JPEG, GIF, and APNG.
    'f': '98',
    'q': '2',
  };
  final columns = _parseIterm2CellDimension(
    metadata['width'],
    availableCells: terminal.viewWidth,
  );
  final rows = _parseIterm2CellDimension(
    metadata['height'],
    availableCells: terminal.viewHeight,
  );
  final preservesAspectRatio = metadata['preserveAspectRatio'] != '0';
  if (columns != null) {
    graphicsArgs['c'] = '$columns';
  }
  // A single constrained dimension lets the renderer derive the other from
  // the decoded image. When distortion is explicitly allowed, honor both.
  if (rows != null && (columns == null || !preservesAspectRatio)) {
    graphicsArgs['r'] = '$rows';
  }
  if (metadata['doNotMoveCursor'] == '1') {
    graphicsArgs['C'] = '1';
  }

  terminal
    ..graphicsCommandStart(graphicsArgs)
    ..graphicsDataChunk(imageBytes)
    ..graphicsCommandEnd();
  return true;
}

const int _maxEncodedImageLength = ((maxIterm2InlineImageBytes + 2) ~/ 3) * 4;

Map<String, String> _parseIterm2FileMetadata(String raw) {
  final metadata = <String, String>{};
  for (final field in raw.split(';')) {
    final separator = field.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    metadata[field.substring(0, separator)] = field.substring(separator + 1);
  }
  return metadata;
}

int? _parseIterm2CellDimension(String? raw, {required int availableCells}) {
  if (raw == null || raw.isEmpty || raw == 'auto' || availableCells <= 0) {
    return null;
  }
  final percentage = RegExp(r'^(\d{1,3})%$').firstMatch(raw);
  if (percentage != null) {
    final value = int.parse(percentage.group(1)!).clamp(1, 100);
    return ((availableCells * value) / 100).ceil().clamp(1, availableCells);
  }
  final cells = int.tryParse(raw);
  if (cells == null || cells <= 0) {
    // Pixel dimensions cannot be translated until the view has supplied cell
    // metrics, so retain natural image sizing instead of guessing.
    return null;
  }
  return cells.clamp(1, availableCells);
}
