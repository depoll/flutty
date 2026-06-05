import 'package:flutter/foundation.dart';
import 'package:kterm/kterm.dart';

/// Tracks OSC 8 terminal hyperlinks so taps can open links whose labels do not
/// visibly contain the destination URL.
class TerminalHyperlinkTracker {
  /// Creates a tracker that retains at most [maxRetainedLinks] fully closed
  /// hyperlinks. Oldest links are evicted first (LRU) once the cap is reached.
  TerminalHyperlinkTracker({int maxRetainedLinks = defaultMaxRetainedLinks})
    : _maxRetainedLinks = maxRetainedLinks;

  /// Default cap on the number of fully closed hyperlinks retained in memory.
  static const int defaultMaxRetainedLinks = 200;

  Terminal? _terminal;
  final _trackedHyperlinks = <_TrackedTerminalHyperlink>[];
  _PendingTerminalHyperlink? _pendingHyperlink;
  final int _maxRetainedLinks;
  final _normalizedHyperlinkUris = <String, String>{};
  final _normalizedHyperlinkTokens = <String, String>{};
  var _nextHyperlinkToken = 1;

  /// Attaches this tracker to [terminal].
  ///
  /// Reattaching to the same terminal preserves existing tracked hyperlinks so
  /// links remain tappable when a persisted session screen is rebuilt.
  void attach(Terminal terminal) {
    if (identical(_terminal, terminal)) {
      return;
    }

    reset(keepTerminalReference: false);
    _terminal = terminal;
  }

  /// Clears any tracked hyperlinks and disposes their anchors.
  void reset({bool keepTerminalReference = true}) {
    _pendingHyperlink?.dispose();
    _pendingHyperlink = null;

    for (final hyperlink in _trackedHyperlinks) {
      hyperlink.dispose();
    }
    _trackedHyperlinks.clear();
    _normalizedHyperlinkUris.clear();
    _normalizedHyperlinkTokens.clear();
    _nextHyperlinkToken = 1;

    if (!keepTerminalReference) {
      _terminal = null;
    }
  }

  /// Rewrites OSC 8 hyperlinks that kterm cannot parse losslessly.
  ///
  /// kterm treats semicolons inside the URI as OSC argument delimiters. Replacing
  /// those URIs with internal tokens lets kterm retain the rendered cell
  /// hyperlink while this tracker maps taps back to the original destination.
  String normalizeTerminalOutput(String input) {
    final output = StringBuffer();
    var cursor = 0;
    while (cursor < input.length) {
      final start = input.indexOf(_osc8Prefix, cursor);
      if (start == -1) {
        output.write(input.substring(cursor));
        break;
      }

      output.write(input.substring(cursor, start));
      final end = _oscTerminatorIndex(input, start + _osc8Prefix.length);
      if (end == null) {
        output.write(input.substring(start));
        break;
      }

      output.write(_normalizeOsc8Sequence(input.substring(start, end)));
      cursor = end;
    }
    return output.toString();
  }

  /// Handles private OSC sequences emitted by the terminal.
  ///
  /// OSC 8 sequences are used for hyperlinks. Opening a hyperlink records the
  /// current cursor position as the start anchor; closing it records the end
  /// anchor so later taps can resolve back to the hidden URL.
  void handlePrivateOsc(String code, List<String> args) {
    if (code != '8') {
      return;
    }

    final terminal = _terminal;
    if (terminal == null) {
      return;
    }

    _pruneDetachedHyperlinks();

    final nextUri = _parseHyperlinkUri(args);
    if (nextUri == null) {
      _closePendingHyperlink(terminal);
      return;
    }

    _closePendingHyperlink(terminal);
    _pendingHyperlink = _PendingTerminalHyperlink(
      uri: nextUri,
      startAnchor: terminal.buffer.createAnchorFromCursor(),
    );
  }

