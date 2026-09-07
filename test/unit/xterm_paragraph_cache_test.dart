import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';

void main() {
  test('clear releases native paragraphs and allows reuse', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final first = cache.performAndCacheLayout(
      'a',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final second = cache.performAndCacheLayout(
      'b',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    expect(first.debugDisposed, isFalse);
    expect(cache.getLayoutFromCache(1), same(first));

    cache.clear();
    expect(first.debugDisposed, isTrue);
    expect(second.debugDisposed, isTrue);
    expect(cache.length, 0);
    expect(cache.getLayoutFromCache(1), isNull);
    expect(cache.clear, returnsNormally);

    final replacement = cache.performAndCacheLayout(
      'c',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    expect(replacement.debugDisposed, isFalse);
    expect(cache.getLayoutFromCache(1), same(replacement));
  });

  test('replacing a key releases only its old paragraph', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final old = cache.performAndCacheLayout(
      'a',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final other = cache.performAndCacheLayout(
      'b',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    final replacement = cache.performAndCacheLayout(
      'c',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );

    expect(old.debugDisposed, isTrue);
    expect(other.debugDisposed, isFalse);
    expect(replacement.debugDisposed, isFalse);
    expect(cache.length, 2);
    expect(cache.getLayoutFromCache(1), same(replacement));
    expect(cache.getLayoutFromCache(2), same(other));
  });

  test('cache hits still promote the least recently used entry', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final first = cache.performAndCacheLayout(
      'a',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final evicted = cache.performAndCacheLayout(
      'b',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    // Quiver owns capacity eviction; its uncached native object can be released
    // here because the test deliberately keeps a reference to it.
    addTearDown(evicted.dispose);
    expect(cache.getLayoutFromCache(1), same(first));
    final third = cache.performAndCacheLayout(
      'c',
      const TextStyle(),
      TextScaler.noScaling,
      3,
    );
    expect(cache.length, 2);
    expect(cache.getLayoutFromCache(2), isNull);
    expect(cache.getLayoutFromCache(1), same(first));
    expect(cache.getLayoutFromCache(3), same(third));
  });
}
