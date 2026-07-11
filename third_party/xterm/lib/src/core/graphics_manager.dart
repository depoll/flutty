import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/async_semaphore.dart';

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
  String? imageId,
  String? action,
  bool? reused,
})? terminalGraphicsDecodeObserver;

/// Bounds all terminal image decodes across eager and deferred graphics paths.
final AsyncSemaphore terminalGraphicsDecodeGate = AsyncSemaphore(3);

/// A decoded image retained for the Kitty graphics protocol.
class TerminalImage {
  TerminalImage(this.id, this.image, {this.sourceSignature = 0});

  /// Image id assigned by the [GraphicsManager].
  final int id;

  /// The decoded image.
  final ui.Image image;

  /// A cheap hash of the source payload this image was decoded from. Used to
  /// skip re-decoding when the same id is transmitted again with identical
  /// bytes (e.g. MonkeyMux replays cached images on every window switch).
  /// Zero means "unknown" and never matches an incoming signature.
  final int sourceSignature;

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

/// A transmitted-but-not-yet-decoded image, held so its decode can be deferred
/// until something actually needs to paint it.
///
/// A MonkeyMux window switch replays every retained Kitty image up front
/// (store-only, `a=t`), but a foreground app such as the Copilot CLI only
/// re-emits placeholder cells for the few images currently on screen. Decoding
/// all store-only images eagerly wastes CPU, memory and raster bandwidth on
/// images the user never sees; keeping the encoded payload and decoding on first
/// reference bounds the work to the visible set.
class _PendingGraphicsImage {
  _PendingGraphicsImage({
    required this.payload,
    required this.format,
    required this.width,
    required this.height,
    required this.sourceSignature,
  });

  final Uint8List payload;
  final int format;
  final int width;
  final int height;
  final int sourceSignature;
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
  // Encoded images awaiting a first paint reference (see [_PendingGraphicsImage]
  // and [storePendingImage]). Insertion-ordered so the oldest can be evicted.
  final Map<int, _PendingGraphicsImage> _pendingImages = {};
  final Set<int> _decodingIds = {};
  // Maps a client-assigned image number (`I=`) to the most recent image id it
  // was transmitted with, so later commands can address the image by number.
  final Map<int, int> _imageNumberToId = {};

  /// Invoked after a deferred image finishes decoding so the host can repaint.
  /// The [Terminal] wires this to `notifyListeners`; it stays null in tests and
  /// standalone xterm.
  void Function()? onChanged;

  /// Bounds the encoded bytes retained for not-yet-decoded images. Small
  /// relative to the decoded-image budget because encoded payloads are far
  /// smaller than their RGBA bitmaps.
  static const int _maxPendingBytes = 64 * 1024 * 1024;

  /// Bounds the number of not-yet-decoded images retained.
  static const int _maxPendingImages = 128;

  int _pendingBytes = 0;

  int _nextImageId = 1;
  int _nextPlacementId = 1;
  int _generation = 0;
  int _currentMemoryBytes = 0;
  int _accessClock = 0;

  /// Active placements, oldest first.
  List<TerminalImagePlacement> get placements => _placements;

  /// Active Unicode-placeholder cells, oldest first.
  List<TerminalImagePlaceholder> get placeholders => _placeholders;

  /// The `{imageId: sourceSignature}` of every image the client is guaranteed to
  /// still hold after a window switch — retained decoded images and pending
  /// (transmitted but not yet decoded) ones.
  ///
  /// Reported to the MonkeyMux server on a window switch so it can omit
  /// re-transmitting images the client already has, sparing the client from
  /// re-parsing several megabytes of image data it would immediately discard as
  /// a duplicate. The signature disambiguates content, so a different window
  /// that reuses the same protocol id for different bytes is never skipped.
  ///
  /// Only images that survive [clear] are reported. A window switch replays
  /// `CSI ? 1049 h`, which clears the screen and drops every decoded image that
  /// is not retained (i.e. a physical `a=T` placement rather than a
  /// Unicode-placeholder virtual image). Reporting such an image would let the
  /// server skip re-transmitting it, and then the switch's own clear would drop
  /// it — leaving the redrawn cells with no image to composite (blank until the
  /// app fully redraws). Pending images survive the clear untouched, so they are
  /// always safe to report.
  Map<int, int> heldImageSignatures() {
    final result = <int, int>{};
    for (final entry in _images.entries) {
      if (!_retainedImageIds.contains(entry.key)) {
        continue;
      }
      final signature = entry.value.sourceSignature;
      if (signature != 0) {
        result[entry.key] = signature;
      }
    }
    for (final entry in _pendingImages.entries) {
      final signature = entry.value.sourceSignature;
      if (signature != 0) {
        result[entry.key] = signature;
      }
    }
    return result;
  }