  /// Resolves the hyperlink at [offset], if one is currently tracked there.
  String? resolveLinkAt(CellOffset offset) {
    final terminal = _terminal;
    if (terminal == null) {
      return null;
    }

    _pruneDetachedHyperlinks();

    final nativeLink = _resolveNativeLinkAt(terminal, offset);
    if (nativeLink != null) {
      return nativeLink;
    }

    final activeHyperlink = _pendingHyperlink;
    if (activeHyperlink != null &&
        _containsOffset(
          start: activeHyperlink.startAnchor.offset,
          end: _currentCursorOffset(terminal),
          target: offset,
        )) {
      return activeHyperlink.uri.toString();
    }

    for (final hyperlink in _trackedHyperlinks.reversed) {
      if (hyperlink.contains(offset)) {
        return hyperlink.uri.toString();
      }
    }

    return null;
  }

  /// Number of fully tracked hyperlinks currently retained in memory.
  @visibleForTesting
  int get trackedHyperlinkCount {
    _pruneDetachedHyperlinks();
    final terminal = _terminal;
    final nativeCount = terminal == null
        ? 0
        : _cappedNativeHyperlinkIds(terminal).length;
    return nativeCount + _trackedHyperlinks.length;
  }

  Uri? _parseHyperlinkUri(List<String> args) {
    if (args.length < 2) {
      return null;
    }

    final uriText = args.sublist(1).join(';');
    if (uriText.isEmpty) {
      return null;
    }

    return Uri.tryParse(uriText);
  }

  void _closePendingHyperlink(Terminal terminal) {
    final pendingHyperlink = _pendingHyperlink;
    if (pendingHyperlink == null) {
      return;
    }

    final endAnchor = terminal.buffer.createAnchorFromCursor();
    final hyperlink = _TrackedTerminalHyperlink(
      uri: pendingHyperlink.uri,
      startAnchor: pendingHyperlink.startAnchor,
      endAnchor: endAnchor,
    );

    if (hyperlink.isEmpty) {
      hyperlink.dispose();
    } else {
      _trackedHyperlinks.add(hyperlink);
      _evictOverCapLinks();
    }

    _pendingHyperlink = null;
  }

  /// Disposes the oldest tracked hyperlinks until the retained count is within
  /// [_maxRetainedLinks]. Called after every new link is committed.
  void _evictOverCapLinks() {
    while (_trackedHyperlinks.length > _maxRetainedLinks) {
      _trackedHyperlinks.removeAt(0).dispose();
    }
  }

  void _pruneDetachedHyperlinks() {
    _trackedHyperlinks.removeWhere((hyperlink) {
      if (hyperlink.attached) {
        return false;
      }
      hyperlink.dispose();
      return true;
    });
  }

  String? _resolveNativeLinkAt(Terminal terminal, CellOffset offset) {
    if (offset.y < 0 || offset.y >= terminal.buffer.height || offset.x < 0) {
      return null;
    }

    final line = terminal.buffer.lines[offset.y];
    if (offset.x >= line.length) {
      return null;
    }

    final hyperlinkId = line.getHyperlinkId(offset.x);
    if (hyperlinkId == 0 ||
        !_cappedNativeHyperlinkIds(terminal).contains(hyperlinkId)) {
      return null;
    }

    final uri = terminal.getHyperlinkUri(hyperlinkId);
    if (uri == null) {
      return null;
    }
    return _normalizedHyperlinkUris[uri] ?? uri;
  }

  Set<int> _cappedNativeHyperlinkIds(Terminal terminal) {
    if (_maxRetainedLinks <= 0) {
      return const {};
    }

    final orderedIds = <int>[];
    final seenIds = <int>{};
    final activeUris = <String>{};
    for (var y = 0; y < terminal.buffer.height; y++) {
      final line = terminal.buffer.lines[y];
      for (var x = 0; x < line.length; x++) {
        final hyperlinkId = line.getHyperlinkId(x);
        if (hyperlinkId == 0) {
          continue;
        }
        final uri = terminal.getHyperlinkUri(hyperlinkId);
        if (uri == null) {
          continue;
        }
        activeUris.add(uri);
        if (!seenIds.add(hyperlinkId)) {
          continue;
        }
        orderedIds.add(hyperlinkId);
      }
    }
    _pruneNormalizedHyperlinkTokens(activeUris);

    if (orderedIds.length <= _maxRetainedLinks) {
      return seenIds;
    }

    return orderedIds.skip(orderedIds.length - _maxRetainedLinks).toSet();
  }

