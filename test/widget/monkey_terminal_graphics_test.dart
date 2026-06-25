import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

Future<String> _buildSolidPngBase64(Color color, int size) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64.encode(bytes!.buffer.asUint8List());
}

Future<bool> _boundaryHasRed(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final shot = await boundary.toImage();
  final data = (await shot.toByteData())!;
  for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
    final r = data.getUint8(i);
    final g = data.getUint8(i + 1);
    final b = data.getUint8(i + 2);
    if (r > 150 && g < 90 && b < 90) {
      return true;
    }
  }
  return false;
}

void main() {
  testWidgets('Kitty graphics image is composited into the terminal', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: RepaintBoundary(
                key: boundaryKey,
                child: MonkeyTerminalView(terminal, hardwareKeyboardOnly: true),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    var hasRed = false;
    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal.write('\x1b_Ga=T,f=100,c=8,r=4;$png\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final shot = await boundary.toImage();
      final data = (await shot.toByteData())!;
      for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
        final r = data.getUint8(i);
        final g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2);
        if (r > 150 && g < 90 && b < 90) {
          hasRed = true;
          break;
        }
      }
    });

    expect(
      terminal.graphics.hasPlacements,
      isTrue,
      reason: 'the image should have been decoded and placed',
    );
    expect(
      hasRed,
      isTrue,
      reason: 'the placed red image should be composited into the terminal',
    );
  });

  testWidgets(
    'Kitty Unicode placeholder image is composited into the terminal',
    (tester) async {
      final boundaryKey = GlobalKey();
      final terminal = Terminal();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 300,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: MonkeyTerminalView(
                    terminal,
                    hardwareKeyboardOnly: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal.write('\x1b_Ga=T,i=42,f=100,c=8,r=4;$png\x1b\\');

        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
      });
      terminal.write('\x1b[H\x1b[2J');
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(terminal.graphics.imageById(42), isNotNull);

      final placeholder = String.fromCharCode(
        kittyGraphicsPlaceholderCodePoint,
      );
      final row = List.filled(8, '$placeholder\u0305\u0305').join();
      terminal.write('\x1b[38;5;42m$row\r\n$row\r\n$row\r\n$row\x1b[39m');
      await tester.pump();

      var hasRed = false;
      await tester.runAsync(() async {
        hasRed = await _boundaryHasRed(boundaryKey);
      });

      expect(
        hasRed,
        isTrue,
        reason: 'the placed red image should replace the Unicode placeholders',
      );
    },
  );

  testWidgets('Kitty Unicode placeholders are hidden when image is missing', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: RepaintBoundary(
                key: boundaryKey,
                child: MonkeyTerminalView(terminal, hardwareKeyboardOnly: true),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
    final row = List.filled(8, '$placeholder\u0305\u0305').join();
    terminal.write('\x1b[38;2;255;0;0m$row\r\n$row\r\n$row\r\n$row\x1b[39m');
    await tester.pump();

    var hasPlaceholderRed = false;
    await tester.runAsync(() async {
      hasPlaceholderRed = await _boundaryHasRed(boundaryKey);
    });

    expect(
      hasPlaceholderRed,
      isFalse,
      reason:
          'missing image placeholders should not paint fallback glyph boxes',
    );
  });

  testWidgets('zoom, clear and re-place an image without crashing', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();
    var fontSize = 14.0;

    Widget build() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: RepaintBoundary(
              key: boundaryKey,
              child: MonkeyTerminalView(
                terminal,
                hardwareKeyboardOnly: true,
                textStyle: TerminalStyle(fontSize: fontSize),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pump();

    Future<void> writeImage(Color color) async {
      final png = await _buildSolidPngBase64(color, 24);
      terminal.write('\x1b_Ga=T,f=100,c=8,r=4;$png\x1b\\');
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    }

    await tester.runAsync(() => writeImage(const Color(0xFFFF0000)));
    await tester.pump();
    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isTrue,
      reason: 'image should render after placement',
    );

    // Sweep the font size the way a pinch-zoom does. Rasterizing each frame
    // exercises drawImageRect through the engine; degenerate cell metrics or a
    // disposed image would throw here.
    for (final fs in [9.0, 8.0, 20.0, 32.0, 12.0, 8.0, 16.0]) {
      fontSize = fs;
      await tester.pumpWidget(build());
      await tester.pump();
      await tester.runAsync(() => _boundaryHasRed(boundaryKey));
      expect(tester.takeException(), isNull, reason: 'zoom to $fs crashed');
    }

    // Clearing must remove the image (it does not "come back") and must not
    // dispose it out from under an in-flight frame.
    terminal.write('\x1b[2J\x1b[H');
    await tester.pump();
    expect(terminal.graphics.hasPlacements, isFalse);
    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isFalse,
      reason: 'image should be gone after clear',
    );
    for (final fs in [10.0, 24.0, 8.0, 14.0]) {
      fontSize = fs;
      await tester.pumpWidget(build());
      await tester.pump();
      await tester.runAsync(() => _boundaryHasRed(boundaryKey));
      expect(
        tester.takeException(),
        isNull,
        reason: 'zoom after clear at $fs crashed',
      );
    }
    expect(
      terminal.graphics.hasPlacements,
      isFalse,
      reason: 'cleared image must not reappear after zoom',
    );

    // A fresh image still renders after the clear.
    await tester.runAsync(() => writeImage(const Color(0xFFFF0000)));
    await tester.pump();
    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isTrue,
      reason: 'a new image should render after a clear',
    );
  });

  testWidgets('degenerate font sizes do not crash layout or paint', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal(maxLines: 200);
    var fontSize = 14.0;

    Widget build() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: RepaintBoundary(
              key: boundaryKey,
              child: MonkeyTerminalView(
                terminal,
                hardwareKeyboardOnly: true,
                textStyle: TerminalStyle(fontSize: fontSize),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pump();

    await tester.runAsync(() async {
      terminal.write('\x1b[4:3;58:2::255:60:60mcurly\x1b[0m text gyp\r\n');
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal.write('\x1b_Ga=T,f=100,c=24,r=6;$png\x1b\\');
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    // A sub-pixel font size used to drive cellSize to ~0 and crash
    // `width ~/ cellSize.width` / `(dstHeight / cellHeight).ceil()`. (NaN/Inf
    // font sizes are prevented upstream by the zoom math; see
    // terminal_screen_zoom_test.dart.)
    for (final fs in [0.01, 0.5, 1.0, 2.0, 8.0]) {
      fontSize = fs;
      await tester.pumpWidget(build());
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await (await boundary.toImage()).toByteData();
      });
      expect(
        tester.takeException(),
        isNull,
        reason: 'font size $fs crashed the terminal',
      );
    }
  });
}