  /// Protocol image ids referenced by attached Kitty Unicode-placeholder cells
  /// that resolve to no stored or pending image.
  ///
  /// The foreground app has drawn placeholder cells for these images, but their
  /// bytes were never received (or have been evicted) — for example when a
  /// window switch replay is bounded and drops images the app still shows, or a
  /// reconnect replays fewer images than the app references. Such placeholders
  /// render blank until the bytes arrive. A caller can ask the MonkeyMux server
  /// to replay exactly these ids from its per-window retained cache.
  ///
  /// Pending (transmitted but not yet decoded) ids are treated as resolvable and
  /// excluded: their bytes are already in flight. The result is de-duplicated by
  /// image id, so a full-screen image made of hundreds of placeholder cells
  /// contributes a single id.
  Set<int> unresolvedPlaceholderImageIds() {
    if (_placeholders.isEmpty) {
      return const <int>{};
    }
    final unresolved = <int>{};
    final resolvable = <int>{};
    for (final placeholder in _placeholders) {
      if (!placeholder.attached) {
        continue;
      }
      final id = placeholder.imageId;
      if (id <= 0 || unresolved.contains(id) || resolvable.contains(id)) {
        continue;
      }
      if (_canResolvePlaceholderId(id, placeholder.imageIdBitWidth)) {
        resolvable.add(id);
      } else {
        unresolved.add(id);
      }
    }
    return unresolved;
  }

  /// Whether a placeholder color [id] maps to any stored or pending image,
  /// directly or via the low-bit masked fallback used by
  /// [imageByPlaceholderColorId]. Unlike that method this never starts a decode,
  /// so it is safe to call while merely probing for missing images.
  bool _canResolvePlaceholderId(int id, int bitWidth) {
    if (_images.containsKey(id) || _pendingImages.containsKey(id)) {
      return true;
    }
    final mask = bitWidth >= 24 ? 0xFFFFFF : 0xFF;
    for (final key in _images.keys) {
      if (_retainedImageIds.contains(key) && (key & mask) == id) {
        return true;
      }
    }
    for (final key in _pendingImages.keys) {
      if ((key & mask) == id) {
        return true;
      }
    }
    return false;
  }

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
  ///
  /// If the referenced image is still pending (transmitted but not decoded), its
  /// decode is started and null is returned; the caller (renderer) paints
  /// nothing this frame and repaints via [onChanged] once the decode completes.
  TerminalImage? imageByPlaceholderColorId(int id, {required int bitWidth}) {
    final direct = imageById(id);
    if (direct != null) {
      return direct;
    }
    if (_pendingImages.containsKey(id)) {
      unawaited(_beginDecode(id));
      return null;
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
      return best;
    }

    // No decoded image matches; a pending one whose low bits match must be
    // decoded before it can be composited.
    int? pendingMatch;
    for (final pendingId in _pendingImages.keys) {
      if ((pendingId & mask) == id) {
        pendingMatch = pendingId; // keep scanning: newest insertion wins
      }
    }
    if (pendingMatch != null) {
      unawaited(_beginDecode(pendingMatch));
    }
    return null;
  }

  /// Resolves a placement's image for painting, starting a deferred decode if
  /// the image is pending. Returns null (paint nothing this frame) until the
  /// decode completes and triggers a repaint via [onChanged].
  TerminalImage? imageForPlacement(int id) {
    final image = imageById(id);
    if (image != null) {
      return image;
    }
    if (_pendingImages.containsKey(id)) {
      unawaited(_beginDecode(id));
    }
    return null;
  }

  /// Whether image [id] has been transmitted but not yet decoded.
  bool hasPendingImage(int id) => _pendingImages.containsKey(id);

  /// Whether a pending (undecoded) image [id] carries a matching
  /// [sourceSignature], so a replay can skip re-storing identical bytes. A zero
  /// signature never matches.
  bool hasPendingWithSignature(int id, int sourceSignature) {
    if (id <= 0 || sourceSignature == 0) {
      return false;
    }
    final pending = _pendingImages[id];
    return pending != null && pending.sourceSignature == sourceSignature;
  }

