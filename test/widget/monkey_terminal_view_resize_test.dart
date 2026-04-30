// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = luminanceA > luminanceB ? luminanceA : luminanceB;
  final darkest = luminanceA > luminanceB ? luminanceB : luminanceA;
  return (brightest + 0.05) / (darkest + 0.05);
}

void main() {
  Widget buildTerminal({
    required Terminal terminal,
    required Size size,
    Key? terminalKey,
    double keyboardInset = 0,
    FocusNode? focusNode,
    bool readOnly = true,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
      ),
      child: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MonkeyTerminalView(
            key: terminalKey,
            terminal,
            focusNode: focusNode,
            hardwareKeyboardOnly: true,
            readOnly: readOnly,
          ),
        ),
      ),
    ),
  );

  testWidgets('auto resize reports total viewport pixels', (tester) async {
    final terminal = Terminal();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    expect(resizeEvents, isNotEmpty);
    final event = resizeEvents.last;
    expect(event.width, greaterThan(0));
    expect(event.height, greaterThan(0));
    expect(event.pixelWidth, 320);
    expect(event.pixelHeight, 240);
  });

  testWidgets('size refresh re-sends the current viewport dimensions', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    expect(resizeEvents, isNotEmpty);
    final initialEvent = resizeEvents.last;
    final initialCount = resizeEvents.length;

    terminalKey.currentState!.refreshTerminalSize();

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last, initialEvent);
  });

  testWidgets('same-size refresh preserves terminal scroll margins', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    expect(resizeEvents, isNotEmpty);
    final initialCount = resizeEvents.length;
    terminal.setMargins(1, 2);
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);

    terminalKey.currentState!.refreshTerminalSize();

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);
  });

  testWidgets('pixel-only resize preserves terminal scroll margins', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    final renderTerminal = terminalKey.currentState!.renderTerminal;
    final cellSize = renderTerminal.cellSize;
    final columns = terminal.viewWidth;
    final rows = terminal.viewHeight;
    final nextSize = Size(
      (columns * cellSize.width) + (cellSize.width * 0.5),
      (rows * cellSize.height) + (cellSize.height * 0.5),
    );
    final initialCount = resizeEvents.length;

    terminal.setMargins(1, 2);
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: nextSize,
      ),
    );

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last.width, columns);
    expect(resizeEvents.last.height, rows);
    expect(resizeEvents.last.pixelWidth, nextSize.width.round());
    expect(resizeEvents.last.pixelHeight, nextSize.height.round());
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);
  });

  testWidgets('keyboard inset changes debounce before the final resize', (
    tester,
  ) async {
    final terminal = Terminal();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 400)),
    );

    expect(resizeEvents, isNotEmpty);
    final initialEvent = resizeEvents.last;
    final initialCount = resizeEvents.length;

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        size: const Size(320, 240),
        keyboardInset: 160,
      ),
    );

    expect(resizeEvents, hasLength(initialCount));
    expect(terminal.viewWidth, initialEvent.width);
    expect(terminal.viewHeight, initialEvent.height);

    await tester.pump(terminalKeyboardResizeDebounceDuration);

    expect(resizeEvents, hasLength(initialCount + 1));
    final keyboardShownEvent = resizeEvents.last;
    expect(keyboardShownEvent.width, initialEvent.width);
    expect(keyboardShownEvent.height, lessThan(initialEvent.height));
    expect(keyboardShownEvent.pixelWidth, 320);
    expect(keyboardShownEvent.pixelHeight, 240);

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 400)),
    );

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last, keyboardShownEvent);

    await tester.pump(terminalKeyboardResizeDebounceDuration);

    expect(resizeEvents, hasLength(initialCount + 2));
    expect(resizeEvents.last.width, initialEvent.width);
    expect(resizeEvents.last.height, initialEvent.height);
    expect(resizeEvents.last.pixelWidth, initialEvent.pixelWidth);
    expect(resizeEvents.last.pixelHeight, initialEvent.pixelHeight);
  });

  testWidgets('emits focus reports when focus reporting mode is enabled', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()
      ..write('\x1b[?1004h')
      ..onOutput = output.add;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        size: const Size(320, 240),
        focusNode: focusNode,
        readOnly: false,
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    expect(output, contains('\x1b[I'));

    focusNode.unfocus();
    await tester.pump();

    expect(output, contains('\x1b[O'));
  });

  testWidgets('refreshFocusReport resends focus gained when requested', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()
      ..write('\x1b[?1004h')
      ..onOutput = output.add;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        size: const Size(320, 240),
        focusNode: focusNode,
        readOnly: false,
      ),
    );

    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport();

    expect(output, ['\x1b[I']);

    output.clear();
    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport(forceTransition: true);

    expect(output, ['\x1b[O\x1b[I']);

    terminal.write('\x1b[?1004l');
    output.clear();
    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport();

    expect(output, isEmpty);
  });

  testWidgets('refreshThemeModeReport sends xterm theme mode report', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    final terminalViewState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );

    for (final isDark in [true, false]) {
      terminalViewState.refreshThemeModeReport(isDark: isDark);
    }

    expect(output, ['\x1b[?997;1n', '\x1b[?997;2n']);
  });

  testWidgets('refreshThemeColorReports sends full theme color refresh', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshThemeColorReports(
          monkey_themes.TerminalThemes.defaultLightTheme,
        );

    expect(output, [isNotEmpty]);
    expect(output.single, contains('\x1b]10;rgb:1f1f/2323/2828\x1b\\'));
    expect(output.single, contains('\x1b]11;rgb:ffff/ffff/ffff\x1b\\'));
    expect(output.single, contains('\x1b]12;rgb:0909/6969/dada\x1b\\'));
    expect(output.single, contains('\x1b]17;rgb:1f1f/2323/2828\x1b\\'));
    expect(output.single, contains('\x1b]19;rgb:1f1f/2323/2828\x1b\\'));
    expect(output.single, contains('\x1b]4;0;rgb:2424/2929/2f2f\x1b\\'));
    expect(output.single, contains('\x1b]4;8;rgb:5757/6060/6a6a\x1b\\'));
    expect(output.single, contains('\x1b]4;15;rgb:8c8c/9595/9f9f\x1b\\'));
    expect(output.single, isNot(contains('\x1b]4;16;')));
  });

  test('explicit xterm palette grayscale colors stay standard', () {
    final darkTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        .toXtermTheme();
    final lightTheme = monkey_themes.TerminalThemes.defaultLightTheme
        .toXtermTheme();
    final darkPainter = MonkeyTerminalPainter(
      theme: darkTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final lightPainter = MonkeyTerminalPainter(
      theme: lightTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    for (final painter in [darkPainter, lightPainter]) {
      expect(
        painter.resolveForegroundColor(CellColor.palette | 244),
        const Color(0xFF808080),
      );
      expect(
        painter.resolveBackgroundColor(CellColor.palette | 235),
        const Color(0xFF262626),
      );
    }
  });

  test('ANSI bright colors follow the active theme palette', () {
    final darkTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        .toXtermTheme();
    final lightTheme = monkey_themes.TerminalThemes.defaultLightTheme
        .toXtermTheme();
    final darkPainter = MonkeyTerminalPainter(
      theme: darkTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final lightPainter = MonkeyTerminalPainter(
      theme: lightTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    expect(
      darkPainter.resolveForegroundColor(CellColor.named | 8),
      darkTheme.brightBlack,
    );
    expect(
      lightPainter.resolveForegroundColor(CellColor.named | 8),
      lightTheme.brightBlack,
    );
    expect(
      darkPainter.resolveForegroundColor(CellColor.named | 15),
      darkTheme.brightWhite,
    );
    expect(
      lightPainter.resolveForegroundColor(CellColor.named | 15),
      lightTheme.brightWhite,
    );
    expect(
      darkPainter.resolveBackgroundColor(CellColor.palette | 15),
      darkTheme.brightWhite,
    );
    expect(
      lightPainter.resolveBackgroundColor(CellColor.palette | 15),
      lightTheme.brightWhite,
    );
    expect(darkTheme.brightBlack, isNot(lightTheme.brightBlack));
    expect(darkTheme.brightWhite, isNot(darkTheme.white));
  });

  test('faint terminal text preserves each theme base readability', () {
    for (final theme in monkey_themes.TerminalThemes.all) {
      final faintForeground = resolveMonkeyTerminalFaintForegroundColor(
        foreground: theme.foreground,
        background: theme.background,
      );
      final baseContrast = _contrastRatio(theme.foreground, theme.background);
      final expectedContrast = baseContrast >= 4.5 ? 4.5 : baseContrast;

      expect(
        _contrastRatio(faintForeground, theme.background),
        greaterThanOrEqualTo(expectedContrast),
        reason:
            'Theme ${theme.name} should not let SGR 2 faint text fall below '
            'the base foreground contrast that its palette provides.',
      );
    }
  });

  test('faint terminal text remains dim when contrast allows it', () {
    const theme = monkey_themes.TerminalThemes.atomOneDark;
    final defaultFaint = Color.alphaBlend(
      theme.foreground.withAlpha(128),
      theme.background,
    );
    final readableFaint = resolveMonkeyTerminalFaintForegroundColor(
      foreground: theme.foreground,
      background: theme.background,
    );

    expect(_contrastRatio(defaultFaint, theme.background), lessThan(4.5));
    expect(
      _contrastRatio(readableFaint, theme.background),
      greaterThanOrEqualTo(4.5),
    );
    expect(readableFaint, isNot(theme.foreground));
  });
}
