import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Future<String> _buildPngBase64(int width, int height) async {
  final image = await _buildImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64.encode(bytes!.buffer.asUint8List());
}

Future<ui.Image> _buildImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFF0000),
  );
  return recorder.endRecording().toImage(width, height);
}

/// Waits until image [id] has finished its (deferred) decode and is stored.
Future<void> _awaitImage(Terminal terminal, int id) async {
  var waited = 0;
  while (terminal.graphics.imageById(id) == null && waited < 2000) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    waited += 20;
  }
}

/// Store-only (`a=t`) and virtual (`a=T,U=1`) images are decoded lazily: the
/// bytes are retained and only decoded when something paints them. Tests that
/// assert on the decoded image must first reference it the way the renderer
/// does on a visible frame, then wait for the async decode.
Future<void> _decodeDeferredImage(Terminal terminal, int id) async {
  terminal.graphics.imageForPlacement(id);
  await _awaitImage(terminal, id);
}

void main() {
  testWidgets('Kitty graphics a=T decodes, stores and places an image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      expect(terminal.graphics.hasPlacements, isFalse);

      terminal.write('\x1b_Ga=T,f=100;$pngBase64\x1b\\');

      // The decode runs asynchronously; give it time to complete.
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final placement = terminal.graphics.placements.single;
      expect(placement.col, 0);
      expect(placement.row, 0);

      final stored = terminal.graphics.imageById(placement.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('a burst of images all decode despite the concurrency gate', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // Transmit more images at once than the decode gate's permits (3) to
      // exercise queueing. Decoding is deferred until each is referenced, so
      // reference them all (as the painter would) and confirm none deadlock.
      const count = 8;
      for (var id = 1; id <= count; id++) {
        terminal.write('\x1b_Ga=t,f=100,i=$id;$pngBase64\x1b\\');
      }
      for (var id = 1; id <= count; id++) {
        terminal.graphics.imageForPlacement(id);
      }

      var waited = 0;
      bool allStored() => List.generate(count, (i) => i + 1)
          .every((id) => terminal.graphics.imageById(id) != null);
      while (!allStored() && waited < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      for (var id = 1; id <= count; id++) {
        expect(
          terminal.graphics.imageById(id),
          isNotNull,
          reason: 'image $id should have decoded despite throttling',
        );
      }
    });
  });

  testWidgets('Kitty graphics payload tolerates embedded whitespace', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      // Splice newlines/spaces into the payload; the streaming decoder must
      // skip them, matching the previous lenient whitespace-stripping behavior.
      final mid = pngBase64.length ~/ 2;
      final noisy =
          '${pngBase64.substring(0, mid)}\n \r\t${pngBase64.substring(mid)}';

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=100;$noisy\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final stored = terminal.graphics
          .imageById(terminal.graphics.placements.single.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('Kitty graphics omitted format defaults to RGBA', (tester) async {
    await tester.runAsync(() async {
      final rgbaBase64 = base64.encode([0xFF, 0x00, 0x00, 0xFF]);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,s=1,v=1;$rgbaBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final placement = terminal.graphics.placements.single;
      final stored = terminal.graphics.imageById(placement.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 1);
      expect(stored.image.height, 1);
    });
  });

  testWidgets('Kitty graphics query responds before following DA1', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\\x1b[c',
    );

    expect(output, ['\x1b_Gi=31;OK\x1b\\', '\x1b[?62;22c']);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty graphics query rejects unsupported transmission media', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,a=q,t=f;${base64.encode('/tmp/image.png'.codeUnits)}'
      '\x1b\\',
    );

    expect(
      output,
      ['\x1b_Gi=31;EINVAL: unsupported transmission medium\x1b\\'],
    );
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty graphics query honors quiet OK suppression', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,q=1,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\',
    );

    expect(output, isEmpty);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty graphics query q=2 suppresses successful responses', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,q=2,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\',
    );

    expect(output, isEmpty);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty transmit-only images are stored by protocol id', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=t,i=42,f=100;$pngBase64\x1b\\');

      // Deferred: the bytes are retained but not decoded until referenced.
      expect(terminal.graphics.imageById(42), isNull);
      expect(terminal.graphics.hasPendingImage(42), isTrue);

      await _decodeDeferredImage(terminal, 42);

      final stored = terminal.graphics.imageById(42);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('transmit-only images are not decoded until referenced', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // A window switch replays every retained image up front (store-only).
      const count = 5;
      for (var id = 1; id <= count; id++) {
        terminal.write('\x1b_Ga=t,f=100,i=$id;$pngBase64\x1b\\');
      }

      // Give any (unwanted) eager decode ample time to run.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      for (var id = 1; id <= count; id++) {
        expect(
          terminal.graphics.imageById(id),
          isNull,
          reason: 'image $id must stay deferred until something paints it',
        );
        expect(terminal.graphics.hasPendingImage(id), isTrue);
      }

      // Reference only image 3, the way the painter would for a visible cell.
      await _decodeDeferredImage(terminal, 3);

      expect(terminal.graphics.imageById(3), isNotNull);
      for (final id in [1, 2, 4, 5]) {
        expect(
          terminal.graphics.imageById(id),
          isNull,
          reason: 'off-screen image $id must not be decoded',
        );
        expect(terminal.graphics.hasPendingImage(id), isTrue);
      }
    });
  });

  testWidgets('re-transmitting an identical image id reuses the cached decode',
      (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // First transmit + reference decodes and stores the image.
      terminal.write('\x1b_Ga=t,i=77,f=100;$pngBase64\x1b\\');
      await _decodeDeferredImage(terminal, 77);
      final first = terminal.graphics.imageById(77);
      expect(first, isNotNull);

      // Re-transmitting the same id with identical bytes (as a window-switch
      // replay does) must reuse the existing decoded image, not replace it.
      terminal.write('\x1b_Ga=t,i=77,f=100;$pngBase64\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final second = terminal.graphics.imageById(77);
      expect(
        identical(first!.image, second!.image),
        isTrue,
        reason: 'identical replay should reuse the same ui.Image',
      );
    });
  });

  testWidgets('re-transmitting an id with new bytes decodes a fresh image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final smallPng = await _buildPngBase64(3, 2);
      final largerPng = await _buildPngBase64(5, 4);
      final terminal = Terminal();

      terminal.write('\x1b_Ga=t,i=88,f=100;$smallPng\x1b\\');
      await _decodeDeferredImage(terminal, 88);
      expect(terminal.graphics.imageById(88)!.image.width, 3);

      // Different bytes for the same id must miss the dedup, supersede the stale
      // image and re-decode once referenced again.
      terminal.write('\x1b_Ga=t,i=88,f=100;$largerPng\x1b\\');
      terminal.graphics.imageForPlacement(88);
      var waited = 0;
      while ((terminal.graphics.imageById(88)?.image.width ?? 3) != 5 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(88)!.image.width, 5);
    });
  });

  test('terminalGraphicsSourceSignature distinguishes content and is stable',
      () {
    final a = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));
    final b = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));
    final c =
        Uint8List.fromList(List<int>.generate(5000, (i) => (i + 1) % 251));
    expect(terminalGraphicsSourceSignature(a), isNot(0));
    expect(
      terminalGraphicsSourceSignature(a),
      terminalGraphicsSourceSignature(b),
      reason: 'identical bytes hash equally',
    );
    expect(
      terminalGraphicsSourceSignature(a),
      isNot(terminalGraphicsSourceSignature(c)),
      reason: 'different bytes hash differently',
    );
    expect(terminalGraphicsSourceSignature(Uint8List(0)), 0);
  });

  testWidgets('decodeTerminalImage downscales an oversized image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // A 2400x1200 PNG must come back capped to 1280 on its longest side with
      // aspect ratio preserved (so it can't blow up decoded memory on mobile).
      final pngBytes = base64.decode(await _buildPngBase64(2400, 1200));
      final image = await decodeTerminalImage(pngBytes, format: 100);
      expect(image, isNotNull);
      expect(image!.width, 1280);
      expect(image.height, 640);
    });
  });

  testWidgets('decodeTerminalImage leaves a small image untouched', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(320, 200));
      final image = await decodeTerminalImage(pngBytes, format: 100);
      expect(image, isNotNull);
      expect(image!.width, 320);
      expect(image.height, 200);
    });
  });

  testWidgets('Kitty placeholder color can resolve high-byte image ids', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      const imageId = 42 + (2 << 24);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=t,i=$imageId,f=100;$pngBase64\x1b\\');

      // Referencing by the placeholder color (low byte 42) triggers the
      // deferred decode via the low-bits fallback.
      terminal.graphics.imageByPlaceholderColorId(42, bitWidth: 8);
      await _awaitImage(terminal, imageId);

      final stored = terminal.graphics.imageByPlaceholderColorId(
        42,
        bitWidth: 8,
      );
      expect(stored, isNotNull);
      expect(stored!.id, imageId);
    });
  });

  testWidgets('Kitty virtual transmit-and-place uses a virtual placement', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,U=1,i=43,f=100,c=3,r=2;$pngBase64\x1b\\');

      // U=1 means the client displays the image through Unicode placeholder
      // cells, so the terminal must not create a physical placement (that would
      // draw a duplicate image at the cursor). The virtual placement is
      // registered immediately even though the decode is deferred.
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(
        terminal.graphics.virtualPlacementById(43),
        isNotNull,
        reason: 'Unicode placeholder clients reference the virtual placement',
      );

      await _decodeDeferredImage(terminal, 43);

      final stored = terminal.graphics.imageById(43);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
      expect(terminal.graphics.hasPlacements, isFalse);

      terminal.write('\x1b[2J');
      expect(
        terminal.graphics.imageById(43),
        isNotNull,
        reason: 'virtual placeholder redraws can still reuse the image bytes',
      );
    });
  });

  testWidgets('Kitty protocol-id image survives clear for placeholder redraw', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,i=44,f=100,c=3,r=2;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageById(44), isNotNull);
      expect(terminal.graphics.hasPlacements, isTrue);

      terminal.write('\x1b[2J');

      expect(terminal.graphics.hasPlacements, isFalse);
      expect(
        terminal.graphics.imageById(44),
        isNotNull,
        reason: 'placeholder redraws can follow a screen clear',
      );
    });
  });

  testWidgets('Kitty Unicode placeholder diacritics do not consume cells', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    terminal.write('\x1b[38;5;42m$placeholder\u0305\u0305X');

    final line = terminal.buffer.lines[terminal.buffer.absoluteCursorY];
    expect(line.getCodePoint(0), kittyGraphicsPlaceholderCodePoint);
    expect(line.getCodePoint(1), 'X'.codeUnitAt(0));
    expect(line.getText(0, 2), '${placeholder}X');
  });

  testWidgets('Kitty Unicode row-only placeholders reset columns per row', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    terminal.write(
      '\x1b[38;5;42m'
      '$placeholder\u0305$placeholder$placeholder\r\n'
      '$placeholder\u030D$placeholder$placeholder',
    );

    final placeholders = terminal.graphics.placeholders;
    expect(placeholders.map((p) => (p.row, p.col)).toList(), [
      (0, 0),
      (0, 1),
      (0, 2),
      (1, 0),
      (1, 1),
      (1, 2),
    ]);
  });

  testWidgets('placeholders survive the image decode that backs them', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();
      final placeholder =
          String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

      // The image transmit and the placeholder cells that reference it arrive
      // together, but the PNG decode completes asynchronously afterwards. The
      // decode must not drop the placeholder cells waiting on that image.
      terminal
        ..write('\x1b_Ga=T,U=1,i=77,f=100,c=3,r=2;$pngBase64\x1b\\')
        ..write('\x1b[38;2;0;0;77m'
            '$placeholder\u0305\u0305$placeholder\u0305\u030D'
            '$placeholder\u0305\u030E');

      expect(terminal.graphics.placeholders, isNotEmpty);
      final before = terminal.graphics.placeholders.length;

      // The painter references the backing image on the next frame, which
      // starts the deferred decode; that decode must not drop the placeholders.
      terminal.graphics.imageForPlacement(77);
      await _awaitImage(terminal, 77);

      expect(terminal.graphics.imageById(77), isNotNull);
      expect(
        terminal.graphics.placeholders.length,
        before,
        reason: 'storing the decoded image must not drop its placeholder cells',
      );
    });
  });

  testWidgets('Kitty Unicode placeholders stay attached across a scroll', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 100)..resize(20, 4);
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    terminal.write('\x1b[38;5;42m$placeholder\u0305\u0305');
    final placeholdersBefore = terminal.graphics.placeholders.length;
    expect(placeholdersBefore, greaterThan(0));

    // Emit far more lines than the 4-row viewport so the buffer scrolls. This
    // used to detach the line that owns the placeholder anchor, dropping it.
    for (var i = 0; i < 20; i++) {
      terminal.write('row $i\r\n');
    }

    expect(
      terminal.graphics.placeholders.every((p) => p.attached),
      isTrue,
      reason: 'scrolling must not orphan placeholder anchors',
    );
    expect(terminal.graphics.placeholders.length, placeholdersBefore);
  });

  testWidgets(
      'Kitty Unicode placeholders support high-byte diacritics above 127', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
    const imageId = 42 + (200 << 24);

    terminal
      ..graphics.storeImageWithId(imageId, await _buildImage(1, 1))
      ..write('\x1b[38;5;42m$placeholder\u0305\u0305\u20D4');

    final placeholders = terminal.graphics.placeholders;
    expect(placeholders, hasLength(1));
    expect(placeholders.single.imageId, imageId);
    expect(
      terminal.graphics.imageByPlaceholderColorId(
        placeholders.single.imageId,
        bitWidth: placeholders.single.imageIdBitWidth,
      ),
      isNotNull,
    );
  });

  testWidgets('a=T advances the cursor below the image by r rows', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(2, 2);
      final terminal = Terminal();

      terminal.write('\x1b_Ga=T,f=100,r=3;$pngBase64\x1b\\X');

      // 'X' should land three rows below where the image was anchored.
      expect(terminal.buffer.lines[3].getText().trimRight(), 'X');
    });
  });

  testWidgets('a=T with C=1 leaves the cursor where it is', (tester) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(2, 2);
      final terminal = Terminal();

      // C=1 is the Kitty "do not move the cursor" policy: the following 'X' must
      // stay on the same row as the image anchor rather than dropping r rows.
      terminal.write('\x1b_Ga=T,f=100,r=3,C=1;$pngBase64\x1b\\X');

      expect(terminal.buffer.lines[0].getText().trimRight(), 'X');
      expect(terminal.buffer.lines[3].getText().trimRight(), isEmpty);
    });
  });

  testWidgets('invalid graphics payload is ignored without placing', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=100;bm90LWFuLWltYWdl\x1b\\');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('a viewport image keeps its row after clearing scrollback', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal(maxLines: 1000)..resize(40, 10);
      // Build some scrollback, then a marker line and the image right below it,
      // all kept inside the viewport.
      for (var i = 0; i < 20; i++) {
        terminal.write('pre $i\r\n');
      }
      terminal.write('MARKER\r\n');
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\',
      );
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      int markerRow() {
        for (var i = 0; i < terminal.buffer.lines.length; i++) {
          if (terminal.buffer.lines[i].getText().contains('MARKER')) return i;
        }
        return -1;
      }

      expect(terminal.graphics.placements.single.row, markerRow() + 1);

      // Clearing the scrollback (CSI 3 J) shifts every surviving line up; the
      // image must move with its anchor line, not stay at the old absolute row.
      terminal.write('\x1b[3J');
      expect(terminal.graphics.hasPlacements, isTrue);
      expect(
        terminal.graphics.placements.single.row,
        markerRow() + 1,
        reason:
            'the image must stay glued to its content after clearScrollback',
      );
    });
  });

  testWidgets('clearing the screen (CSI 2 J) removes placed images', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}'
        '\x1b\\',
      );
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.hasPlacements, isTrue);

      terminal.write('\x1b[2J');
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('partial erases remove intersecting placed images', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal()..resize(40, 10);

      Future<void> placeImage() async {
        terminal
          ..write('\x1b[H')
          ..write(
            '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\',
          );
        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
        expect(terminal.graphics.hasPlacements, isTrue);
      }

      await placeImage();
      terminal.write('\x1b[H\x1b[2K');
      expect(
        terminal.graphics.hasPlacements,
        isFalse,
        reason: 'CSI K clears the image row and must drop the placement',
      );

      await placeImage();
      terminal.write('\x1b[H\x1b[4X');
      expect(
        terminal.graphics.hasPlacements,
        isFalse,
        reason: 'CSI X clears the image cells and must drop the placement',
      );
    });
  });

  testWidgets(
    'clearing does not dispose the decoded image (no use-after-free)',
    (tester) async {
      await tester.runAsync(() async {
        final terminal = Terminal();
        terminal.write(
          '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}'
          '\x1b\\',
        );
        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
        final placement = terminal.graphics.placements.single;
        final image = terminal.graphics.imageById(placement.imageId)!.image;
        expect(image.debugDisposed, isFalse);

        // Clearing the screen drops the placement, but the underlying image must
        // NOT be disposed: a frame already in flight may still draw it, and
        // drawing a disposed image crashes the engine.
        terminal.write('\x1b[2J');
        expect(terminal.graphics.hasPlacements, isFalse);
        expect(
          image.debugDisposed,
          isFalse,
          reason: 'the decoded image must not be force-disposed on clear',
        );
      });
    },
  );

  testWidgets('a clear that races an in-flight decode places no stale image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal()..resize(40, 10);
      // Start the (asynchronous) decode, then clear the screen before it can
      // finish — as a MonkeyMux replay clear would. The image must not appear.
      terminal
        ..write('\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\')
        ..write('\x1b[H\x1b[2J\x1b[3J');

      // Give any pending decode time to complete.
      var waited = 0;
      while (waited < 600) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(
        terminal.graphics.hasPlacements,
        isFalse,
        reason: 'an image decoded after a clear must be discarded',
      );

      // A subsequent (replay) image still places exactly one.
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\',
      );
      waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(1));
    });
  });

  testWidgets('an unrelated erase does not discard an in-flight image decode', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal()..resize(40, 10);
      terminal
        ..write('\x1b[H')
        ..write('\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\')
        // Erase a prompt/status row that does not intersect the image while the
        // decode is still in flight. Replay streams commonly contain such
        // erases after the image APC; they must not cancel the image.
        ..write('\x1b[10;1H\x1b[2K');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(
        terminal.graphics.hasPlacements,
        isTrue,
        reason: 'unrelated erases during replay must not drop the image',
      );
    });
  });

  testWidgets('images do not leak across the alternate screen', (tester) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}'
        '\x1b\\',
      );
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.hasPlacements, isTrue);

      // The alternate screen has its own (empty) image set.
      terminal.write('\x1b[?47h');
      expect(terminal.graphics.hasPlacements, isFalse);

      // Returning to the main screen restores the image.
      terminal.write('\x1b[?47l');
      expect(terminal.graphics.hasPlacements, isTrue);
    });
  });

  testWidgets(
    'Kitty graphics a=d removes a placement the client deletes by id',
    (tester) async {
      await tester.runAsync(() async {
        final pngBase64 = await _buildPngBase64(4, 3);
        final terminal = Terminal();

        // Transmit-and-display a physical placement with an explicit image and
        // placement id, exactly as Copilot CLI does for its full-screen image
        // viewer (a=T, p=1, i=..., no Unicode placeholder).
        const imageId = 13912678;
        terminal
            .write('\x1b_Ga=T,i=$imageId,p=1,f=100,c=8,r=4;$pngBase64\x1b\\');

        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
        expect(
          terminal.graphics.placements,
          hasLength(1),
          reason: 'the transmit-and-display must create a placement',
        );

        // Closing the viewer sends a delete-by-id (d=i). The placement must be
        // removed so it does not linger as a background overlay.
        terminal.write('\x1b_Ga=d,d=i,i=$imageId,p=1,q=2\x1b\\');

        expect(
          terminal.graphics.placements,
          isEmpty,
          reason: 'a=d,d=i must remove the matching placement',
        );
        expect(
          terminal.graphics.imageById(imageId),
          isNotNull,
          reason: 'a lowercase d=i deletes the placement but keeps image data',
        );
      });
    },
  );

  testWidgets(
    'Kitty graphics a=d,d=i matches the client placement id, not paint order',
    (tester) async {
      await tester.runAsync(() async {
        final pngBase64 = await _buildPngBase64(4, 3);
        final terminal = Terminal();

        // A first physical placement of a different image. Its decode finishes
        // before the next, so it takes the first internal placement slot.
        terminal.write('\x1b_Ga=T,i=999,p=7,f=100,c=4,r=2;$pngBase64\x1b\\');
        var waited = 0;
        while (terminal.graphics.placements.length < 1 && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }

        // The full-screen image, transmitted later, with client placement id 1.
        // Its internal placement id therefore differs from its p= value.
        const imageId = 13912678;
        terminal
            .write('\x1b_Ga=T,i=$imageId,p=1,f=100,c=8,r=4;$pngBase64\x1b\\');
        waited = 0;
        while (terminal.graphics.placements.length < 2 && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }

        // Closing the viewer deletes by image id + client placement id 1. The
        // match must be on the client p= value, not the internal ordering, or
        // the image lingers as a background ghost.
        terminal.write('\x1b_Ga=d,d=i,i=$imageId,p=1,q=2\x1b\\');

        final remaining =
            terminal.graphics.placements.map((p) => p.imageId).toList();
        expect(
          remaining,
          isNot(contains(imageId)),
          reason: 'the targeted placement must be deleted by its client p=',
        );
        expect(
          remaining,
          contains(999),
          reason: 'the unrelated placement must survive',
        );
      });
    },
  );

  testWidgets('Kitty graphics a=d with no selector deletes all placements', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 3);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=1,f=100,c=4,r=2;$pngBase64\x1b\\')
        ..write('\x1b_Ga=T,i=2,f=100,c=4,r=2;$pngBase64\x1b\\');

      var waited = 0;
      while (terminal.graphics.placements.length < 2 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(2));

      // The Kitty default selector when d= is omitted is 'a' (all placements).
      terminal.write('\x1b_Ga=d\x1b\\');

      expect(terminal.graphics.placements, isEmpty);
    });
  });

  testWidgets('Kitty graphics a=D (uppercase) frees the image data too', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 3);
      final terminal = Terminal();

      const imageId = 777;
      terminal.write('\x1b_Ga=T,i=$imageId,p=1,f=100,c=4,r=2;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(imageId), isNotNull);

      terminal.write('\x1b_Ga=d,d=I,i=$imageId\x1b\\');

      expect(terminal.graphics.placements, isEmpty);
      expect(
        terminal.graphics.imageById(imageId),
        isNull,
        reason: 'an uppercase d=I must also free the image data',
      );
    });
  });

  testWidgets('Kitty graphics o=z inflates a zlib-compressed RGBA payload', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // A 2x2 solid red RGBA image, zlib-compressed (o=z).
      final raw = Uint8List.fromList(
        List<int>.generate(
            2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : (i % 4 == 0 ? 0xFF : 0)),
      );
      final compressed = ZLibEncoder().encode(raw);
      final payload = base64.encode(compressed);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=32,o=z,s=2,v=2;$payload\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final stored = terminal.graphics
          .imageById(terminal.graphics.placements.single.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 2);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('Kitty graphics o=z inflates a zlib-compressed PNG payload', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(3, 2));
      final compressed = ZLibEncoder().encode(pngBytes);
      final payload = base64.encode(compressed);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=100,o=z;$payload\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final stored = terminal.graphics
          .imageById(terminal.graphics.placements.single.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('Kitty graphics query accepts o=z and rejects other o values', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(3, 2));
      final compressed = base64.encode(ZLibEncoder().encode(pngBytes));

      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      // q=0 so success responses are emitted; o=z must validate OK.
      terminal.write('\x1b_Ga=q,i=1,f=100,o=z,q=0;$compressed\x1b\\');
      expect(responses.single, contains('OK'));

      responses.clear();
      // An unknown compression value must still be rejected.
      terminal.write(
        '\x1b_Ga=q,i=2,f=100,o=w,q=0;${base64.encode(pngBytes)}\x1b\\',
      );
      expect(responses.single, contains('EINVAL'));
    });
  });

  testWidgets('Kitty graphics image numbers: transmit, place and delete by I=',
      (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      // Transmit-only with an image number (no id). The terminal must answer the
      // handshake echoing the number and the id it assigned.
      terminal.write('\x1b_Ga=t,I=5,f=100,q=0;$pngBase64\x1b\\');
      var waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, matches(RegExp(r'I=5,i=\d+;OK')));

      // The image can be placed by number.
      terminal.write('\x1b_Ga=p,I=5,c=3,r=2\x1b\\');
      expect(terminal.graphics.placements, hasLength(1));

      // ...and deleted by number (lowercase keeps the image data).
      terminal.write('\x1b_Ga=d,d=n,I=5\x1b\\');
      expect(terminal.graphics.placements, isEmpty);
      expect(
        terminal.graphics.imageIdForNumber(5),
        isNotNull,
        reason: 'd=n keeps the image data; only the placement is removed',
      );
    });
  });
}
