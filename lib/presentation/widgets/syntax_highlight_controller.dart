import 'package:flutter/widgets.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

/// Maximum text length (in characters) for which syntax highlighting is
/// applied.
///
/// Files larger than this threshold are rendered as plain text to avoid
/// frame-rate drops caused by the highlighting pass inside [buildTextSpan].
///
/// The SFTP screen gates on the raw byte length before creating the
/// controller; this character-based guard is a secondary safety net inside
/// [SyntaxHighlightController.buildTextSpan].
const syntaxHighlightSizeLimit = 100 * 1024; // 100 K characters

/// A [TextEditingController] that produces syntax-highlighted [TextSpan]s.
///
/// Uses the `highlight` package to tokenize the controller text and maps
/// highlight.js CSS class names to [TextStyle]s via the supplied [theme] map.
///
/// Highlighting is automatically skipped when the text exceeds
/// [syntaxHighlightSizeLimit] characters.
class SyntaxHighlightController extends TextEditingController {
  /// Creates a [SyntaxHighlightController].
  ///
  /// [theme] maps highlight.js class names (e.g. `'keyword'`, `'string'`) to
  /// [TextStyle]s.  The special `'root'` key provides the base text style.
  ///
  /// [language] is the highlight.js language identifier (e.g. `'dart'`).
  /// When `null`, `highlight.parse` attempts auto-detection.
  SyntaxHighlightController({required this.theme, super.text, this.language});

  /// The highlight.js language name, or `null` for auto-detection.
  String? language;

  /// Highlight.js theme map (class name → [TextStyle]).
  Map<String, TextStyle> theme;

  // Cached spans keyed on the raw text value so we only re-highlight on edits.
  String? _cachedText;
  TextSpan? _cachedSpan;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    // ignore: always_put_required_named_parameters_first
    required bool withComposing,
  }) {
    final source = text;

    // During active IME composing, fall back to the default controller so
    // the composing underline decoration is preserved.
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    // Skip highlighting for empty or oversized text.
    if (source.isEmpty || source.length > syntaxHighlightSizeLimit) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    // Return cached result when the text has not changed.
    if (source == _cachedText && _cachedSpan != null) {
      return TextSpan(style: style, children: [_cachedSpan!]);
    }

    try {
      final result = highlight.parse(source, language: language);
      final nodes = result.nodes;
      if (nodes == null || nodes.isEmpty) {
        return super.buildTextSpan(
          context: context,
          style: style,
          withComposing: withComposing,
        );
      }

      final highlighted = TextSpan(
        style: style,
        children: _convertNodes(nodes),
      );

      _cachedText = source;
      _cachedSpan = highlighted;
      return highlighted;
    } on Object {
      // If the highlighter fails for any reason, fall through to plain text.
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
  }

  /// Recursively converts highlight.js [Node]s into [TextSpan] children.
  List<TextSpan> _convertNodes(List<Node> nodes) {
    final spans = <TextSpan>[];
    for (final node in nodes) {
      if (node.value != null) {
        spans.add(
          TextSpan(
            text: node.value,
            style: node.className != null ? theme[node.className!] : null,
          ),
        );
      } else if (node.children != null) {
        spans.add(
          TextSpan(
            style: node.className != null ? theme[node.className!] : null,
            children: _convertNodes(node.children!),
          ),
        );
      }
    }
    return spans;
  }

  /// Invalidates the internal cache, forcing the next [buildTextSpan] call to
  /// re-highlight from scratch.
  void invalidateHighlightCache() {
    _cachedText = null;
    _cachedSpan = null;
  }
}
