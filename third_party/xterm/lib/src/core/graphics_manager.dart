import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:xterm/src/core/buffer/line.dart';

/// A decoded image retained for the Kitty graphics protocol.
class TerminalImage {
  TerminalImage(this.id, this.image);

  /// Image id assigned by the [GraphicsManager].
  final int id;

  /// The decoded image.
  final ui.Image image;

  /// Approximate size of the decoded image in bytes (RGBA).
  int get sizeBytes => image.width * image.height * 4;

  int _lastAccess = 0;
}

/// A placement of a [TerminalImage] anchored to a cell in the buffer.
///
/// The placement is anchored with a [CellAnchor] so it tracks its cell across
/// scrollback and reflow, and detaches when that cell is evicted.
class TerminalImagePlacement {
  TerminalImagePlacement({
    required this.placementId,
    required this.imageId,
    required this.anchor,
    this.cols = 0,
    this.rows = 0,
  });

  /// Placement id assigned by the [GraphicsManager].
  final int placementId;

  /// The id of the placed [TerminalImage].
  final int imageId;

  /// Anchor for the top-left cell of the placement.
  final CellAnchor anchor;

  /// Number of columns the image should occupy (from `c=`), or `0` to size the
  /// image from its own pixel dimensions.
  final int cols;

  /// Number of rows the image should occupy (from `r=`), or `0` to size the
  /// image from its own pixel dimensions.
  final int rows;

  /// Column of the top-left cell.
  int get col => anchor.x;

  /// Absolute buffer row of the top-left cell.
  int get row => anchor.y;

  /// Whether the anchored cell is still present in the buffer.
  bool get attached => anchor.attached;

  /// Releases the underlying anchor.
  void dispose() => anchor.dispose();
}

/// Stores decoded terminal images and their placements with count and memory
/// caps.
class GraphicsManager {
  GraphicsManager({
    this.maxImageCount = 256,
    this.maxMemoryBytes = 100 * 1024 * 1024,
  });

  /// Maximum number of decoded images retained before the oldest are evicted.
  final int maxImageCount;

  /// Maximum approximate decoded image memory retained before LRU eviction.
  final int maxMemoryBytes;

  final Map<int, TerminalImage> _images = {};
  final List<TerminalImagePlacement> _placements = [];

  int _nextImageId = 1;
  int _nextPlacementId = 1;
  int _generation = 0;
  int _currentMemoryBytes = 0;
  int _accessClock = 0;

  /// Active placements, oldest first.
  List<TerminalImagePlacement> get placements => _placements;

  /// Approximate decoded image memory currently retained.
  int get currentMemoryBytes => _currentMemoryBytes;

  /// Number of decoded images currently retained.
  int get imageCount => _images.length;

  /// Whether any images are currently placed.
  bool get hasPlacements => _placements.isNotEmpty;

  /// Bumped whenever placements are cleared. An asynchronous image decode
  /// captures this before it starts and skips placing if it changed, so a clear
  /// that races an in-flight decode cannot leave a stale image behind.
  int get generation => _generation;

  /// Looks up a stored image by id.
  TerminalImage? imageById(int id) {
    final image = _images[id];
    if (image != null) {
      image._lastAccess = ++_accessClock;
    }
    return image;
  }

  /// Stores [image] and returns its new id.
  int storeImage(ui.Image image) {
    final sizeBytes = image.width * image.height * 4;
    _evictIfNeeded(sizeBytes);

    final id = _nextImageId++;
    _images[id] = TerminalImage(id, image).._lastAccess = ++_accessClock;
    _currentMemoryBytes += sizeBytes;
    return id;
  }

  /// Stores [image] using an id supplied by the Kitty graphics protocol.
  int storeImageWithId(int id, ui.Image image) {
    if (id <= 0) {
      return storeImage(image);
    }

    final sizeBytes = image.width * image.height * 4;
    _dropImage(id);
    _evictIfNeeded(sizeBytes);

    _images[id] = TerminalImage(id, image).._lastAccess = ++_accessClock;
    _currentMemoryBytes += sizeBytes;
    if (id >= _nextImageId) {
      _nextImageId = id + 1;
    }
    return id;
  }

  /// Creates a placement of [imageId] anchored at [anchor], optionally spanning
  /// [cols] x [rows] cells.
  TerminalImagePlacement placeImage(
    int imageId,
    CellAnchor anchor, {
    int cols = 0,
    int rows = 0,
  }) {
    final placement = TerminalImagePlacement(
      placementId: _nextPlacementId++,
      imageId: imageId,
      anchor: anchor,
      cols: cols,
      rows: rows,
    );
    _placements.add(placement);
    return placement;
  }

  /// Drops placements whose anchor cell has been evicted from the buffer.
  ///
  /// Returns true if any placement was removed.
  bool pruneDetachedPlacements() {
    final before = _placements.length;
    _placements.removeWhere((placement) {
      if (placement.attached) return false;
      placement.dispose();
      return true;
    });
    return _placements.length != before;
  }

