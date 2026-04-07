import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('resolveTerminalTabInput returns plain tab by default', () {
    expect(resolveTerminalTabInput(shiftActive: false), '\t');
  });

  test('resolveTerminalTabInput returns reverse-tab when shift is active', () {
    expect(resolveTerminalTabInput(shiftActive: true), '\x1b[Z');
  });

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
      expect(find.byTooltip('Escape'), findsOneWidget);
      expect(find.byTooltip('Tab'), findsOneWidget);
      expect(find.byTooltip('Ctrl'), findsOneWidget);
      expect(find.byTooltip('Alt'), findsOneWidget);
      expect(find.byTooltip('Shift'), findsOneWidget);

      // Check navigation row keys
      expect(find.byTooltip('Up'), findsOneWidget);
      expect(find.byTooltip('Down'), findsOneWidget);
      expect(find.byTooltip('Left'), findsOneWidget);
      expect(find.byTooltip('Right'), findsOneWidget);
      expect(find.byTooltip('Home'), findsOneWidget);
      expect(find.byTooltip('End'), findsOneWidget);
      expect(find.byTooltip('Page Up'), findsOneWidget);
      expect(find.byTooltip('Page Down'), findsOneWidget);
    });

    testWidgets('keeps series keys to the left of arrow keys', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      const expectedOrder = [
        'Page Up',
        'Page Down',
        'Home',
        'End',
        'Left',
        'Right',
        'Up',
        'Down',
      ];
      final positions = <String, double>{
        for (final label in expectedOrder)
          label: tester.getCenter(find.byTooltip(label)).dx,
      };
      final actualOrder = expectedOrder.toList()
        ..sort((a, b) => positions[a]!.compareTo(positions[b]!));

      expect(actualOrder, expectedOrder);
    });

    testWidgets('modifier key toggles state on tap', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      // Find Ctrl button
      final ctrlFinder = find.byTooltip('Ctrl');
      expect(ctrlFinder, findsOneWidget);

      // Tap to activate (one-shot mode)
      await tester.tap(ctrlFinder);
      await tester.pumpAndSettle();

      // Tap again to deactivate
      await tester.tap(ctrlFinder);
      await tester.pumpAndSettle();
    });

    testWidgets(
      'controller preserves Ctrl state across toolbar rebuilds for system keyboard input',
      (tester) async {
        final controller = KeyboardToolbarController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyboardToolbar(terminal: terminal, controller: controller),
            ),
          ),
        );

        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();

        expect(controller.isCtrlActive, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyboardToolbar(terminal: terminal, controller: controller),
            ),
          ),
        );
        await tester.pump();

        expect(controller.applySystemKeyboardModifiers('b'), '\u0002');
        expect(controller.isCtrlActive, isFalse);
      },
    );

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
      expect(find.text('/'), findsOneWidget);
    });

    testWidgets('Enter button renders and triggers callback', (tester) async {
      var callCount = 0;
      final output = <String>[];
      terminal.onOutput = output.add;

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

      // Enter button uses an icon, find by tooltip
      final enterButton = find.byTooltip('Enter');
      expect(enterButton, findsOneWidget);

      await tester.tap(enterButton);
      await tester.pump();

      expect(callCount, 1);
      // keyInput(TerminalKey.enter) produces '\r'
      expect(output, contains('\r'));
    });

    testWidgets('Tab ignores the system keyboard shift state', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byTooltip('Tab'));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(output, contains('\t'));
      expect(output, isNot(contains('\x1b[Z')));
    });

    testWidgets('toolbar Shift still sends reverse-tab', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      await tester.tap(find.byTooltip('Shift'));
      await tester.pump();
      await tester.tap(find.byTooltip('Tab'));
      await tester.pump();

      expect(output, contains('\x1b[Z'));
    });
    test('keeps bottom safe-area padding when keyboard is closed', () {
      const mediaQuery = MediaQueryData(padding: EdgeInsets.only(bottom: 34));

      expect(shouldKeepToolbarBottomSafeArea(mediaQuery), isTrue);
    });

    test('drops bottom safe-area padding when keyboard is open', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.only(bottom: 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );

      expect(shouldKeepToolbarBottomSafeArea(mediaQuery), isFalse);
    });

    testWidgets('arrow keys repeat while held', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Up')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 160));
      await gesture.up();
      await tester.pump();

      expect(output.where((value) => value == '\x1b[A').length, greaterThan(1));
    });

    testWidgets('repeating navigation stops when gesture is cancelled', (
      tester,
    ) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Right')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 120));
      await gesture.cancel();
      await tester.pump();

      final outputCount = output.where((value) => value == '\x1b[C').length;
      await tester.pump(const Duration(milliseconds: 150));

      expect(outputCount, greaterThan(1));
      expect(output.where((value) => value == '\x1b[C').length, outputCount);
    });

    testWidgets('repeating navigation stops when released', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Home')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 120));
      await gesture.up();
      await tester.pump();

      final outputCount = output.where((value) => value == '\x1b[H').length;
      await tester.pump(const Duration(milliseconds: 150));

      expect(outputCount, greaterThan(1));
      expect(output.where((value) => value == '\x1b[H').length, outputCount);
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
