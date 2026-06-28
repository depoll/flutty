import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

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

    if (!keepTerminalReference) {
      _terminal = null;
    }
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

  /// Whether any tracked hyperlink covers a cell in the inclusive column range
  /// [startColumn]–[endColumn] on [row].
  ///
  /// Used to avoid layering heuristic linkification (e.g. file paths) over text
  /// the program already marked as an OSC 8 hyperlink.
  bool hasLinkInRowRange(int row, int startColumn, int endColumn) {
    final terminal = _terminal;
    if (terminal == null || endColumn < startColumn) {
      return false;
    }

    _pruneDetachedHyperlinks();

    final queryStart = CellOffset(startColumn, row);
    final queryEnd = CellOffset(endColumn + 1, row);
    bool intersects(CellOffset start, CellOffset end) =>
        _compareOffsets(start, queryEnd) < 0 &&
        _compareOffsets(queryStart, end) < 0;

    final activeHyperlink = _pendingHyperlink;
    if (activeHyperlink != null &&
        intersects(
          activeHyperlink.startAnchor.offset,
          _currentCursorOffset(terminal),
        )) {
      return true;
    }

    for (final hyperlink in _trackedHyperlinks) {
      if (hyperlink.attached &&
          intersects(
            hyperlink.startAnchor.offset,
            hyperlink.endAnchor.offset,
          )) {
        return true;
      }
    }

    return false;
  }

  /// Resolves the hyperlink anchored on [row] when exactly one distinct
  /// destination spans that row.
  ///
  /// Touch taps rarely land on the exact cell of a short label like `#587`, so
  /// this acts as a forgiving fallback: if a rendered row carries a single
  /// hyperlink, a tap anywhere on it opens that link. Rows with two or more
  /// distinct destinations stay ambiguous and resolve to `null`.
  String? resolveLinkOnRow(int row) {
    final terminal = _terminal;
    if (terminal == null) {
      return null;
    }

    _pruneDetachedHyperlinks();

    final destinations = <String>{};
    String? lastDestination;

    void consider(CellOffset start, CellOffset end, Uri uri) {
      if (row >= start.y && row <= end.y) {
        final destination = uri.toString();
        destinations.add(destination);
        lastDestination = destination;
      }
    }

    final activeHyperlink = _pendingHyperlink;
    if (activeHyperlink != null) {
      consider(
        activeHyperlink.startAnchor.offset,
        _currentCursorOffset(terminal),
        activeHyperlink.uri,
      );
    }
    for (final hyperlink in _trackedHyperlinks) {
      if (hyperlink.attached) {
        consider(
          hyperlink.startAnchor.offset,
          hyperlink.endAnchor.offset,
          hyperlink.uri,
        );
      }
    }

    return destinations.length == 1 ? lastDestination : null;
  }

  /// Number of fully tracked hyperlinks currently retained in memory.
  @visibleForTesting
  int get trackedHyperlinkCount => _trackedHyperlinks.length;

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

    // Drop a still-open hyperlink whose start anchor detached (e.g. the line
    // scrolled out of scrollback or the screen was cleared before the closing
    // OSC 8 arrived) so it can't shadow later taps with a stale destination.
    final pendingHyperlink = _pendingHyperlink;
    if (pendingHyperlink != null && !pendingHyperlink.attached) {
      pendingHyperlink.dispose();
      _pendingHyperlink = null;
    }
  }

  CellOffset _currentCursorOffset(Terminal terminal) =>
      CellOffset(terminal.buffer.cursorX, terminal.buffer.absoluteCursorY);
}

class _PendingTerminalHyperlink {
  _PendingTerminalHyperlink({required this.uri, required this.startAnchor});

  final Uri uri;
  final CellAnchor startAnchor;

  bool get attached => startAnchor.attached;

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
