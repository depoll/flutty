import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

void main() {
  group('GraphicsManager viewport indexes', () {
    test('placeholder lookup visits only requested buffer rows', () {
      final terminal = Terminal(maxLines: 100)..resize(12, 6);
      terminal.write(
        List<String>.generate(40, (index) => 'line $index').join('\r\n'),
      );
      final lines = terminal.buffer.lines;
      final graphics = terminal.graphics;

      final offscreen = graphics.addPlaceholder(
        imageId: 7,
        imageIdBitWidth: 24,
        anchor: lines[2].createAnchor(4),
        row: 3,
        col: 5,
      );
      final visible = graphics.addPlaceholder(
        imageId: 7,
        imageIdBitWidth: 24,
        anchor: lines[35].createAnchor(1),
        row: 0,
        col: 0,
      );

      expect(graphics.placeholdersInRows(lines, 34, 36), [visible]);
      expect(visible.gridColumns, 6);
      expect(visible.gridRows, 4);
      expect(visible.sequence, greaterThan(offscreen.sequence));
    });

    test('diacritic-expanded image ids keep separate grid sizes', () {
      final terminal = Terminal(maxLines: 100)..resize(12, 6);
      final graphics = terminal.graphics;
      final lines = terminal.buffer.lines;
      final large = graphics.addPlaceholder(
        imageId: 7,
        imageIdBitWidth: 8,
        anchor: lines[0].createAnchor(0),
        row: 3,
        col: 5,
      )..updateMetadata(
          imageId: 0x01000007,
          imageIdBitWidth: 8,
          row: 3,
          col: 5,
        );
      final small = graphics.addPlaceholder(
        imageId: 7,
        imageIdBitWidth: 8,
        anchor: lines[1].createAnchor(0),
        row: 0,
        col: 0,
      )..updateMetadata(
          imageId: 0x02000007,
          imageIdBitWidth: 8,
          row: 0,
          col: 0,
        );

      expect((large.gridColumns, large.gridRows), (6, 4));
      expect((small.gridColumns, small.gridRows), (1, 1));
    });

    test('physical placement preservation is local to one line', () {
      final terminal = Terminal(maxLines: 100)..resize(12, 6);
      terminal.write(
        List<String>.generate(40, (index) => 'line $index').join('\r\n'),
      );
      final lines = terminal.buffer.lines;
      final graphics = terminal.graphics;
      final targetAnchor = lines[35].createAnchor(1);
      final otherAnchor = lines[2].createAnchor(1);

      final targetPlacement = graphics.placeImage(
        1,
        targetAnchor,
        cols: 2,
        rows: 2,
      );
      graphics.placeImage(2, otherAnchor, cols: 2, rows: 2);

      expect(graphics.physicalPlacementAnchorsInLine(lines[35]), {
        targetAnchor,
      });
      expect(graphics.physicalPlacementAnchorsInLine(lines[34]), isEmpty);
      expect(graphics.placementsInRows(lines, 36, 36), [targetPlacement]);
    });

    test('scrollback eviction removes graphics anchor indexes', () {
      final terminal = Terminal(maxLines: 30)..resize(8, 4);
      final firstLine = terminal.buffer.lines[0];
      terminal.graphics
        ..addPlaceholder(
          imageId: 9,
          imageIdBitWidth: 24,
          anchor: firstLine.createAnchor(0),
          row: 0,
          col: 0,
        )
        ..placeImage(10, firstLine.createAnchor(1), cols: 1, rows: 1);

      terminal.write(
        List<String>.generate(60, (index) => 'row $index').join('\r\n'),
      );

      expect(terminal.graphics.placeholderCount, 0);
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(terminal.graphics.placeholders, isEmpty);
      expect(terminal.graphics.placements, isEmpty);
    });
  });
}
