import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:xterm/src/core/buffer/line.dart';

/// Optional observer invoked after each Kitty graphics decode attempt.
///
/// The app wires this to its diagnostics log to surface inflate/decode timing
/// and payload size; it stays null in tests and standalone xterm so the decode
/// path keeps no dependency on the host application.
void Function({
  required int payloadBytes,
  required int inflateMicros,
  required int decodeMicros,
  required bool compressed,
  required bool success,
})? terminalGraphicsDecodeObserver;

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
    required int fallbackCol,
    required int fallbackRow,
    this.clientPlacementId = 0,
    this.cols = 0,
    this.rows = 0,
    this.z = 0,
    this.srcX = 0,
    this.srcY = 0,
    this.srcWidth = 0,
    this.srcHeight = 0,
    this.xOffset = 0,
    this.yOffset = 0,
  })  : _fallbackCol = fallbackCol,
        _fallbackRow = fallbackRow;

  /// Internal placement id assigned by the [GraphicsManager], unique per
  /// placement and monotonically increasing (used for stable paint ordering).
  final int placementId;

  /// The id of the placed [TerminalImage].
  final int imageId;

  /// Client-assigned placement id (the Kitty `p=` key, 0 when unspecified). This
  /// — not [placementId] — is what a delete command (`a=d` with `p=`) targets.
  final int clientPlacementId;

  /// Anchor for the top-left cell of the placement.
  final CellAnchor anchor;

  final int _fallbackCol;
  final int _fallbackRow;

  /// Number of columns the image should occupy (from `c=`), or `0` to size the
  /// image from its own pixel dimensions.
  final int cols;

  /// Number of rows the image should occupy (from `r=`), or `0` to size the
  /// image from its own pixel dimensions.
  final int rows;

  /// Z-index (`z=`). Higher values stack above lower ones; negative values are
  /// drawn behind the terminal text.
  final int z;

  /// Left edge of the source rectangle within the image, in pixels (`x=`).
  final int srcX;

  /// Top edge of the source rectangle within the image, in pixels (`y=`).
  final int srcY;

  /// Width of the source rectangle in pixels (`w=`), or `0` for the full width
  /// from [srcX].
  final int srcWidth;

  /// Height of the source rectangle in pixels (`h=`), or `0` for the full height
  /// from [srcY].
  final int srcHeight;

  /// Horizontal pixel offset within the top-left cell (`X=`).
  final int xOffset;

  /// Vertical pixel offset within the top-left cell (`Y=`).
  final int yOffset;

  /// Column of the top-left cell.
  int get col => anchor.attached ? anchor.x : _fallbackCol;

  /// Absolute buffer row of the top-left cell.
  int get row => anchor.attached ? anchor.y : _fallbackRow;

  /// Whether the anchored cell is still present in the buffer.
  bool get attached => anchor.attached;

  /// Releases the underlying anchor.
  void dispose() => anchor.dispose();
}

/// A Kitty Unicode-placeholder cell that references a stored image.
class TerminalImagePlaceholder {
  TerminalImagePlaceholder({
    required this.imageId,
    required this.imageIdBitWidth,
    required this.anchor,
    required this.row,
    required this.col,
  });

  /// The referenced Kitty graphics image id.
  int imageId;

  /// Number of image-id bits encoded directly in the foreground color.
  int imageIdBitWidth;

  /// Anchor for this placeholder cell.
  final CellAnchor anchor;

  /// Row within the virtual image placement.
  int row;

  /// Column within the virtual image placement.
  int col;

  /// Column of the placeholder cell.
  int get cellCol => anchor.x;

  /// Absolute buffer row of the placeholder cell.
  int get cellRow => anchor.y;

  /// Whether the anchored cell is still present in the buffer.
  bool get attached => anchor.attached;

  /// Releases the underlying anchor.
  void dispose() => anchor.dispose();
}

