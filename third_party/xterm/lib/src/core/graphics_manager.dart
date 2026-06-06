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

/// Stores decoded terminal images and their placements, with a simple cap on
/// the number of retained images.
class GraphicsManager {
  GraphicsManager({this.maxImageCount = 256});

  /// Maximum number of decoded images retained before the oldest are evicted.
  final int maxImageCount;

  final Map<int, TerminalImage> _images = {};
  final List<TerminalImagePlacement> _placements = [];

  int _nextImageId = 1;
  int _nextPlacementId = 1;

  /// Active placements, oldest first.
  List<TerminalImagePlacement> get placements => _placements;

  /// Whether any images are currently placed.
  bool get hasPlacements => _placements.isNotEmpty;

  /// Looks up a stored image by id.
  TerminalImage? imageById(int id) => _images[id];

  /// Stores [image] and returns its new id.
  int storeImage(ui.Image image) {
    final id = _nextImageId++;
    _images[id] = TerminalImage(id, image);
    _evictIfNeeded();
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
  /// or whose anchor has detached, disposing any images that become
  /// unreferenced. Used when the screen or scrollback is erased.
  void removePlacementsInRows(int firstRow, int lastRow) {
    final orphaned = <int>[];
    _placements.removeWhere((placement) {
      final remove = !placement.attached ||
          (placement.row >= firstRow && placement.row <= lastRow);
      if (remove) {
        orphaned.add(placement.imageId);
        placement.dispose();
      }
      return remove;
    });
    for (final id in orphaned) {
      if (!_placements.any((p) => p.imageId == id)) {
        _images.remove(id)?.image.dispose();
      }
    }
  }

  /// Removes every image and placement.
  void clear() {
    for (final placement in _placements) {
      placement.dispose();
    }
    _placements.clear();
    for (final image in _images.values) {
      image.image.dispose();
    }
    _images.clear();
  }

  void _evictIfNeeded() {
    while (_images.length > maxImageCount) {
      final oldestId = _images.keys.first;
      _images.remove(oldestId)?.image.dispose();
      _placements.removeWhere((placement) {
        if (placement.imageId != oldestId) return false;
        placement.dispose();
        return true;
      });
    }
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
      return await completer.future.timeout(const Duration(seconds: 5),
          onTimeout: () => throw 'timeout');
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
