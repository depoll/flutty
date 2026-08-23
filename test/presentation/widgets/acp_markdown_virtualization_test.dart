// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_data_images.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_virtualization.dart';

void main() {
  test('keeps short Markdown as one unchanged segment', () {
    const source = 'A short **response**.';

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks, [source]);
  });

  test('bounds long prose without dropping or reordering content', () {
    final source = List.generate(
      1200,
      (index) => 'Paragraph $index with enough text to exercise segmentation.',
    ).join('\n\n');

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    expect(
      chunks.every((chunk) => chunk.length <= kAcpMarkdownVirtualChunkChars),
      isTrue,
    );
    expect(chunks.join(), source);
  });

  test('normalizes and keeps a wrapped inline data image atomic', () {
    final payload = List.filled(9000, 'A').join();
    final wrappedPayload = payload.replaceAllMapped(
      RegExp('.{1,72}'),
      (match) => '${match.group(0)}\n',
    );
    final source =
        'before\n\n![diagram](data:image/\npng;base64,$wrappedPayload)\n\nafter';

    final chunks = splitAcpMarkdownForVirtualization(source, targetChars: 1024);

    final imageChunks = chunks.where((chunk) => chunk.contains('![diagram]'));
    expect(imageChunks, hasLength(1));
    expect(imageChunks.single.length, greaterThan(1024));
    expect(imageChunks.single, isNot(contains('image/\npng')));
    expect(imageChunks.single, isNot(contains('\nAAAA')));
    expect(chunks.join(), contains('data:image/png;base64,$payload'));
    expect(chunks.join(), startsWith('before'));
    expect(chunks.join(), endsWith('after'));
  });

  test('leaves wrapped data-image syntax unchanged inside code fences', () {
    const source =
        '```text\n'
        '![literal](data:image/\npng;base64,AAAA\nBBBB)\n'
        '```\n';

    expect(normalizeAcpMarkdownDataImages(source), source);
  });

  test('bounds long literal text without changing pasted diagnostics', () {
    final source = List.generate(
      1200,
      (index) => 'diagnostic $index: state, timing, and stack details',
    ).join('\n');

    final chunks = splitAcpTextForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    expect(
      chunks.every((chunk) => chunk.length <= kAcpTextVirtualChunkChars),
      isTrue,
    );
    expect(chunks.join(), source);
  });

  test('closes and reopens fenced code across segment boundaries', () {
    final source =
        '```dart\n${List.generate(1200, (index) => 'print($index);').join('\n')}\n```\n';

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks) {
      expect(chunk.trimLeft(), startsWith('```dart'));
      expect(chunk.trimRight(), endsWith('```'));
    }
  });

  test('splits one giant line without breaking surrogate pairs', () {
    final source = List.filled(10000, '🙂 word').join(' ');

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    expect(chunks.join(), source);
    for (final chunk in chunks) {
      expect(chunk.runes.toList(), isNotEmpty);
    }
  });
}
