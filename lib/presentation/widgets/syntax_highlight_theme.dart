import 'package:flutter/painting.dart';

import '../../domain/models/terminal_theme.dart';

Color _syntaxMutedColor(TerminalThemeData theme) =>
    theme.isDark ? theme.brightBlack : theme.white;

/// Builds a highlight.js–compatible `Map<String, TextStyle>` theme from a
/// [TerminalThemeData] so that syntax colors stay visually consistent with
/// the user's chosen terminal palette.
///
/// The map keys correspond to highlight.js CSS class names (e.g. `keyword`,
/// `string`, `comment`).  The special `root` key carries the base foreground
/// and background colours.
Map<String, TextStyle> buildSyntaxThemeFromTerminal(
  TerminalThemeData theme,
) => <String, TextStyle>{
  'root': TextStyle(color: theme.foreground, backgroundColor: theme.background),

  // Keywords, control flow, operators
  'keyword': TextStyle(color: theme.magenta),
  'selector-tag': TextStyle(color: theme.magenta),
  'name': TextStyle(color: theme.magenta),

  // Strings and string-like literals
  'string': TextStyle(color: theme.green),
  'addition': TextStyle(color: theme.green),

  // Numbers, booleans, literals
  'number': TextStyle(color: theme.yellow),
  'literal': TextStyle(color: theme.yellow),
  'bullet': TextStyle(color: theme.yellow),

  // Types, classes, built-ins
  'type': TextStyle(color: theme.cyan),
  'built_in': TextStyle(color: theme.cyan),
  'builtin-name': TextStyle(color: theme.cyan),
  'selector-class': TextStyle(color: theme.cyan),
  'selector-id': TextStyle(color: theme.cyan),

  // Function / method titles
  'title': TextStyle(color: theme.blue),
  'section': TextStyle(color: theme.blue),

  // Symbols, attributes
  'symbol': TextStyle(color: theme.brightCyan),
  'attribute': TextStyle(color: theme.brightCyan),
  'attr': TextStyle(color: theme.red),

  // Variables, template interpolation
  'variable': TextStyle(color: theme.brightRed),
  'template-variable': TextStyle(color: theme.brightRed),
  'selector-attr': TextStyle(color: theme.brightRed),
  'selector-pseudo': TextStyle(color: theme.brightRed),

  // Comments, deletions, meta
  'comment': TextStyle(
    color: _syntaxMutedColor(theme),
    fontStyle: FontStyle.italic,
  ),
  'deletion': TextStyle(color: _syntaxMutedColor(theme)),
  'meta': TextStyle(color: _syntaxMutedColor(theme)),
  'quote': TextStyle(
    color: _syntaxMutedColor(theme),
    fontStyle: FontStyle.italic,
  ),

  // Regex, links
  'regexp': TextStyle(color: theme.brightGreen),
  'link': TextStyle(color: theme.brightBlue),
  'code': TextStyle(color: theme.brightGreen),

  // Tags (HTML/XML)
  'tag': TextStyle(color: theme.foreground),
  'subst': TextStyle(color: theme.foreground),
  'params': TextStyle(color: theme.foreground),

  // Emphasis / strong
  'strong': const TextStyle(fontWeight: FontWeight.bold),
  'emphasis': const TextStyle(fontStyle: FontStyle.italic),
};

