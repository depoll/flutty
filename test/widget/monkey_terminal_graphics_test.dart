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

Future<bool> _boundaryHasRed(GlobalKey key) async =>
    await _boundaryRedPixelCount(key) > 0;

Future<int> _boundaryRedPixelCount(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final shot = await boundary.toImage();
  final data = (await shot.toByteData())!;
  var count = 0;
  for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
    final r = data.getUint8(i);
    final g = data.getUint8(i + 1);
    final b = data.getUint8(i + 2);
    if (r > 150 && g < 90 && b < 90) {
      count += 1;
    }
  }
  return count;
}

/// Kitty row/column placeholder diacritics for values 0..7 (rowcolumn-diacritics
/// order). Enough to drive a small placeholder grid in tests.
const _kittyDiacritics = <int>[
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
];

/// Builds the Kitty Unicode-placeholder cells for an [imageId] laid out across
/// [rows] x [cols] cells, exactly as a kitty-aware client (e.g. Copilot CLI)
/// emits them: a 24-bit foreground color carrying the image id, then a
/// U+10EEEE cell per position carrying its row/column diacritics.
String _placeholderGrid(int imageId, {required int cols, required int rows}) {
  final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
  final r = (imageId >> 16) & 0xFF;
  final g = (imageId >> 8) & 0xFF;
  final b = imageId & 0xFF;
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row++) {
    buffer.write('\x1b[38;2;$r;$g;${b}m');
    for (var col = 0; col < cols; col++) {
      buffer
        ..write(placeholder)
        ..writeCharCode(_kittyDiacritics[row])
        ..writeCharCode(_kittyDiacritics[col]);
    }
    buffer.write('\x1b[39m');
    if (row < rows - 1) {
      buffer.write('\r\n');
    }
  }
  return buffer.toString();
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

  testWidgets(
    'Kitty virtual placeholder image renders, then dismisses on redraw',
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

      // Copilot CLI emits the image with a virtual placement (U=1) and then
      // draws U+10EEEE placeholder cells to display it — frequently before the
      // image has finished decoding.
      const imageId = 0xA5E30B;
      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal
          ..write('\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\')
          ..write(_placeholderGrid(imageId, cols: 8, rows: 4));

        var waited = 0;
        while (terminal.graphics.imageById(imageId) == null && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
      });
      await tester.pump();

      // U=1 must not create a physical placement; the placeholders display it.
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason: 'the image must composite over the Unicode placeholder cells',
      );

      // Redrawing over the placeholder cells (here, clearing the screen) must
      // dismiss the image immediately rather than leaving it painted until an
      // unrelated repaint.
      terminal.write('\x1b[H\x1b[2J');
      await tester.pump();
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isFalse,
        reason: 'clearing the placeholder cells must dismiss the image',
      );
      expect(
        terminal.graphics.imageById(imageId),
        isNotNull,
        reason: 'the retained image bytes can back a later placeholder redraw',
      );
    },
  );

  testWidgets('Kitty Unicode placeholder image survives a scroll', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    // A short viewport so writing several rows of output scrolls the buffer,
    // which historically detached the placeholder anchors and dropped the image.
    final terminal = Terminal(maxLines: 200);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 120,
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

    const imageId = 0xA5E30B;
    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal
        ..write('\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\')
        ..write(_placeholderGrid(imageId, cols: 8, rows: 4));

      var waited = 0;
      while (terminal.graphics.imageById(imageId) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    final placeholdersBeforeScroll = terminal.graphics.placeholders.length;
    expect(
      placeholdersBeforeScroll,
      greaterThan(0),
      reason: 'placeholder cells should be tracked after the image is drawn',
    );

    // Emit more lines than the viewport holds so the buffer scrolls.
    for (var i = 0; i < 20; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pump();

    expect(
      terminal.graphics.placeholders.every((p) => p.attached),
      isTrue,
      reason:
          'scrolling must keep placeholder anchors attached, not orphan '
          'them (otherwise the image is pruned and never renders)',
    );
    expect(
      terminal.graphics.placeholders.length,
      placeholdersBeforeScroll,
      reason: 'no placeholder should be spuriously dropped by the scroll',
    );
  });

  testWidgets('Kitty placeholder image is dismissed once mostly overwritten', (
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

    const imageId = 0xA5E30B;
    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal
        ..write('\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\')
        ..write(_placeholderGrid(imageId, cols: 8, rows: 4));

      var waited = 0;
      while (terminal.graphics.imageById(imageId) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isTrue,
      reason: 'the fully present image must render',
    );

    // Simulate the way a TUI (e.g. Copilot CLI) tears the image down: it
    // overwrites most of the grid's cells with other content but, relying on
    // cursor-forward movement, leaves a few untouched. Those survivors must
    // not be painted as stale fragments/stripes of the image.
    terminal.write('\x1b[H'); // cursor home (top-left of the 8x4 grid)
    for (var row = 0; row < 3; row++) {
      terminal.write('${' ' * 8}\r\n'); // blank the first three grid rows
    }
    await tester.pump();

    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isFalse,
      reason:
          'with most of the grid overwritten the image must be dismissed, '
          'not left as fragments of the remaining cells',
    );
  });

  testWidgets(
    'Kitty image renders when delivered in chunked, stream-decoded bytes',
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
        const imageId = 0xA5E30B;
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        final stream =
            '\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\'
            '${_placeholderGrid(imageId, cols: 8, rows: 4)}';

        // Mirror the live SSH path: split the UTF-8 *bytes* into small chunks
        // (which can land mid-code-point, e.g. inside a 4-byte U+10EEEE cell or
        // the large APC payload) and run them through a streaming UTF-8 decoder
        // before writing, exactly like Stream.transform(Utf8Decoder) does.
        final bytes = utf8.encode(stream);
        final decoder = const Utf8Decoder(allowMalformed: true)
            .startChunkedConversion(
              ChunkedConversionSink<String>.withCallback((pieces) {
                for (final piece in pieces) {
                  if (piece.isNotEmpty) {
                    terminal.write(piece);
                  }
                }
              }),
            );
        const chunkSize = 7;
        for (var i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize).clamp(0, bytes.length);
          decoder.add(bytes.sublist(i, end));
        }
        decoder.close();

        var waited = 0;
        while (terminal.graphics.imageById(0xA5E30B) == null && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
      });
      await tester.pump();

      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason:
            'chunked, stream-decoded delivery must still composite the image',
      );
    },
  );

  testWidgets('Kitty Unicode placeholder resolves high-byte image ids', (
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

    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      const imageId = 42 + (2 << 24);
      terminal.write('\x1b_Ga=t,i=$imageId,f=100;$png\x1b\\');

      var waited = 0;
      while (terminal.graphics.imageById(imageId) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });

    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
    final row = List.filled(8, '$placeholder\u0305\u0305\u030E').join();
    terminal.write('\x1b[38;5;42m$row\r\n$row\r\n$row\r\n$row\x1b[39m');
    await tester.pump();

    var hasRed = false;
    await tester.runAsync(() async {
      hasRed = await _boundaryHasRed(boundaryKey);
    });

    expect(
      hasRed,
      isTrue,
      reason:
          'the placeholder color should resolve the retained high-byte image',
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
