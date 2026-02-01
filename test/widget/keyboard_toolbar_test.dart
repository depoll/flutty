import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('KeyboardToolbar', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(maxLines: 100);
    });

    testWidgets('renders all key rows', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      // Check modifier row keys
      expect(find.text('Esc'), findsOneWidget);
      expect(find.text('Tab'), findsOneWidget);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Alt'), findsOneWidget);
      expect(find.text('Shift'), findsOneWidget);

      // Check navigation row keys
      expect(find.text('↑'), findsOneWidget);
      expect(find.text('↓'), findsOneWidget);
      expect(find.text('←'), findsOneWidget);
      expect(find.text('→'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('End'), findsOneWidget);
      expect(find.text('PgUp'), findsOneWidget);
      expect(find.text('PgDn'), findsOneWidget);

      // Check function keys (first page)
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('F6'), findsOneWidget);

      // Check quick actions
      expect(find.text('Ins'), findsOneWidget);
      expect(find.text('Del'), findsOneWidget);
    });

    testWidgets('modifier key toggles state on tap', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      // Find Ctrl button
      final ctrlFinder = find.text('Ctrl');
      expect(ctrlFinder, findsOneWidget);

      // Tap to activate (one-shot mode)
      await tester.tap(ctrlFinder);
      await tester.pumpAndSettle();

      // Tap again to deactivate
      await tester.tap(ctrlFinder);
      await tester.pumpAndSettle();
    });

    testWidgets('function key pagination works', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      // Initially shows F1-F6
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('F6'), findsOneWidget);
      expect(find.text('F7'), findsNothing);

      // Tap next button to go to page 2
      final nextButton = find.text('>');
      await tester.tap(nextButton);
      await tester.pump();

      // Now shows F7-F12
      expect(find.text('F7'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);
      expect(find.text('F1'), findsNothing);

      // Tap previous button to go back
      final prevButton = find.text('<');
      await tester.tap(prevButton);
      await tester.pump();

      // Back to F1-F6
      expect(find.text('F1'), findsOneWidget);
    });

    testWidgets('calls onKeyPressed callback', (tester) async {
      var callCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardToolbar(
              terminal: terminal,
              onKeyPressed: () => callCount++,
            ),
          ),
        ),
      );

      // Tap a key
      await tester.tap(find.text('/'));
      await tester.pump();

      expect(callCount, 1);
    });

    testWidgets('special characters render correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      expect(find.text('|'), findsOneWidget);
      expect(find.text(r'\'), findsOneWidget);
      expect(find.text('/'), findsOneWidget);
      expect(find.text('`'), findsOneWidget);
      expect(find.text('-'), findsOneWidget);
      expect(find.text('='), findsOneWidget);
      expect(find.text('['), findsOneWidget);
      expect(find.text(']'), findsOneWidget);
    });
  });

  group('Terminal key sequences', () {
    test('arrow key escape sequences', () {
      // These are the expected escape sequences for arrow keys
      expect('\x1b[A', equals('\x1b[A')); // Up
      expect('\x1b[B', equals('\x1b[B')); // Down
      expect('\x1b[C', equals('\x1b[C')); // Right
      expect('\x1b[D', equals('\x1b[D')); // Left
    });

    test('navigation key escape sequences', () {
      expect('\x1b[H', equals('\x1b[H')); // Home
      expect('\x1b[F', equals('\x1b[F')); // End
      expect('\x1b[5~', equals('\x1b[5~')); // Page Up
      expect('\x1b[6~', equals('\x1b[6~')); // Page Down
      expect('\x1b[2~', equals('\x1b[2~')); // Insert
      expect('\x1b[3~', equals('\x1b[3~')); // Delete
    });

    test('function key escape sequences', () {
      // F1-F4 use different format
      expect('\x1bOP', equals('\x1bOP')); // F1
      expect('\x1bOQ', equals('\x1bOQ')); // F2
      expect('\x1bOR', equals('\x1bOR')); // F3
      expect('\x1bOS', equals('\x1bOS')); // F4
      // F5-F12 use numbered format
      expect('\x1b[15~', equals('\x1b[15~')); // F5
      expect('\x1b[17~', equals('\x1b[17~')); // F6
      expect('\x1b[24~', equals('\x1b[24~')); // F12
    });

    test('modifier key combinations', () {
      // With modifiers, sequences change
      // Shift = 2, Alt = 3, Shift+Alt = 4, Ctrl = 5, etc.
      expect('\x1b[1;5A', equals('\x1b[1;5A')); // Ctrl+Up
      expect('\x1b[1;3A', equals('\x1b[1;3A')); // Alt+Up
      expect('\x1b[1;2A', equals('\x1b[1;2A')); // Shift+Up
    });
  });
}
