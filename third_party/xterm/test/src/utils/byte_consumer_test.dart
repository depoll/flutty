import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/utils/byte_consumer.dart';

List<int> _drain(ByteConsumer consumer) {
  final out = <int>[];
  while (consumer.isNotEmpty) {
    out.add(consumer.consume());
  }
  return out;
}

void main() {
  group('ByteConsumer.add', () {
    test('ASCII bytes are consumed as their code points', () {
      final consumer = ByteConsumer()..add('hello');
      expect(consumer.length, 5);
      expect(_drain(consumer), 'hello'.runes.toList());
    });

    test('matches String.runes for non-BMP code points (emoji)', () {
      const text = 'a🎉b👨‍👩‍👧c'; // mixes BMP, astral and ZWJ sequences
      final consumer = ByteConsumer()..add(text);
      final expected = text.runes.toList();
      expect(consumer.length, expected.length);
      expect(_drain(consumer), expected);
    });

    test('combines a surrogate pair into a single code point', () {
      const rocket = '🚀'; // U+1F680, one rune, two UTF-16 code units
      final consumer = ByteConsumer()..add(rocket);
      expect(consumer.length, 1);
      expect(_drain(consumer), [0x1F680]);
    });

    test('preserves a lone (unpaired) high surrogate like String.runes', () {
      final lone = String.fromCharCode(0xD83D); // high surrogate, no low
      // A trailing high surrogate is deferred, not dropped: the low half may
      // still be in the next chunk. Anything that proves it cannot pair
      // flushes it, so no input is lost.
      final consumer = ByteConsumer()
        ..add(lone)
        ..add('');
      expect(consumer.isEmpty, isTrue);

      consumer.add('!');
      expect(_drain(consumer), [...lone.runes, '!'.runeAt(0)]);
    });

    test('handles code points split across multiple add() calls', () {
      // The slice pump never splits a surrogate pair, but mixed sequential
      // adds must still decode each block correctly and report a stable length.
      final consumer = ByteConsumer()
        ..add('x')
        ..add('🚀')
        ..add('y');
      expect(consumer.length, 3);
      expect(_drain(consumer), ['x'.runeAt(0), 0x1F680, 'y'.runeAt(0)]);
    });

    // Chunk boundaries land wherever the transport and the parse slicer put
    // them, so a surrogate pair does get split in practice. Decoding each chunk
    // in isolation emitted two lone surrogates, which write two broken cells
    // instead of one — and for the Kitty placeholder U+10EEEE it also loses the
    // code point the graphics layer keys on.
    test('combines a surrogate pair split across two add() calls', () {
      const rocket = '🚀'; // U+1F680
      final consumer = ByteConsumer()
        ..add('a${rocket.substring(0, 1)}')
        ..add('${rocket.substring(1)}b');

      expect(consumer.length, 3);
      expect(_drain(consumer), ['a'.runeAt(0), 0x1F680, 'b'.runeAt(0)]);
    });

    test('combines a placeholder split one code unit at a time', () {
      const placeholder = '\u{10EEEE}';
      final consumer = ByteConsumer();
      for (final unit in placeholder.codeUnits) {
        consumer.add(String.fromCharCode(unit));
      }

      expect(consumer.length, 1);
      expect(_drain(consumer), [0x10EEEE]);
    });

    test('a trailing high surrogate waits instead of emitting an orphan', () {
      const rocket = '🚀';
      final consumer = ByteConsumer()..add(rocket.substring(0, 1));

      expect(
        consumer.length,
        0,
        reason: 'the half pair must not be consumable as a code point',
      );

      consumer.add(rocket.substring(1));

      expect(consumer.length, 1);
      expect(_drain(consumer), [0x1F680]);
    });

    test('an unpaired high surrogate is still emitted once it cannot pair', () {
      final consumer = ByteConsumer()
        ..add('\uD83D') // high surrogate, no low half follows
        ..add('z');

      expect(_drain(consumer), [0xD83D, 'z'.runeAt(0)]);
    });

    test('reset() drops a pending high surrogate', () {
      const rocket = '🚀';
      final consumer = ByteConsumer()..add(rocket.substring(0, 1));
      consumer.reset();
      consumer.add('a');

      expect(_drain(consumer), ['a'.runeAt(0)]);
    });
  });
}

extension on String {
  int runeAt(int index) => runes.elementAt(index);
}
