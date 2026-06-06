import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Future<String> _buildPngBase64(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64.encode(bytes!.buffer.asUint8List());
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
}
