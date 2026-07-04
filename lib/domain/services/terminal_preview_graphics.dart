import 'dart:math' as math;
import 'dart:ui' show Image, Rect;

import 'package:xterm/xterm.dart';

import '../models/terminal_preview.dart';

/// Minimum fraction of a Kitty Unicode-placeholder instance's bounding box that
/// must contain live cells before it is treated as a real image (rather than a
/// scattered torn remnant). Kept in sync with `monkey_terminal_view.dart`.
const double _kittyPlaceholderRenderThreshold = 0.85;

/// Resolves the Kitty-graphics images that intersect the captured preview rows
/// ([startRow]..[endRow], inclusive absolute buffer rows) into cell-space draws.
///
/// The result mirrors the compositing done live in `monkey_terminal_view.dart`
/// (`_paintGraphics` + `_paintKittyPlaceholderGraphics`), but expressed in cells
/// relative to [startRow] so the connection-preview painter can scale it to its
/// own (smaller) cell size. Classic placements come first (sorted by z-index,
/// then placement id) followed by Unicode-placeholder strips, so a single
/// stable pass draws z<0 below the text and the rest above it.
List<TerminalPreviewImage> buildTerminalPreviewImages(
  Terminal terminal, {
  required int startRow,
  required int endRow,
}) {
  final graphics = terminal.graphics;
  if (!graphics.hasPlacements && graphics.imageCount == 0) {
    return const [];
  }

  final images = <TerminalPreviewImage>[
    ..._resolveClassicPlacements(terminal, startRow: startRow, endRow: endRow),
    ..._resolvePlaceholderStrips(terminal, startRow: startRow, endRow: endRow),
  ];
  return images;
}

/// Resolves classic (`a=p`/`a=T`) Kitty placements overlapping the preview rows.
List<TerminalPreviewImage> _resolveClassicPlacements(
  Terminal terminal, {
  required int startRow,
  required int endRow,
}) {
  final graphics = terminal.graphics;
  final viewWidth = terminal.viewWidth;
  if (viewWidth <= 0) {
    return const [];
  }

  final resolved = <TerminalPreviewImage>[];
  for (final placement in graphics.placements) {
    if (!placement.attached) {
      continue;
    }
    final stored = graphics.imageById(placement.imageId);
    if (stored == null) {
      continue;
    }
    final image = stored.image;
    final imageWidth = image.width.toDouble();
    final imageHeight = image.height.toDouble();

    // Source rectangle: the optional crop (x=,y=,w=,h=), clamped to the image.
    final srcLeft = placement.srcX.toDouble().clamp(0.0, imageWidth);
    final srcTop = placement.srcY.toDouble().clamp(0.0, imageHeight);
    final srcWidth =
        (placement.srcWidth > 0
                ? placement.srcWidth.toDouble()
                : imageWidth - srcLeft)
            .clamp(0.0, imageWidth - srcLeft);
    final srcHeight =
        (placement.srcHeight > 0
                ? placement.srcHeight.toDouble()
                : imageHeight - srcTop)
            .clamp(0.0, imageHeight - srcTop);
    if (srcWidth <= 0 || srcHeight <= 0) {
      continue;
    }

    final bool fitToWidth;
    final int colSpan;
    final int rowSpan;
    if (placement.cols > 0 && placement.rows > 0) {
      fitToWidth = false;
      colSpan = placement.cols;
      rowSpan = placement.rows;
    } else {
      // No explicit cell span: the painter fits the source width within the
      // available columns (mirrors the live view's pixel fit, resolution-free).
      fitToWidth = true;
      colSpan = (viewWidth - placement.col).clamp(1, viewWidth);
      // Approximate the covered rows only to cull placements that cannot reach
      // the captured window; the painter derives the real height when drawing.
      rowSpan = math.max(1, (srcHeight / srcWidth * colSpan).ceil());
    }

    // Skip placements entirely outside the captured rows.
    if (placement.row > endRow || placement.row + rowSpan < startRow) {
      continue;
    }

    resolved.add(
      TerminalPreviewImage(
        image: image,
        src: Rect.fromLTWH(srcLeft, srcTop, srcWidth, srcHeight),
        col: placement.col,
        row: placement.row - startRow,
        colSpan: colSpan,
        rowSpan: rowSpan,
        xOffset: placement.xOffset.toDouble(),
        yOffset: placement.yOffset.toDouble(),
        z: placement.z,
        order: placement.placementId,
        fitToWidth: fitToWidth,
      ),
    );
  }

  resolved.sort((a, b) {
    final byZ = a.z.compareTo(b.z);
    return byZ != 0 ? byZ : a.order.compareTo(b.order);
  });
  return resolved;
}

