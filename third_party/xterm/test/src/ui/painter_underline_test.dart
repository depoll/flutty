import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';

void main() {
  test('paintTerminalCellUnderline tolerates degenerate cell metrics', () {
    const sizes = [
      Size(0, 0),
      Size(double.nan, double.nan),
      Size(double.infinity, double.infinity),
      Size(-5, -5),
      Size(8, 16), // valid
    ];
    const offsets = [Offset.zero, Offset(double.nan, 0), Offset(0, double.nan)];

    for (final size in sizes) {
      for (final offset in offsets) {
        for (var style = 0; style <= 5; style++) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          expect(
            () => paintTerminalCellUnderline(
              canvas,
              offset,
              size,
              style,
              const Color(0xFFFFFFFF),
            ),
            returnsNormally,
            reason: 'size=$size offset=$offset style=$style',
          );
          recorder.endRecording();
        }
      }
    }
  });
}
