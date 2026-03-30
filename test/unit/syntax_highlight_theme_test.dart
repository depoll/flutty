import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_theme.dart';

void main() {
  group('buildSyntaxThemeFromTerminal', () {
    const theme = TerminalThemeData(
      id: 'test',
      name: 'Test',
      isDark: true,
      foreground: Color(0xFFFFFFFF),
      background: Color(0xFF000000),
      cursor: Color(0xFFCCCCCC),
      selection: Color(0xFF444444),
      black: Color(0xFF000000),
      red: Color(0xFFFF0000),
      green: Color(0xFF00FF00),
      yellow: Color(0xFFFFFF00),
      blue: Color(0xFF0000FF),
      magenta: Color(0xFFFF00FF),
      cyan: Color(0xFF00FFFF),
      white: Color(0xFFFFFFFF),
      brightBlack: Color(0xFF808080),
      brightRed: Color(0xFFFF8080),
      brightGreen: Color(0xFF80FF80),
      brightYellow: Color(0xFFFFFF80),
      brightBlue: Color(0xFF8080FF),
      brightMagenta: Color(0xFFFF80FF),
      brightCyan: Color(0xFF80FFFF),
      brightWhite: Color(0xFFFFFFFF),
    );

    late Map<String, TextStyle> syntaxTheme;

    setUp(() {
      syntaxTheme = buildSyntaxThemeFromTerminal(theme);
    });

    test('root uses foreground and background', () {
      final root = syntaxTheme['root']!;
      expect(root.color, theme.foreground);
      expect(root.backgroundColor, theme.background);
    });

    test('keyword uses magenta', () {
      expect(syntaxTheme['keyword']!.color, theme.magenta);
    });

    test('string uses green', () {
      expect(syntaxTheme['string']!.color, theme.green);
    });

    test('number uses yellow', () {
      expect(syntaxTheme['number']!.color, theme.yellow);
    });

    test('type uses cyan', () {
      expect(syntaxTheme['type']!.color, theme.cyan);
    });

    test('title uses blue', () {
      expect(syntaxTheme['title']!.color, theme.blue);
    });

    test('comment uses brightBlack with italic', () {
      final comment = syntaxTheme['comment']!;
      expect(comment.color, theme.brightBlack);
      expect(comment.fontStyle, FontStyle.italic);
    });

    test('strong is bold', () {
      expect(syntaxTheme['strong']!.fontWeight, FontWeight.bold);
    });

    test('emphasis is italic', () {
      expect(syntaxTheme['emphasis']!.fontStyle, FontStyle.italic);
    });

    test('covers all standard highlight.js class names', () {
      const expectedKeys = [
        'root',
        'keyword',
        'selector-tag',
        'name',
        'string',
        'addition',
        'number',
        'literal',
        'bullet',
        'type',
        'built_in',
        'builtin-name',
        'selector-class',
        'selector-id',
        'title',
        'section',
        'symbol',
        'attribute',
        'attr',
        'variable',
        'template-variable',
        'selector-attr',
        'selector-pseudo',
        'comment',
        'deletion',
        'meta',
        'quote',
        'regexp',
        'link',
        'code',
        'tag',
        'subst',
        'params',
        'strong',
        'emphasis',
      ];
      for (final key in expectedKeys) {
        expect(syntaxTheme.containsKey(key), isTrue, reason: 'missing "$key"');
      }
    });
  });

  group('defaultDarkSyntaxTheme', () {
    test('has a root entry with dark background', () {
      final root = defaultDarkSyntaxTheme['root']!;
      expect(root.backgroundColor, isNotNull);
      expect(root.color, isNotNull);
    });

    test('has keyword entry', () {
      expect(defaultDarkSyntaxTheme['keyword'], isNotNull);
    });
  });

  group('defaultLightSyntaxTheme', () {
    test('has a root entry with light background', () {
      final root = defaultLightSyntaxTheme['root']!;
      expect(root.backgroundColor, isNotNull);
      expect(root.color, isNotNull);
    });

    test('has keyword entry', () {
      expect(defaultLightSyntaxTheme['keyword'], isNotNull);
    });
  });
}