/// A live Kitty Unicode-placeholder cell resolved for the preview.
class _PreviewPlaceholderCell {
  const _PreviewPlaceholderCell({
    required this.imageKey,
    required this.imageId,
    required this.bitWidth,
    required this.cellRow,
    required this.cellCol,
    required this.imgRow,
    required this.imgCol,
  });

  final String imageKey;
  final int imageId;
  final int bitWidth;
  final int cellRow;
  final int cellCol;
  final int imgRow;
  final int imgCol;
}

/// Resolves Kitty Unicode-placeholder images into per-row cell strips.
///
/// Ports the density- and recency-gated grouping from
/// `monkey_terminal_view.dart` so partial/ghost placements are handled the same
/// way in the preview as in the live terminal.
List<TerminalPreviewImage> _resolvePlaceholderStrips(
  Terminal terminal, {
  required int startRow,
  required int endRow,
}) {
  final graphics = terminal.graphics..pruneDetachedPlaceholders();
  final placeholders = graphics.placeholders;
  if (placeholders.isEmpty) {
    return const [];
  }

  final buffer = terminal.buffer;
  final lineCount = buffer.lines.length;

  bool cellIsLivePlaceholder(int cellRow, int cellCol) {
    if (cellRow < 0 || cellRow >= lineCount) {
      return false;
    }
    final line = buffer.lines[cellRow];
    if (cellCol < 0 || cellCol >= line.length) {
      return false;
    }
    return line.getCodePoint(cellCol) == kittyGraphicsPlaceholderCodePoint;
  }

  // Pass 1: group live placeholder cells into display instances and keep the
  // ones dense/recent enough to be a real image (not a torn remnant or ghost).
  final gridCols = <String, int>{};
  final gridRows = <String, int>{};
  final instanceCellCount = <String, int>{};
  final instanceRowBounds = <String, List<int>>{};
  final instanceColBounds = <String, List<int>>{};
  final instanceRecency = <String, int>{};
  final instanceImageKey = <String, String>{};

  String instanceKeyFor(TerminalImagePlaceholder p, String imageKey) {
    final offsetRow = p.cellRow - p.row;
    final offsetCol = p.cellCol - p.col;
    return '$imageKey@$offsetRow,$offsetCol';
  }

  for (var index = 0; index < placeholders.length; index++) {
    final placeholder = placeholders[index];
    if (!placeholder.attached) {
      continue;
    }
    final key = '${placeholder.imageIdBitWidth}:${placeholder.imageId}';
    final virtualPlacement = graphics.virtualPlacementById(placeholder.imageId);
    final cols = (virtualPlacement?.cols ?? 0) > 0
        ? virtualPlacement!.cols
        : math.max(gridCols[key] ?? 1, placeholder.col + 1);
    final rows = (virtualPlacement?.rows ?? 0) > 0
        ? virtualPlacement!.rows
        : math.max(gridRows[key] ?? 1, placeholder.row + 1);
    gridCols[key] = cols;
    gridRows[key] = rows;

    if (!cellIsLivePlaceholder(placeholder.cellRow, placeholder.cellCol)) {
      continue;
    }
    final instanceKey = instanceKeyFor(placeholder, key);
    instanceImageKey[instanceKey] = key;
    instanceCellCount[instanceKey] = (instanceCellCount[instanceKey] ?? 0) + 1;
    instanceRecency[instanceKey] = index;
    final rowBounds = instanceRowBounds[instanceKey] ??= <int>[
      placeholder.row,
      placeholder.row,
    ];
    rowBounds[0] = math.min(rowBounds[0], placeholder.row);
    rowBounds[1] = math.max(rowBounds[1], placeholder.row);
    final colBounds = instanceColBounds[instanceKey] ??= <int>[
      placeholder.col,
      placeholder.col,
    ];
    colBounds[0] = math.min(colBounds[0], placeholder.col);
    colBounds[1] = math.max(colBounds[1], placeholder.col);
  }

  final denseInstances = <String>[];
  for (final entry in instanceCellCount.entries) {
    final rowBounds = instanceRowBounds[entry.key];
    final colBounds = instanceColBounds[entry.key];
    if (rowBounds == null || colBounds == null) {
      continue;
    }
    final boxRows = rowBounds[1] - rowBounds[0] + 1;
    final boxCols = colBounds[1] - colBounds[0] + 1;
    final boxArea = boxRows * boxCols;
    if (boxArea <= 0) {
      continue;
    }
    if (entry.value >= boxArea * _kittyPlaceholderRenderThreshold) {
      denseInstances.add(entry.key);
    }
  }
  if (denseInstances.isEmpty) {
    return const [];
  }

  // Among dense instances of the same image id, keep only the most recent one.
  final newestInstanceForImage = <String, String>{};
  for (final instanceKey in denseInstances) {
    final imageKey = instanceImageKey[instanceKey]!;
    final current = newestInstanceForImage[imageKey];
    if (current == null ||
        instanceRecency[instanceKey]! > instanceRecency[current]!) {
      newestInstanceForImage[imageKey] = instanceKey;
    }
  }
  final renderableInstances = newestInstanceForImage.values.toSet();
  if (renderableInstances.isEmpty) {
    return const [];
  }

  // Pass 2: collect the captured cells belonging to a renderable instance.
  final cellByPosition = <int, _PreviewPlaceholderCell>{};
  for (final placeholder in placeholders) {
    if (!placeholder.attached) {
      continue;
    }
    final key = '${placeholder.imageIdBitWidth}:${placeholder.imageId}';
    if (!renderableInstances.contains(instanceKeyFor(placeholder, key))) {
      continue;
    }
    final cellRow = placeholder.cellRow;
    if (cellRow < startRow || cellRow > endRow) {
      continue;
    }
    final cellCol = placeholder.cellCol;
    if (!cellIsLivePlaceholder(cellRow, cellCol)) {
      continue;
    }
    cellByPosition[cellRow * _kittyGridStride +
        cellCol] = _PreviewPlaceholderCell(
      imageKey: key,
      imageId: placeholder.imageId,
      bitWidth: placeholder.imageIdBitWidth,
      cellRow: cellRow,
      cellCol: cellCol,
      imgRow: placeholder.row,
      imgCol: placeholder.col,
    );
  }
  final visible = cellByPosition.values.toList();
  if (visible.isEmpty) {
    return const [];
  }

  // Merge contiguous cells in the same screen row into one horizontal run per
  // image, then stack vertically-adjacent runs so a solid image is drawn as a
  // single rectangle (no per-row sampling seams).
  visible.sort((a, b) {
    final byImage = a.imageKey.compareTo(b.imageKey);
    if (byImage != 0) return byImage;
    if (a.cellRow != b.cellRow) return a.cellRow - b.cellRow;
    return a.cellCol - b.cellCol;
  });

  final imageCache = <String, TerminalImage?>{};
  final runs = <_PreviewPlaceholderRun>[];
  var i = 0;
  while (i < visible.length) {
    final start = visible[i];
    var end = i;
    while (end + 1 < visible.length) {
      final cur = visible[end];
      final next = visible[end + 1];
      if (next.imageKey == cur.imageKey &&
          next.cellRow == cur.cellRow &&
          next.cellCol == cur.cellCol + 1 &&
          next.imgRow == cur.imgRow &&
          next.imgCol == cur.imgCol + 1) {
        end++;
      } else {
        break;
      }
    }
    final last = visible[end];
    i = end + 1;

    final stored = imageCache.putIfAbsent(
      start.imageKey,
      () => graphics.imageByPlaceholderColorId(
        start.imageId,
        bitWidth: start.bitWidth,
      ),
    );
    if (stored == null) {
      continue;
    }
    final cols = gridCols[start.imageKey] ?? 1;
    final rows = gridRows[start.imageKey] ?? 1;
    if (cols <= 0 || rows <= 0) {
      continue;
    }

    runs.add(
      _PreviewPlaceholderRun(
        imageKey: start.imageKey,
        image: stored.image,
        srcCellWidth: stored.image.width / cols,
        srcCellHeight: stored.image.height / rows,
        cellRow: start.cellRow,
        cellCol: start.cellCol,
        colSpan: last.cellCol - start.cellCol + 1,
        imgRow: start.imgRow,
        imgCol: start.imgCol,
      ),
    );
  }
  if (runs.isEmpty) {
    return const [];
  }

  // Stack runs that share the same columns and image columns into rectangles,
  // extending downward while screen rows and image rows stay contiguous.
  runs.sort((a, b) {
    final byImage = a.imageKey.compareTo(b.imageKey);
    if (byImage != 0) return byImage;
    if (a.cellCol != b.cellCol) return a.cellCol - b.cellCol;
    return a.cellRow - b.cellRow;
  });

  final strips = <TerminalPreviewImage>[];
  var order = 0;
  var r = 0;
  while (r < runs.length) {
    final start = runs[r];
    var end = r;
    while (end + 1 < runs.length) {
      final cur = runs[end];
      final next = runs[end + 1];
      if (identical(next.image, cur.image) &&
          next.imageKey == cur.imageKey &&
          next.cellCol == cur.cellCol &&
          next.colSpan == cur.colSpan &&
          next.imgCol == cur.imgCol &&
          next.cellRow == cur.cellRow + 1 &&
          next.imgRow == cur.imgRow + 1) {
        end++;
      } else {
        break;
      }
    }
    final last = runs[end];
    final rowSpan = last.cellRow - start.cellRow + 1;
    r = end + 1;

    final src = Rect.fromLTWH(
      start.imgCol * start.srcCellWidth,
      start.imgRow * start.srcCellHeight,
      start.colSpan * start.srcCellWidth,
      rowSpan * start.srcCellHeight,
    );
    if (src.width <= 0 || src.height <= 0) {
      continue;
    }

    strips.add(
      TerminalPreviewImage(
        image: start.image,
        src: src,
        col: start.cellCol,
        row: start.cellRow - startRow,
        colSpan: start.colSpan,
        rowSpan: rowSpan,
        order: order++,
      ),
    );
  }
  return strips;
}

/// A single horizontal run of Kitty Unicode-placeholder cells before vertical
/// runs are stacked into rectangles.
class _PreviewPlaceholderRun {
  const _PreviewPlaceholderRun({
    required this.imageKey,
    required this.image,
    required this.srcCellWidth,
    required this.srcCellHeight,
    required this.cellRow,
    required this.cellCol,
    required this.colSpan,
    required this.imgRow,
    required this.imgCol,
  });

  final String imageKey;
  final Image image;
  final double srcCellWidth;
  final double srcCellHeight;
  final int cellRow;
  final int cellCol;
  final int colSpan;
  final int imgRow;
  final int imgCol;
}

/// Stride used to pack (row, col) into a single map key. Kept in sync with
/// `monkey_terminal_view.dart`.
const int _kittyGridStride = 100003;