/// Provides a sensible dark-background fallback syntax theme.
///
/// Used when no [TerminalThemeData] is available.
Map<String, TextStyle> get defaultDarkSyntaxTheme => const <String, TextStyle>{
  'root': TextStyle(
    color: Color(0xFFD4D4D4),
    backgroundColor: Color(0xFF1E1E1E),
  ),
  'keyword': TextStyle(color: Color(0xFFC586C0)),
  'selector-tag': TextStyle(color: Color(0xFFC586C0)),
  'name': TextStyle(color: Color(0xFFC586C0)),
  'string': TextStyle(color: Color(0xFFCE9178)),
  'addition': TextStyle(color: Color(0xFFCE9178)),
  'number': TextStyle(color: Color(0xFFB5CEA8)),
  'literal': TextStyle(color: Color(0xFFB5CEA8)),
  'bullet': TextStyle(color: Color(0xFFB5CEA8)),
  'type': TextStyle(color: Color(0xFF4EC9B0)),
  'built_in': TextStyle(color: Color(0xFF4EC9B0)),
  'builtin-name': TextStyle(color: Color(0xFF4EC9B0)),
  'selector-class': TextStyle(color: Color(0xFF4EC9B0)),
  'selector-id': TextStyle(color: Color(0xFF4EC9B0)),
  'title': TextStyle(color: Color(0xFFDCDCAA)),
  'section': TextStyle(color: Color(0xFFDCDCAA)),
  'symbol': TextStyle(color: Color(0xFF4FC1FF)),
  'attribute': TextStyle(color: Color(0xFF4FC1FF)),
  'attr': TextStyle(color: Color(0xFF9CDCFE)),
  'variable': TextStyle(color: Color(0xFF9CDCFE)),
  'template-variable': TextStyle(color: Color(0xFF9CDCFE)),
  'selector-attr': TextStyle(color: Color(0xFF9CDCFE)),
  'selector-pseudo': TextStyle(color: Color(0xFF9CDCFE)),
  'comment': TextStyle(color: Color(0xFF6A9955), fontStyle: FontStyle.italic),
  'deletion': TextStyle(color: Color(0xFF6A9955)),
  'meta': TextStyle(color: Color(0xFF6A9955)),
  'quote': TextStyle(color: Color(0xFF6A9955), fontStyle: FontStyle.italic),
  'regexp': TextStyle(color: Color(0xFFD16969)),
  'link': TextStyle(color: Color(0xFF4FC1FF)),
  'code': TextStyle(color: Color(0xFFD16969)),
  'tag': TextStyle(color: Color(0xFFD4D4D4)),
  'subst': TextStyle(color: Color(0xFFD4D4D4)),
  'params': TextStyle(color: Color(0xFFD4D4D4)),
  'strong': TextStyle(fontWeight: FontWeight.bold),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
};

/// Provides a sensible light-background fallback syntax theme.
///
/// Used when no [TerminalThemeData] is available and the platform brightness
/// is light.
Map<String, TextStyle> get defaultLightSyntaxTheme => const <String, TextStyle>{
  'root': TextStyle(
    color: Color(0xFF000000),
    backgroundColor: Color(0xFFFFFFFF),
  ),
  'keyword': TextStyle(color: Color(0xFFAF00DB)),
  'selector-tag': TextStyle(color: Color(0xFFAF00DB)),
  'name': TextStyle(color: Color(0xFFAF00DB)),
  'string': TextStyle(color: Color(0xFFA31515)),
  'addition': TextStyle(color: Color(0xFFA31515)),
  'number': TextStyle(color: Color(0xFF098658)),
  'literal': TextStyle(color: Color(0xFF098658)),
  'bullet': TextStyle(color: Color(0xFF098658)),
  'type': TextStyle(color: Color(0xFF267F99)),
  'built_in': TextStyle(color: Color(0xFF267F99)),
  'builtin-name': TextStyle(color: Color(0xFF267F99)),
  'selector-class': TextStyle(color: Color(0xFF267F99)),
  'selector-id': TextStyle(color: Color(0xFF267F99)),
  'title': TextStyle(color: Color(0xFF795E26)),
  'section': TextStyle(color: Color(0xFF795E26)),
  'symbol': TextStyle(color: Color(0xFF0070C1)),
  'attribute': TextStyle(color: Color(0xFF0070C1)),
  'attr': TextStyle(color: Color(0xFF001080)),
  'variable': TextStyle(color: Color(0xFF001080)),
  'template-variable': TextStyle(color: Color(0xFF001080)),
  'selector-attr': TextStyle(color: Color(0xFF001080)),
  'selector-pseudo': TextStyle(color: Color(0xFF001080)),
  'comment': TextStyle(color: Color(0xFF008000), fontStyle: FontStyle.italic),
  'deletion': TextStyle(color: Color(0xFF008000)),
  'meta': TextStyle(color: Color(0xFF008000)),
  'quote': TextStyle(color: Color(0xFF008000), fontStyle: FontStyle.italic),
  'regexp': TextStyle(color: Color(0xFF811F3F)),
  'link': TextStyle(color: Color(0xFF0070C1)),
  'code': TextStyle(color: Color(0xFF811F3F)),
  'tag': TextStyle(color: Color(0xFF000000)),
  'subst': TextStyle(color: Color(0xFF000000)),
  'params': TextStyle(color: Color(0xFF000000)),
  'strong': TextStyle(fontWeight: FontWeight.bold),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
};