  /// Retains an encoded image for [id] without decoding it, to be decoded on
  /// first paint reference. See [_PendingGraphicsImage].
  void storePendingImage(
    int id, {
    required Uint8List payload,
    required int format,
    int width = 0,
    int height = 0,
    int sourceSignature = 0,
  }) {
    if (id <= 0) {
      return;
    }
    // Already decoded from identical bytes: nothing to defer.
    if (hasImageWithSignature(id, sourceSignature)) {
      return;
    }
    // New bytes for an id whose previous image is already decoded supersede it;
    // drop the stale bitmap (keeping any placements/placeholders that reference
    // the id) so the deferred decode of the new bytes is what gets painted.
    final stale = _images.remove(id);
    if (stale != null) {
      _currentMemoryBytes -= stale.sizeBytes;
    }
    final existing = _pendingImages.remove(id);
    if (existing != null) {
      _pendingBytes -= existing.payload.length;
    }
    _pendingImages[id] = _PendingGraphicsImage(
      payload: payload,
      format: format,
      width: width,
      height: height,
      sourceSignature: sourceSignature,
    );
    _pendingBytes += payload.length;
    if (id >= _nextImageId) {
      _nextImageId = id + 1;
    }
    _evictPendingIfNeeded();
  }

  void _evictPendingIfNeeded() {
    while (_pendingImages.isNotEmpty &&
        (_pendingBytes > _maxPendingBytes ||
            _pendingImages.length > _maxPendingImages)) {
      final oldest = _pendingImages.keys.first;
      final removed = _pendingImages.remove(oldest);
      if (removed != null) {
        _pendingBytes -= removed.payload.length;
      }
      // The image bytes are gone, so its virtual placement (if any) can no
      // longer back a placeholder; drop it unless a decoded image kept the id.
      if (!_images.containsKey(oldest)) {
        _virtualPlacements.remove(oldest);
      }
    }
  }

  Future<void> _beginDecode(int id) async {
    if (_decodingIds.contains(id)) {
      return;
    }
    final pending = _pendingImages[id];
    if (pending == null) {
      return;
    }
    _decodingIds.add(id);
    final observer = terminalGraphicsDecodeObserver;
    final stopwatch = observer == null ? null : (Stopwatch()..start());
    ui.Image? image;
    await terminalGraphicsDecodeGate.acquire();
    try {
      image = await decodeTerminalImage(
        pending.payload,
        format: pending.format,
        width: pending.width,
        height: pending.height,
      );
    } finally {
      terminalGraphicsDecodeGate.release();
      _decodingIds.remove(id);
    }

    // The pending entry may have been evicted, deleted (`a=d`) or replaced with
    // fresh bytes while decoding; only commit when it is still the same image.
    if (!identical(_pendingImages[id], pending)) {
      return;
    }
    observer?.call(
      payloadBytes: pending.payload.length,
      inflateMicros: 0,
      decodeMicros: stopwatch?.elapsedMicroseconds ?? 0,
      compressed: false,
      success: image != null,
      imageId: id.toString(),
      action: 'lazy',
      reused: false,
    );
    _pendingImages.remove(id);
    _pendingBytes -= pending.payload.length;
    if (image == null) {
      return;
    }
    storeImageWithId(id, image, sourceSignature: pending.sourceSignature);
    onChanged?.call();
  }