  void _pruneNormalizedHyperlinkTokens(Set<String> activeUris) {
    _normalizedHyperlinkUris.removeWhere(
      (token, _) => !activeUris.contains(token),
    );
    _normalizedHyperlinkTokens.removeWhere(
      (_, token) => !_normalizedHyperlinkUris.containsKey(token),
    );
  }

  CellOffset _currentCursorOffset(Terminal terminal) =>
      CellOffset(terminal.buffer.cursorX, terminal.buffer.absoluteCursorY);

  String _normalizeOsc8Sequence(String sequence) {
    final terminator = _oscTerminator(sequence);
    if (terminator == null) {
      return sequence;
    }

    final payload = sequence.substring(
      _oscPrefix.length,
      sequence.length - terminator.length,
    );
    final paramsStart = payload.indexOf(';');
    if (paramsStart == -1) {
      return sequence;
    }
    final uriStart = payload.indexOf(';', paramsStart + 1);
    if (uriStart == -1) {
      return sequence;
    }

    final uri = payload.substring(uriStart + 1);
    if (uri.isEmpty || !uri.contains(';')) {
      return sequence;
    }

    final token = _normalizedHyperlinkTokens.putIfAbsent(uri, () {
      final nextToken = 'monkeyssh-internal-hyperlink:${_nextHyperlinkToken++}';
      _normalizedHyperlinkUris[nextToken] = uri;
      return nextToken;
    });
    return '${sequence.substring(0, _oscPrefix.length + uriStart + 1)}'
        '$token$terminator';
  }
}

const _oscPrefix = '\x1b]';
const _osc8Prefix = '${_oscPrefix}8;';
const _oscStringTerminator = '\x1b\\';
const _oscBellTerminator = '\x07';

int? _oscTerminatorIndex(String input, int start) {
  var cursor = start;
  while (cursor < input.length) {
    final codeUnit = input.codeUnitAt(cursor);
    if (codeUnit == 0x07) {
      return cursor + 1;
    }
    if (codeUnit == 0x1B) {
      if (cursor + 1 >= input.length) {
        return null;
      }
      if (input.codeUnitAt(cursor + 1) == 0x5C) {
        return cursor + 2;
      }
      cursor += 1;
      continue;
    }
    cursor += 1;
  }
  return null;
}

String? _oscTerminator(String sequence) {
  if (sequence.endsWith(_oscStringTerminator)) {
    return _oscStringTerminator;
  }
  if (sequence.endsWith(_oscBellTerminator)) {
    return _oscBellTerminator;
  }
  return null;
}

class _PendingTerminalHyperlink {
  _PendingTerminalHyperlink({required this.uri, required this.startAnchor});

  final Uri uri;
  final CellAnchor startAnchor;

  void dispose() {
    startAnchor.dispose();
  }
}

class _TrackedTerminalHyperlink {
  _TrackedTerminalHyperlink({
    required this.uri,
    required this.startAnchor,
    required this.endAnchor,
  });

  final Uri uri;
  final CellAnchor startAnchor;
  final CellAnchor endAnchor;

  bool get attached => startAnchor.attached && endAnchor.attached;

  bool get isEmpty {
    if (!attached) {
      return true;
    }

    return _compareOffsets(startAnchor.offset, endAnchor.offset) >= 0;
  }

  bool contains(CellOffset offset) {
    if (!attached) {
      return false;
    }

    return _containsOffset(
      start: startAnchor.offset,
      end: endAnchor.offset,
      target: offset,
    );
  }

  void dispose() {
    startAnchor.dispose();
    endAnchor.dispose();
  }
}

bool _containsOffset({
  required CellOffset start,
  required CellOffset end,
  required CellOffset target,
}) => _compareOffsets(start, target) <= 0 && _compareOffsets(target, end) < 0;

int _compareOffsets(CellOffset a, CellOffset b) {
  if (a.y != b.y) {
    return a.y.compareTo(b.y);
  }
  return a.x.compareTo(b.x);
}
