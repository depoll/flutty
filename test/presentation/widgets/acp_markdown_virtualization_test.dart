// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
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