/// A virtual Kitty Unicode-placeholder placement prototype.
class TerminalImageVirtualPlacement {
  TerminalImageVirtualPlacement({required this.cols, required this.rows});

  /// Number of columns the image should occupy.
  final int cols;

  /// Number of rows the image should occupy.
  final int rows;
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
  final List<TerminalImagePlaceholder> _placeholders = [];
  final Map<int, TerminalImageVirtualPlacement> _virtualPlacements = {};
  final Set<int> _retainedImageIds = {};
  // Maps a client-assigned image number (`I=`) to the most recent image id it
  // was transmitted with, so later commands can address the image by number.
  final Map<int, int> _imageNumberToId = {};

  int _nextImageId = 1;
  int _nextPlacementId = 1;
  int _generation = 0;
  int _currentMemoryBytes = 0;
  int _accessClock = 0;

  /// Active placements, oldest first.
  List<TerminalImagePlacement> get placements => _placements;

  /// Active Unicode-placeholder cells, oldest first.
  List<TerminalImagePlaceholder> get placeholders => _placeholders;

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

  /// Looks up virtual placement dimensions for [imageId].
  TerminalImageVirtualPlacement? virtualPlacementById(int imageId) =>
      _virtualPlacements[imageId];

  /// Associates a client image number (`I=`) with the [imageId] it was
  /// transmitted with. Later transmits of the same number overwrite the mapping.
  void registerImageNumber(int number, int imageId) {
    if (number > 0 && imageId > 0) {
      _imageNumberToId[number] = imageId;
    }
  }

  /// Resolves a client image number (`I=`) to its current image id, if known.
  int? imageIdForNumber(int number) => _imageNumberToId[number];

