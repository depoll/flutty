// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

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
}