  /// Removes placements anchored within rows `[firstRow, lastRow]` (inclusive),
  /// or whose anchor has detached. Used when the screen or scrollback is erased.
  ///
  /// The decoded [ui.Image]s are intentionally *not* disposed here. A placement
  /// that was painted in a still-in-flight frame would otherwise have its image
  /// freed out from under the raster thread, which crashes the engine ("Cannot
  /// draw a disposed image"). Dropping the references is enough: any picture
  /// that already drew the image keeps its own reference alive, and the image is
  /// reclaimed by the GC finalizer once nothing can paint it.
  void removePlacementsInRows(int firstRow, int lastRow) {
    final before = _placements.length;
    _placements.removeWhere((placement) {
      final remove = !placement.attached ||
          _placementIntersectsRows(placement, firstRow, lastRow);
      if (remove) {
        placement.dispose();
      }
      return remove;
    });
    if (_placements.length != before) {
      _generation++;
    }
    _dropUnreferencedImages();
  }

  /// Removes placements intersecting the rectangular cell region whose rows and
  /// columns are inclusive. Used by partial erases (`CSI J/K/X`) so an image
  /// does not remain painted over cells the terminal just cleared.
  void removePlacementsInRegion(
    int firstRow,
    int lastRow,
    int firstCol,
    int lastCol,
  ) {
    final before = _placements.length;
    _placements.removeWhere((placement) {
      final remove = !placement.attached ||
          (_placementIntersectsRows(placement, firstRow, lastRow) &&
              _placementIntersectsCols(placement, firstCol, lastCol));
      if (remove) {
        placement.dispose();
      }
      return remove;
    });
    if (_placements.length != before) {
      _generation++;
    }
    _dropUnreferencedImages();
  }

  /// Removes every image and placement. The decoded images are dropped rather
  /// than disposed; see [removePlacementsInRows] for why.
  void clear() {
    _generation++;
    for (final placement in _placements) {
      placement.dispose();
    }
    _placements.clear();
    _images.clear();
    _currentMemoryBytes = 0;
  }

  /// Drops stored images that no longer have a placement referencing them.
  void _dropUnreferencedImages() {
    if (_images.isEmpty) return;
    final referenced = _placements.map((p) => p.imageId).toSet();
    for (final id in _images.keys.toList()) {
      if (!referenced.contains(id)) {
        _dropImage(id);
      }
    }
  }

  bool _placementIntersectsRows(
    TerminalImagePlacement placement,
    int firstRow,
    int lastRow,
  ) {
    final rows = placement.rows > 0 ? placement.rows : 1;
    final placementFirst = placement.row;
    final placementLast = placementFirst + rows - 1;
    return placementFirst <= lastRow && placementLast >= firstRow;
  }

  bool _placementIntersectsCols(
    TerminalImagePlacement placement,
    int firstCol,
    int lastCol,
  ) {
    final cols = placement.cols > 0 ? placement.cols : 1;
    final placementFirst = placement.col;
    final placementLast = placementFirst + cols - 1;
    return placementFirst <= lastCol && placementLast >= firstCol;
  }

  void _evictIfNeeded(int requiredBytes) {
    if (_images.isEmpty) return;

    final highWaterMemory = (maxMemoryBytes * 0.7).toInt();
    if (_currentMemoryBytes + requiredBytes <= highWaterMemory &&
        _images.length < maxImageCount) {
      return;
    }

    final targetMemory = (maxMemoryBytes * 0.5).toInt();
    while (_images.isNotEmpty &&
        (_currentMemoryBytes + requiredBytes > targetMemory ||
            _images.length >= maxImageCount)) {
      final oldest = _images.entries.reduce((a, b) {
        return a.value._lastAccess <= b.value._lastAccess ? a : b;
      });
      _dropImage(oldest.key);
    }
  }

  void _dropImage(int imageId) {
    final image = _images.remove(imageId);
    if (image != null) {
      _currentMemoryBytes -= image.sizeBytes;
    }
    _placements.removeWhere((placement) {
      if (placement.imageId != imageId) return false;
      placement.dispose();
      return true;
    });
  }
}

/// Decodes Kitty graphics payload [bytes] into a [ui.Image].
///
/// Uses Flutter's built-in codecs for `f=100`/`f=98` (PNG/JPEG/GIF first frame)
/// and [ui.decodeImageFromPixels] for raw pixels (`f=32` RGBA, `f=24` RGB).
/// Returns null on any failure rather than throwing.
Future<ui.Image?> decodeTerminalImage(
  Uint8List bytes, {
  int format = 100,
  int width = 0,
  int height = 0,
}) async {
  if (bytes.isEmpty) return null;
  try {
    if (format == 32 || format == 24) {
      if (width <= 0 || height <= 0) return null;
      final rgba = format == 24 ? _rgbToRgba(bytes) : bytes;
      if (rgba.length < width * height * 4) return null;
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw 'timeout',
      );
    }
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

Uint8List _rgbToRgba(Uint8List rgb) {
  final pixels = rgb.length ~/ 3;
  final rgba = Uint8List(pixels * 4);
  for (var i = 0; i < pixels; i++) {
    rgba[i * 4] = rgb[i * 3];
    rgba[i * 4 + 1] = rgb[i * 3 + 1];
    rgba[i * 4 + 2] = rgb[i * 3 + 2];
    rgba[i * 4 + 3] = 0xFF;
  }
  return rgba;
}