  /// Looks up an image referenced by a Kitty Unicode placeholder color.
  ///
  /// Placeholders encode the low 8 or 24 bits of the protocol image id in the
  /// foreground color, with higher bits optionally carried by combining
  /// diacritics. When that high-byte metadata is not available, fall back to the
  /// retained protocol image whose low bits match the color value.
  TerminalImage? imageByPlaceholderColorId(int id, {required int bitWidth}) {
    final direct = imageById(id);
    if (direct != null) {
      return direct;
    }

    final mask = bitWidth >= 24 ? 0xFFFFFF : 0xFF;
    TerminalImage? best;
    for (final entry in _images.entries) {
      if (!_retainedImageIds.contains(entry.key)) {
        continue;
      }
      if ((entry.key & mask) != id) {
        continue;
      }
      if (best == null || entry.value._lastAccess >= best._lastAccess) {
        best = entry.value;
      }
    }
    if (best != null) {
      best._lastAccess = ++_accessClock;
    }
    return best;
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
  ///
  /// Any existing image with [id] is replaced in place. Crucially, placements,
  /// placeholders and the virtual placement that already reference [id] are
  /// preserved: Kitty Unicode placeholders are frequently written *before* the
  /// referenced image finishes decoding, so dropping them here (as a full
  /// [_dropImage] would) leaves the freshly stored image with nothing to paint
  /// over — the cells render as bare placeholder glyphs instead of the image.
  int storeImageWithId(int id, ui.Image image) {
    if (id <= 0) {
      return storeImage(image);
    }

    final sizeBytes = image.width * image.height * 4;
    final existing = _images.remove(id);
    if (existing != null) {
      _currentMemoryBytes -= existing.sizeBytes;
    }
    _evictIfNeeded(sizeBytes);

    _images[id] = TerminalImage(id, image).._lastAccess = ++_accessClock;
    _retainedImageIds.add(id);
    _currentMemoryBytes += sizeBytes;
    if (id >= _nextImageId) {
      _nextImageId = id + 1;
    }
    return id;
  }

  /// Creates a placement of [imageId] anchored at [anchor], optionally spanning
  /// [cols] x [rows] cells, with an optional source crop, cell pixel offset and
  /// z-index.
  TerminalImagePlacement placeImage(
    int imageId,
    CellAnchor anchor, {
    int cols = 0,
    int rows = 0,
    int z = 0,
    int clientPlacementId = 0,
    int srcX = 0,
    int srcY = 0,
    int srcWidth = 0,
    int srcHeight = 0,
    int xOffset = 0,
    int yOffset = 0,
  }) {
    final placement = TerminalImagePlacement(
      placementId: _nextPlacementId++,
      imageId: imageId,
      anchor: anchor,
      fallbackCol: anchor.x,
      fallbackRow: anchor.y,
      clientPlacementId: clientPlacementId,
      cols: cols,
      rows: rows,
      z: z,
      srcX: srcX,
      srcY: srcY,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      xOffset: xOffset,
      yOffset: yOffset,
    );
    _placements.add(placement);
    return placement;
  }

  /// Records a virtual placement prototype for [imageId].
  void setVirtualPlacement(int imageId,
      {required int cols, required int rows}) {
    if (imageId <= 0 || cols <= 0 || rows <= 0) {
      return;
    }
    _virtualPlacements[imageId] = TerminalImageVirtualPlacement(
      cols: cols,
      rows: rows,
    );
    _retainedImageIds.add(imageId);
  }

  /// Adds a Kitty Unicode-placeholder cell.
  TerminalImagePlaceholder addPlaceholder({
    required int imageId,
    required int imageIdBitWidth,
    required CellAnchor anchor,
    required int row,
    required int col,
  }) {
    final placeholder = TerminalImagePlaceholder(
      imageId: imageId,
      imageIdBitWidth: imageIdBitWidth,
      anchor: anchor,
      row: row,
      col: col,
    );
    _placeholders.add(placeholder);
    return placeholder;
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

  /// Drops placeholder cells whose anchors have been evicted.
  bool pruneDetachedPlaceholders() {
    final before = _placeholders.length;
    _placeholders.removeWhere((placeholder) {
      if (placeholder.attached) return false;
      placeholder.dispose();
      return true;
    });
    return _placeholders.length != before;
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
    pruneDetachedPlaceholders();
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
    pruneDetachedPlaceholders();
    _dropUnreferencedImages();
  }

  /// Deletes physical image placements in response to a Kitty graphics delete
  /// command (`a=d`).
  ///
  /// [what] is the `d=` selector. The Kitty default, when `d=` is omitted, is
  /// `a` — every placement currently on screen. Lowercase selectors remove the
  /// matching placement(s) only; uppercase selectors additionally free the
  /// underlying image data (and, for the id form, its Unicode placeholders).
  /// Selectors target placements by image/placement id ([imageId]/[placementId]
  /// for `i`/`I`), the cursor cell ([cursorCol]/[cursorRow] for `c`/`C`), or an
  /// explicit cell, column or row ([cellCol]/[cellRow] for `p`/`P`, `x`/`X`,
  /// `y`/`Y`). Unsupported selectors delete nothing.
  ///
  /// Returns true if anything was removed.
  bool deletePlacements({
    String what = 'a',
    int? imageId,
    int? placementId,
    int? cursorCol,
    int? cursorRow,
    int? cellCol,
    int? cellRow,
  }) {
    final selector = what.isEmpty ? 'a' : what;
    final mode = selector.toLowerCase();
    final freeImages = selector != mode; // an uppercase selector frees data

    bool matches(TerminalImagePlacement placement) {
      switch (mode) {
        case 'a':
          return true;
        case 'i':
          if (imageId != null && placement.imageId != imageId) return false;
          if (placementId != null &&
              placement.clientPlacementId != placementId) {
            return false;
          }
          return true;
        case 'c':
          return cursorCol != null &&
              cursorRow != null &&
              _placementIntersectsRows(placement, cursorRow, cursorRow) &&
              _placementIntersectsCols(placement, cursorCol, cursorCol);
        case 'p':
          return cellCol != null &&
              cellRow != null &&
              _placementIntersectsRows(placement, cellRow, cellRow) &&
              _placementIntersectsCols(placement, cellCol, cellCol);
        case 'x':
          return cellCol != null &&
              _placementIntersectsCols(placement, cellCol, cellCol);
        case 'y':
          return cellRow != null &&
              _placementIntersectsRows(placement, cellRow, cellRow);
        default:
          // Unsupported selector (image number, z-index, animation frames,
          // ranges): delete nothing rather than risk wiping live images.
          return false;
      }
    }

    final freedImageIds = <int>{};
    final before = _placements.length;
    _placements.removeWhere((placement) {
      if (!matches(placement)) return false;
      freedImageIds.add(placement.imageId);
      placement.dispose();
      return true;
    });
    var changed = _placements.length != before;

    if (freeImages) {
      // The client explicitly asked to free the image data, so allow even
      // images retained for Unicode-placeholder reuse to be reclaimed.
      for (final id in freedImageIds) {
        _retainedImageIds.remove(id);
      }
      if (mode == 'i' && imageId != null) {
        // `d=I` with an id frees the image and all of its placements and
        // placeholders, whether or not a physical placement was on screen.
        if (_images.containsKey(imageId) ||
            _placeholders.any((p) => p.imageId == imageId)) {
          _dropImage(imageId);
          changed = true;
        }
      } else {
        _dropUnreferencedImages();
      }
    }

    if (changed) {
      _generation++;
    }
    return changed;
  }

  /// Removes every physical placement and drops placement-only images. Images
  /// with protocol ids are retained so Unicode-placeholder redraws can reuse
  /// them after a clear.
  void clear() {
    _generation++;
    for (final placement in _placements) {
      placement.dispose();
    }
    for (final placeholder in _placeholders) {
      placeholder.dispose();
    }
    _placements.clear();
    _placeholders.clear();
    _virtualPlacements.clear();
    for (final id in _images.keys.toList()) {
      if (!_retainedImageIds.contains(id)) {
        _dropImage(id);
      }
    }
  }

  /// Drops stored images that no longer have a placement referencing them.
  ///
  /// Retained protocol-id images (Unicode-placeholder backing) and images still
  /// referenced by a placement or placeholder cell are kept.
  void pruneUnreferencedImages() => _dropUnreferencedImages();

  /// Drops stored images that no longer have a placement referencing them.
  void _dropUnreferencedImages() {
    if (_images.isEmpty) return;
    pruneDetachedPlaceholders();
    final referenced = {
      ..._placements.map((p) => p.imageId),
      ..._placeholders.map((p) => p.imageId),
    };
    for (final id in _images.keys.toList()) {
      if (!referenced.contains(id) && !_retainedImageIds.contains(id)) {
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
    _retainedImageIds.remove(imageId);
    _virtualPlacements.remove(imageId);
    _imageNumberToId.removeWhere((_, id) => id == imageId);
    _placements.removeWhere((placement) {
      if (placement.imageId != imageId) return false;
      placement.dispose();
      return true;
    });
    _placeholders.removeWhere((placeholder) {
      if (placeholder.imageId != imageId) return false;
      placeholder.dispose();
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

/// Inflates a zlib-compressed (`o=z`) Kitty graphics payload.
///
/// Returns null if [bytes] is empty or not valid zlib data. Uses
/// `package:archive`, whose decoder works on both `dart:io` and web targets.
Uint8List? inflateZlibData(Uint8List bytes) {
  if (bytes.isEmpty) {
    return null;
  }
  try {
    // archive 3.x returns List<int>, 4.x returns Uint8List; widen to List<int>
    // and copy so this compiles cleanly against both without a type check.
    final List<int> inflated = const ZLibDecoder().decodeBytes(bytes);
    return Uint8List.fromList(inflated);
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
