import 'dart:convert';
import 'dart:ui' as ui;

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

    expect(output, ['\x1b_Gi=31;OK\x1b\\', '\x1b[?1;2c']);
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

  testWidgets('eviction accounts for the image being stored', (tester) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager(maxImageCount: 10, maxMemoryBytes: 64);
      final first = await _buildImage(2, 2);
      final second = await _buildImage(2, 2);
      final third = await _buildImage(2, 2);

      final firstId = manager.storeImage(first);
      final secondId = manager.storeImage(second);
      final thirdId = manager.storeImage(third);

      expect(
        manager.imageById(firstId),
        isNull,
        reason:
            'the third 16-byte image must evict against future memory usage',
      );
      expect(manager.imageById(secondId), isNotNull);
      expect(manager.imageById(thirdId), isNotNull);
      expect(manager.currentMemoryBytes, 32);
      expect(first.debugDisposed, isFalse);
    });
  });
}
