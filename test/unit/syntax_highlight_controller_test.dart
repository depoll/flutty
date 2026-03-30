import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_controller.dart';

void main() {
  group('SyntaxHighlightController', () {
    late SyntaxHighlightController controller;

    tearDown(() {
      controller.dispose();
    });

    test('buildTextSpan returns highlighted spans for Dart code', () {
      controller = SyntaxHighlightController(
        theme: const {
          'keyword': TextStyle(color: Color(0xFFFF00FF)),
          'string': TextStyle(color: Color(0xFF00FF00)),
          'comment': TextStyle(color: Color(0xFF808080)),
        },
        text: 'void main() { print("hello"); }',
        language: 'dart',
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // The span should have children (highlighted tokens), not just plain
      // text from the default controller.
      expect(span.children, isNotNull);
      expect(span.children, isNotEmpty);

      // Verify the full text reconstructed from spans matches the source.
      expect(span.toPlainText(), 'void main() { print("hello"); }');
    });

    test('buildTextSpan returns plain text for unknown language on empty', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: '',
        language: 'dart',
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // Empty text should produce no children or a plain span.
      expect(span.toPlainText(), isEmpty);
    });

    test('caches result when text does not change', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );

      final span1 = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      final span2 = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // On the second call the cached highlighted span is reused as the
      // single child of the returned wrapper, so it must be identical to
      // the first span that was originally returned.
      expect(span2.children!.first, same(span1));
    });

    test('re-highlights after text changes', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );

      // First build triggers highlighting; second assignment changes text.
      // ignore: cascade_invocations
      controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      // ignore: cascade_invocations
      controller.text = 'final y = 2;';

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(span.toPlainText(), 'final y = 2;');
    });

    test('skips highlighting for text exceeding size limit', () {
      final largeText = 'x' * (syntaxHighlightSizeLimit + 1);
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: largeText,
        language: 'dart',
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // Should fall through to super (plain text).
      expect(span.toPlainText(), largeText);
    });

    test('invalidateHighlightCache forces re-highlight', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );

      final span1 = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      controller.invalidateHighlightCache();

      final span2 = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // After cache invalidation, the inner span objects should differ.
      expect(identical(span1.children!.first, span2.children!.first), isFalse);
    });

    test('handles language change at runtime', () {
      controller = SyntaxHighlightController(
        theme: const {
          'keyword': TextStyle(color: Color(0xFFFF00FF)),
          'string': TextStyle(color: Color(0xFF00FF00)),
        },
        text: '{"key": "value"}',
        language: 'json',
      );

      // First build triggers highlighting; then change language and invalidate.
      // ignore: cascade_invocations
      controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      // ignore: cascade_invocations
      controller
        ..language = 'javascript'
        ..invalidateHighlightCache();

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(span.toPlainText(), '{"key": "value"}');
    });

    test('falls back to plain text on highlight failure', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'some text',
        language: 'not_a_real_language_xyz',
      );

      // Should not throw — falls back to plain text.
      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(span.toPlainText(), 'some text');
    });
  });
}

/// Minimal fake [BuildContext] for testing [buildTextSpan] which does not
/// use the context for syntax-highlighting purposes.
class _FakeBuildContext extends Fake implements BuildContext {}
