import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// Tracks semantic command locations emitted by OSC 133/633 and iTerm2 SetMark.
class TerminalCommandMarkTracker {
  /// Creates a bounded command-mark tracker.
  TerminalCommandMarkTracker({this.maxRetainedMarks = 200});

  /// Maximum attached anchors retained in scrollback.
  final int maxRetainedMarks;
  Terminal? _terminal;
  final List<CellAnchor> _marks = <CellAnchor>[];

  /// Number of marks still attached to terminal scrollback.
  int get markCount {
    _pruneDetached();
    return _marks.length;
  }

  /// Attaches this tracker to a persistent terminal.
  void attach(Terminal terminal) {
    if (identical(_terminal, terminal)) return;
    reset(keepTerminalReference: false);
    _terminal = terminal;
  }

  /// Handles command-executed markers and explicit iTerm2 marks.
  bool handlePrivateOsc(String code, List<String> args) {
    final isCommandExecuted =
        (code == '133' || code == '633') && args.firstOrNull == 'C';
    final isExplicitMark = code == '1337' && args.firstOrNull == 'SetMark';
    if (!isCommandExecuted && !isExplicitMark) return false;
    final terminal = _terminal;
    if (terminal == null || maxRetainedMarks <= 0) return false;

    _pruneDetached();
    final offset = CellOffset(
      terminal.buffer.cursorX,
      terminal.buffer.absoluteCursorY,
    );
    if (_marks.isNotEmpty && _marks.last.offset.y == offset.y) return false;
    _marks.add(terminal.buffer.createAnchorFromOffset(offset));
    while (_marks.length > maxRetainedMarks) {
      _marks.removeAt(0).dispose();
    }
    return true;
  }

  /// Returns the closest mark before [absoluteRow], wrapping to the newest.
  int? previousMarkRow(int absoluteRow) {
    _pruneDetached();
    if (_marks.isEmpty) return null;
    for (final mark in _marks.reversed) {
      if (mark.offset.y < absoluteRow) return mark.offset.y;
    }
    return _marks.last.offset.y;
  }

  /// Clears retained anchors.
  void reset({bool keepTerminalReference = true}) {
    for (final mark in _marks) {
      mark.dispose();
    }
    _marks.clear();
    if (!keepTerminalReference) _terminal = null;
  }

  void _pruneDetached() {
    _marks.removeWhere((mark) {
      if (mark.attached) return false;
      mark.dispose();
      return true;
    });
  }

  /// Attached mark rows exposed for focused tracker tests.
  @visibleForTesting
  List<int> get debugMarkRows {
    _pruneDetached();
    return _marks.map((mark) => mark.offset.y).toList(growable: false);
  }
}