  /// Stores [image] and returns its new id.
  int storeImage(ui.Image image, {int sourceSignature = 0}) {
    final sizeBytes = image.width * image.height * 4;
    _evictIfNeeded(sizeBytes);

    final id = _nextImageId++;
    _images[id] = TerminalImage(id, image, sourceSignature: sourceSignature)
      .._lastAccess = ++_accessClock;
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
  int storeImageWithId(int id, ui.Image image, {int sourceSignature = 0}) {
    if (id <= 0) {
      return storeImage(image, sourceSignature: sourceSignature);
    }

    final sizeBytes = image.width * image.height * 4;
    final existing = _images.remove(id);
    if (existing != null) {
      _currentMemoryBytes -= existing.sizeBytes;
    }
    _evictIfNeeded(sizeBytes);

    _images[id] = TerminalImage(id, image, sourceSignature: sourceSignature)
      .._lastAccess = ++_accessClock;
    _retainedImageIds.add(id);
    _currentMemoryBytes += sizeBytes;
    if (id >= _nextImageId) {
      _nextImageId = id + 1;
    }
    return id;
  }

  /// Whether image [id] is already stored with a matching [sourceSignature].
  ///
  /// Lets the transmit path skip re-decoding an identical image that the same
  /// id was already decoded from (e.g. a window switch replaying cached images
  /// the client still holds). A zero signature never matches.
  bool hasImageWithSignature(int id, int sourceSignature) {
    if (id <= 0 || sourceSignature == 0) {
      return false;
    }
    final existing = _images[id];
    return existing != null && existing.sourceSignature == sourceSignature;
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
    for (final id in _images.keys.toList()) {
      if (!_retainedImageIds.contains(id)) {
        _dropImage(id);
      }
    }
    // Keep virtual placements for images that survive the clear (retained
    // decoded images and not-yet-decoded pending ones). A virtual placement
    // records how a retained image maps onto Unicode-placeholder cells
    // (its cell columns/rows), and a placeholder-protocol app such as the
    // Copilot CLI redraws only the placeholder cells after a clear/reattach —
    // it never re-transmits the image or its virtual placement. Entering the
    // alternate screen (`CSI ? 1049 h`, part of the MonkeyMux reattach replay)
    // calls clear(); wiping the virtual placements here left the painter to
    // guess the image grid from the visible cells and mis-slice it. Dropped
    // images already had their virtual placement removed by [_dropImage].
    _virtualPlacements.removeWhere(
      (id, _) =>
          !_retainedImageIds.contains(id) && !_pendingImages.containsKey(id),
    );
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
    final pending = _pendingImages.remove(imageId);
    if (pending != null) {
      _pendingBytes -= pending.payload.length;
    }
    _decodingIds.remove(imageId);
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

/// Computes a cheap, stable signature of an image payload for dedup and for the
/// window-switch replay skip protocol.
///
/// Used to skip re-decoding an identical image (same id, same bytes) that a
/// window switch replays, and — reported to the MonkeyMux server — to let the
/// server omit re-transmitting images the client already holds. Not
/// cryptographic: a collision merely causes a redundant decode (or, for the skip
/// protocol, a rare re-send), never corruption.
///
/// FNV-1a over 32 bits (so it stays within a Dart small-int and matches a Go
/// `uint32` exactly, with no signed-shift ambiguity across languages), mixing
/// the exact length plus an evenly-spaced sample of bytes (<= ~4096) rather than
/// every byte to stay fast on very large payloads. The server computes the same
/// hash over the base64-decoded transmission payload, so both sides must keep
/// the algorithm identical. Returns a non-zero value for non-empty input.
int terminalGraphicsSourceSignature(Uint8List bytes) {
  if (bytes.isEmpty) {
    return 0;
  }
  const fnvOffset = 0x811c9dc5;
  const fnvPrime = 0x01000193;
  const mask = 0xFFFFFFFF;
  var hash = fnvOffset;
  // Mix the exact length (little-endian bytes) so payloads that share a sample
  // but differ in length still diverge.
  var length = bytes.length;
  for (var i = 0; i < 4; i++) {
    hash = ((hash ^ (length & 0xFF)) * fnvPrime) & mask;
    length >>= 8;
  }
  final step = bytes.length <= 4096 ? 1 : bytes.length ~/ 4096;
  for (var i = 0; i < bytes.length; i += step) {
    hash = ((hash ^ bytes[i]) * fnvPrime) & mask;
  }
  return hash == 0 ? 1 : hash;
}

/// Maximum width/height a decoded terminal image is kept at. Source images
/// larger than this on their longest side are downscaled during decode, with
/// aspect ratio preserved. A terminal renders images into a small cell grid, so
/// full-resolution screenshots (often several megapixels) waste large amounts of
/// decoded RGBA memory and raster bandwidth; on mobile, decoding many at once
/// can exhaust memory and crash. 1280px keeps images crisp at terminal sizes
/// while bounding each decode to ~6.5 MB.
const _maxDecodedImageDimension = 1280;

/// Decodes Kitty graphics payload [bytes] into a [ui.Image].
///
/// Uses Flutter's built-in codecs for `f=100`/`f=98` (PNG/JPEG/GIF first frame)
/// and [ui.decodeImageFromPixels] for raw pixels (`f=32` RGBA, `f=24` RGB).
/// Encoded images larger than [_maxDecodedImageDimension] are downscaled during
/// decode to bound memory. Returns null on any failure rather than throwing.
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
    return await _decodeEncodedImageBounded(bytes);
  } catch (_) {
    return null;
  }
}

/// Decodes an encoded image (PNG/JPEG/GIF), downscaling to
/// [_maxDecodedImageDimension] on its longest side when larger.
Future<ui.Image?> _decodeEncodedImageBounded(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final srcWidth = descriptor.width;
    final srcHeight = descriptor.height;
    int? targetWidth;
    int? targetHeight;
    final longest = srcWidth > srcHeight ? srcWidth : srcHeight;
    if (longest > _maxDecodedImageDimension && longest > 0) {
      final scale = _maxDecodedImageDimension / longest;
      targetWidth =
          (srcWidth * scale).round().clamp(1, _maxDecodedImageDimension);
      targetHeight = (srcHeight * scale).round().clamp(
            1,
            _maxDecodedImageDimension,
          );
    }
    final codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
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
