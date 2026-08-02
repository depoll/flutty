import 'dart:collection';

class ByteConsumer {
  final _queue = ListQueue<List<int>>();

  final _consumed = ListQueue<List<int>>();

  var _currentOffset = 0;

  var _length = 0;

  var _totalConsumed = 0;

  /// A high surrogate from the end of the previous [add] whose low half has not
  /// arrived yet.
  ///
  /// Chunk boundaries fall wherever the transport and the parse slicer happen
  /// to land, so an astral character is regularly split across two chunks. In a
  /// terminal stream that character is overwhelmingly the Kitty Unicode
  /// placeholder U+10EEEE, emitted once per cell of every image an agent CLI
  /// draws. Decoding each chunk in isolation turned the split pair into two
  /// lone surrogates: two broken cells instead of one, and — because the
  /// graphics layer keys on the placeholder code point — no placeholder
  /// registered for the cell, so the row/column diacritics that follow were
  /// written as ordinary cells too. That renders them as stray combining marks
  /// (U+030D is a vertical line) and pushes the rest of the line right by three
  /// columns per placeholder, which strands the frame the app is repainting.
  int _pendingHighSurrogate = 0;

  void add(String data) {
    if (data.isEmpty) return;
    final block = _toCodePoints(data);
    if (block.isEmpty) return;
    _queue.addLast(block);
    _length += block.length;
  }

  /// Converts [data] into a list of Unicode code points (matching
  /// `String.runes`) while avoiding the cost of the [Runes] iterator, which
  /// decodes the whole string through a general-purpose state machine.
  ///
  /// The overwhelmingly common terminal payload — including the multi-megabyte
  /// base64 of replayed Kitty images that land on the window-switch parse
  /// critical path — contains no surrogate pairs, so the UTF-16 code units are
  /// already the code points. In that case the lazy [String.codeUnits] view is
  /// returned directly with no copy. Only when a surrogate pair is present, or
  /// one is still pending from the previous chunk, do we fall back to combining.
  List<int> _toCodePoints(String data) {
    if (_pendingHighSurrogate != 0) {
      return _combineSurrogatePairs(data.codeUnits, 0);
    }
    final units = data.codeUnits;
    final length = units.length;
    for (var i = 0; i < length; i++) {
      final unit = units[i];
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        return _combineSurrogatePairs(units, i);
      }
    }
    return units;
  }

  List<int> _combineSurrogatePairs(List<int> units, int firstSurrogate) {
    final length = units.length;
    final out = <int>[];
    final pending = _pendingHighSurrogate;
    _pendingHighSurrogate = 0;
    var start = 0;
    if (pending != 0) {
      if (length > 0 && units[0] >= 0xDC00 && units[0] <= 0xDFFF) {
        out.add(0x10000 + ((pending - 0xD800) << 10) + (units[0] - 0xDC00));
        start = 1;
      } else {
        // The low half never came. Keep the orphan rather than silently
        // dropping input the app counted on advancing the cursor.
        out.add(pending);
      }
    }
    for (var i = start; i < firstSurrogate; i++) {
      out.add(units[i]);
    }
    for (var i = start > firstSurrogate ? start : firstSurrogate;
        i < length;
        i++) {
      final unit = units[i];
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= length) {
          // Hold the high half back so the next chunk can complete the pair.
          _pendingHighSurrogate = unit;
          continue;
        }
        final low = units[i + 1];
        if (low >= 0xDC00 && low <= 0xDFFF) {
          out.add(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
          i++;
          continue;
        }
      }
      out.add(unit);
    }
    return out;
  }

  int peek() {
    final data = _queue.first;
    if (_currentOffset < data.length) {
      return data[_currentOffset];
    } else {
      final result = consume();
      rollback();
      return result;
    }
  }

  int consume() {
    final data = _queue.first;

    if (_currentOffset >= data.length) {
      _consumed.add(_queue.removeFirst());
      _currentOffset -= data.length;
      return consume();
    }

    _length--;
    _totalConsumed++;
    return data[_currentOffset++];
  }

  /// Rolls back the last [n] call.
  void rollback([int n = 1]) {
    _currentOffset -= n;
    _totalConsumed -= n;
    _length += n;
    while (_currentOffset < 0) {
      final rollback = _consumed.removeLast();
      _queue.addFirst(rollback);
      _currentOffset += rollback.length;
    }
  }

  /// Rolls back to the state when this consumer had [length] bytes.
  void rollbackTo(int length) {
    rollback(length - _length);
  }

  int get length => _length;

  int get totalConsumed => _totalConsumed;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Unreferences data blocks that have been consumed. After calling this
  /// method, the consumer will not be able to roll back to consumed blocks.
  void unrefConsumedBlocks() {
    _consumed.clear();
  }

  /// Resets the consumer to its initial state.
  void reset() {
    _queue.clear();
    _consumed.clear();
    _currentOffset = 0;
    _totalConsumed = 0;
    _length = 0;
    _pendingHighSurrogate = 0;
  }
}
