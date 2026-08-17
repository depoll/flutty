import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:monkeyssh/presentation/widgets/terminal_menu_style.dart';
import 'package:xterm/xterm.dart';

const _terminalShiftEnterNewlineInput = '\n';

String _terminalKeyOutput(
  TerminalKey key, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  final output = <String>[];
  Terminal(
    onOutput: output.add,
  ).keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
  return output.join();
}

void main() {
  test('resolveTerminalTabInput returns plain tab by default', () {
    expect(resolveTerminalTabInput(shiftActive: false), '\t');
  });

  test('resolveTerminalTabInput returns reverse-tab when shift is active', () {
    expect(resolveTerminalTabInput(shiftActive: true), '\x1b[Z');
  });

  test('uses a single toolbar row in landscape', () {
    const mediaQuery = MediaQueryData(size: Size(844, 390));

    expect(shouldUseSingleRowKeyboardToolbar(mediaQuery), isTrue);
    expect(resolveKeyboardToolbarHeight(mediaQuery), 42);
  });

  test('uses two toolbar rows in portrait', () {
    const mediaQuery = MediaQueryData(
      size: Size(390, 844),
      padding: EdgeInsets.only(bottom: 34),
    );

    expect(shouldUseSingleRowKeyboardToolbar(mediaQuery), isFalse);
    expect(resolveKeyboardToolbarHeight(mediaQuery), 118);
  });

  group('KeyboardToolbar', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(maxLines: 100);
    });

    testWidgets('keeps Paste and Enter on the right edge of their rows', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      const topRowOrder = [
        'Escape',
        'Tab',
        'Ctrl',
        'Alt',
        'Shift',
        'Pipe',
        'Slash',
        'Tilde',
        'Paste',
      ];
      const bottomRowOrder = [
        'Left',
        'Right',
        'Up',
        'Down',
        'Page Up',
        'Page Down',
        'Home',
        'End',
        'Enter',
      ];

      final topRowCenters = <String, Offset>{
        for (final label in topRowOrder)
          label: tester.getCenter(find.byTooltip(label)),
      };
      final bottomRowCenters = <String, Offset>{
        for (final label in bottomRowOrder)
          label: tester.getCenter(find.byTooltip(label)),
      };
      final actualTopRowOrder = topRowOrder.toList()
        ..sort((a, b) => topRowCenters[a]!.dx.compareTo(topRowCenters[b]!.dx));
      final actualBottomRowOrder = bottomRowOrder.toList()
        ..sort(
          (a, b) => bottomRowCenters[a]!.dx.compareTo(bottomRowCenters[b]!.dx),
        );

      expect(actualTopRowOrder, topRowOrder);
      expect(actualBottomRowOrder, bottomRowOrder);
      expect(topRowCenters['Paste']!.dy, topRowCenters['Escape']!.dy);
      expect(bottomRowCenters['Enter']!.dy, bottomRowCenters['Left']!.dy);
      expect(
        bottomRowCenters['Enter']!.dy,
        greaterThan(topRowCenters['Paste']!.dy),
      );
    });

    testWidgets('keeps arrow keys to the left of PgUp/PgDn/Home/End/Enter', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      const expectedOrder = [
        'Left',
        'Right',
        'Up',
        'Down',
        'Page Up',
        'Page Down',
        'Home',
        'End',
        'Enter',
      ];
      final positions = <String, double>{
        for (final label in expectedOrder)
          label: tester.getCenter(find.byTooltip(label)).dx,
      };
      final actualOrder = expectedOrder.toList()
        ..sort((a, b) => positions[a]!.compareTo(positions[b]!));

      expect(actualOrder, expectedOrder);
    });

    testWidgets('renders a single landscape row for extra keys', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(844, 390)),
            child: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        ),
      );

      final escapeCenter = tester.getCenter(find.byTooltip('Escape'));
      final upCenter = tester.getCenter(find.byTooltip('Up'));
      final endCenter = tester.getCenter(find.byTooltip('End'));

      expect((escapeCenter.dy - upCenter.dy).abs(), lessThan(0.1));
      expect((escapeCenter.dy - endCenter.dy).abs(), lessThan(0.1));
    });

    testWidgets('keeps the landscape Enter key fully on screen', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(844, 390)),
            child: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        ),
      );

      final enterRight = tester.getTopRight(find.byTooltip('Enter')).dx;

      expect(enterRight, lessThanOrEqualTo(844.001));
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

    testWidgets('modifier taps call onKeyPressed to reset IME context', (
      tester,
    ) async {
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

      await tester.tap(find.byTooltip('Ctrl'));
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
      expect(find.text('~'), findsOneWidget);
    });

    testWidgets('Tilde button sends a tilde character', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      await tester.tap(find.byTooltip('Tilde'));
      await tester.pump();

      expect(output, contains('~'));
    });

    testWidgets('Paste button invokes clipboard paste callback on tap', (
      tester,
    ) async {
      var pasteCount = 0;
      var keyPressedCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardToolbar(
              terminal: terminal,
              onKeyPressed: () => keyPressedCount++,
              onPasteRequested: () async => pasteCount++,
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Paste'));
      await tester.pump();

      expect(pasteCount, 1);
      expect(keyPressedCount, 1);
    });

    testWidgets('Paste button shows an ellipsis long-press options indicator', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      expect(
        find.descendant(
          of: find.byTooltip('Paste'),
          matching: find.byIcon(Icons.more_horiz_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Paste long press opens an anchored drag-release menu', (
      tester,
    ) async {
      var mediaPasteCount = 0;
      var filePasteCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                KeyboardToolbar(
                  terminal: terminal,
                  onPasteMediaRequested: () async => mediaPasteCount++,
                  onPasteFilesRequested: () async => filePasteCount++,
                ),
              ],
            ),
          ),
        ),
      );

      final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
      final gesture = await tester.startGesture(pasteCenter);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.text('Paste Media'), findsOneWidget);
      expect(find.text('Paste Files'), findsOneWidget);
      expect(
        tester.getCenter(find.text('Paste Media')).dy,
        lessThan(pasteCenter.dy),
      );

      await gesture.moveTo(tester.getCenter(find.text('Paste Media')));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(mediaPasteCount, 1);
      expect(filePasteCount, 0);
      expect(find.text('Paste Media'), findsNothing);
      expect(find.text('Paste Files'), findsNothing);
    });

    testWidgets('Paste long press uses terminal menu styling', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                KeyboardToolbar(
                  terminal: terminal,
                  onPasteMediaRequested: () async {},
                  onPasteFilesRequested: () async {},
                ),
              ],
            ),
          ),
        ),
      );

      final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
      final gesture = await tester.startGesture(pasteCenter);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump();

      final pasteMedia = find.text('Paste Media');
      final menuMaterial = tester.widget<Material>(
        find.ancestor(of: pasteMedia, matching: find.byType(Material)).first,
      );
      final menuContext = tester.element(pasteMedia);

      expect(menuMaterial.color, TerminalMenuStyles.surfaceColor(menuContext));
      expect(menuMaterial.elevation, TerminalMenuStyles.elevation);
      expect(
        menuMaterial.shape,
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TerminalMenuStyles.borderRadius),
        ),
      );
      expect(find.byType(Divider), findsNothing);

      await gesture.cancel();
      await tester.pump();
    });

    testWidgets('Paste long press releases over a top-level snippet', (
      tester,
    ) async {
      KeyboardToolbarSnippet? selectedSnippet;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                KeyboardToolbar(
                  terminal: terminal,
                  snippets: const [
                    KeyboardToolbarSnippet(
                      id: 1,
                      name: 'Top level',
                      command: 'git status',
                    ),
                  ],
                  onSnippetPasteRequested: (snippet) async {
                    selectedSnippet = snippet;
                  },
                ),
              ],
            ),
          ),
        ),
      );

      final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
      final gesture = await tester.startGesture(pasteCenter);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);

      await gesture.moveTo(tester.getCenter(find.text('Snippets')));
      await tester.pump();

      expect(find.text('Top level'), findsOneWidget);

      await gesture.moveTo(tester.getCenter(find.text('Top level')));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(selectedSnippet?.id, 1);
      expect(selectedSnippet?.command, 'git status');
      expect(find.text('Top level'), findsNothing);
    });

    testWidgets('Paste long press releases over a folder snippet', (
      tester,
    ) async {
      KeyboardToolbarSnippet? selectedSnippet;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                KeyboardToolbar(
                  terminal: terminal,
                  snippetFolders: const [
                    KeyboardToolbarSnippetFolder(id: 7, name: 'Deploy'),
                  ],
                  snippets: const [
                    KeyboardToolbarSnippet(
                      id: 2,
                      name: 'Restart API',
                      command: 'systemctl restart api',
                      folderId: 7,
                    ),
                  ],
                  onSnippetPasteRequested: (snippet) async {
                    selectedSnippet = snippet;
                  },
                ),
              ],
            ),
          ),
        ),
      );

      final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
      final gesture = await tester.startGesture(pasteCenter);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump();

      await gesture.moveTo(tester.getCenter(find.text('Snippets')));
      await tester.pump();

      expect(find.text('Deploy'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Deploy')).dx,
        lessThan(tester.getTopLeft(find.text('Snippets')).dx),
      );

      await gesture.moveTo(tester.getCenter(find.text('Deploy')));
      await tester.pump();

      expect(find.text('Restart API'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Restart API')).dx,
        lessThan(tester.getTopLeft(find.text('Snippets')).dx),
      );
      expect(
        tester.getTopLeft(find.text('Restart API')).dy,
        greaterThan(tester.getTopLeft(find.text('Deploy')).dy),
      );

      await gesture.moveTo(tester.getCenter(find.text('Restart API')));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(selectedSnippet?.id, 2);
      expect(selectedSnippet?.command, 'systemctl restart api');
      expect(find.text('Restart API'), findsNothing);
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
      expect(output, contains(_terminalKeyOutput(TerminalKey.enter)));
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

    testWidgets('toolbar Escape and Tab use Kitty encoding when enabled', (
      tester,
    ) async {
      final output = <String>[];
      terminal
        ..onOutput = output.add
        ..write('\x1b[>31u');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      await tester.tap(find.byTooltip('Escape'));
      await tester.pump();
      await tester.tap(find.byTooltip('Tab'));
      await tester.pump();
      await tester.tap(find.byTooltip('Shift'));
      await tester.pump();
      await tester.tap(find.byTooltip('Tab'));
      await tester.pump();

      expect(output, contains('\x1b[27u'));
      expect(output, contains('\x1b[9u'));
      expect(output, contains('\x1b[9;2u'));

      await tester.pump(const Duration(milliseconds: 120));
    });

    testWidgets('toolbar Shift applies to Enter', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      await tester.tap(find.byTooltip('Shift'));
      await tester.pump();
      await tester.tap(find.byTooltip('Enter'));
      await tester.pump();

      expect(output, contains(_terminalShiftEnterNewlineInput));
    });

    testWidgets('toolbar Alt+Enter sends meta-sends-escape CR', (tester) async {
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      await tester.tap(find.byTooltip('Alt'));
      await tester.pump();
      await tester.tap(find.byTooltip('Enter'));
      await tester.pump();

      expect(output, contains('\x1b\r'));
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

    testWidgets('arrow holds avoid Kitty event types in raw terminals', (
      tester,
    ) async {
      final output = <String>[];
      terminal
        ..onOutput = output.add
        ..write('\x1b[>31u');

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
      expect(output.where((value) => value.contains(':2')), isEmpty);
    });

    testWidgets(
      'toolbar presses keep legacy sequences without Kitty key flags',
      (tester) async {
        final output = <String>[];
        terminal
          ..onOutput = output.add
          ..write('\x1b[=2u');

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        await tester.tap(find.byTooltip('Shift'));
        await tester.pump();
        await tester.tap(find.byTooltip('Up'));
        await tester.pump();

        expect(output, contains('\x1b[1;2A'));
        expect(output, isNot(contains('scrollLineUp')));
      },
    );

    testWidgets('series navigation holds avoid Kitty event types', (
      tester,
    ) async {
      final output = <String>[];
      terminal
        ..onOutput = output.add
        ..write('\x1b[>31u');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Page Up')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 160));
      await gesture.up();
      await tester.pump();

      expect(
        output.where((value) => value == '\x1b[5~').length,
        greaterThan(1),
      );
      expect(output.where((value) => value.contains(':2')), isEmpty);
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
