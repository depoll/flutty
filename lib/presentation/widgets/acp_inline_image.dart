import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';

/// Maximum number of decoded bytes [AcpInlineImage] will accept for inline
/// display before rejecting the input.
///
/// Exposed so attachment/composer controllers can enforce the same ceiling
/// when deciding whether to inline an image or fall back to a resource link.
const int kAcpMaxInlineImageBytes = 10 * 1024 * 1024; // 10 MiB

/// Default decode dimension (in pixels) applied to the longer image edge when
/// no explicit decode hint is present, to bound decode memory.
const int kAcpDefaultImageDecodeDimension = 1080;

/// Upper bound applied to the longer target edge, so no decode hint (or
/// intrinsic size) can exceed it.
const int kAcpMaxImageDecodeDimension = 4096;

/// Maximum number of pixels in the *decoded* bitmap. Both target dimensions
/// are scaled down together (preserving aspect ratio) so their product never
/// exceeds this bound.
const int kAcpMaxImageDecodePixels = 4096 * 4096; // ~16.7 MP

/// Maximum intrinsic pixel count accepted from the encoded header. Larger
/// declared dimensions are treated as a decompression bomb and rejected before
/// any decode is attempted.
const int kAcpMaxDecodableSourcePixels = 100 * 1000 * 1000; // 100 MP

/// Resolves an [AcpImageContent] that is not already in memory (e.g. a
/// `file:` or `http(s):` URI) to raw bytes.
///
/// Returning `null` signals that the image could not be resolved. No network
/// or filesystem access is performed by [AcpInlineImage] itself; a resolver
/// must be supplied for non-inline sources.
typedef AcpImageResolver = Future<Uint8List?> Function(AcpImageContent image);

/// Renders an inline image from in-memory bytes, a `data:` URI, or a
/// caller-resolved `file:`/`http(s):` URI, inside a bounded, rounded frame.
///
/// Network and file URIs are only fetched when a [resolver] is provided; there
/// is no implicit network access. Byte payloads larger than [maxBytes] are
/// rejected before decoding. The encoded header's intrinsic dimensions are
/// inspected (via [ui.ImageDescriptor]) before decoding so that *both* target
/// dimensions are bounded — the longer edge to [kAcpMaxImageDecodeDimension]
/// and the total decoded pixels to [kAcpMaxImageDecodePixels] — while
/// preserving aspect ratio. Non-positive decode hints and decompression-bomb
/// dimensions surface as accessible error placeholders. Stale asynchronous
/// completions can never overwrite a newer image (generation guarded).
class AcpInlineImage extends StatefulWidget {
  /// Creates an inline image.
  const AcpInlineImage({
    required this.image,
    super.key,
    this.resolver,
    this.onTap,
    this.maxWidth = 360,
    this.maxHeight = 260,
    this.maxBytes = kAcpMaxInlineImageBytes,
    this.defaultDecodeDimension = kAcpDefaultImageDecodeDimension,
  });

  /// The image to render.
  final AcpImageContent image;

  /// Resolves non-inline images to bytes; required for file/network URIs.
  final AcpImageResolver? resolver;

  /// Called when the image is tapped (e.g. to open a full-screen viewer).
  final ValueChanged<AcpImageContent>? onTap;

  /// Maximum rendered width.
  final double maxWidth;

  /// Maximum rendered height.
  final double maxHeight;

  /// Maximum accepted decoded byte length; larger payloads are rejected.
  final int maxBytes;

  /// Longer-edge decode budget applied when [AcpImageContent] carries no hint.
  final int defaultDecodeDimension;

  @override
  State<AcpInlineImage> createState() => _AcpInlineImageState();
}

enum _ImageState { loading, ready, needsResolver, error, tooLarge }

/// Outcome of inspecting the encoded header and computing decode targets.
enum _DecodeOutcome { ok, invalid, bomb }

class _AcpInlineImageState extends State<AcpInlineImage> {
  _ImageState _state = _ImageState.loading;
  Uint8List? _bytes;
  int? _decodeWidth;
  int? _decodeHeight;

  // Monotonic guard so stale async completions from a previous image or
  // resolver cannot overwrite the current one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AcpInlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.resolver != widget.resolver ||
        oldWidget.maxBytes != widget.maxBytes ||
        oldWidget.defaultDecodeDimension != widget.defaultDecodeDimension) {
      _resolve();
    }
  }

  bool _withinLimit(int byteLength) => byteLength <= widget.maxBytes;

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _set(_ImageState state, {Uint8List? bytes, int? width, int? height}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _state = state;
      _bytes = bytes;
      _decodeWidth = width;
      _decodeHeight = height;
    });
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    final image = widget.image;

    // Validate decode hints synchronously: hints must be positive.
    final hintW = image.decodeWidth;
    final hintH = image.decodeHeight;
    if ((hintW != null && hintW <= 0) || (hintH != null && hintH <= 0)) {
      _set(_ImageState.error);
      return;
    }

    final Uint8List? bytes;
    switch (image.sourceKind) {
      case AcpImageSourceKind.bytes:
        bytes = image.bytes;
      case AcpImageSourceKind.dataUri:
        bytes = _decodeDataUriBytes(image.uri!);
      case AcpImageSourceKind.fileUri:
      case AcpImageSourceKind.networkUri:
        bytes = await _resolveBytes(image, generation);
    }
    if (!_isCurrent(generation) || bytes == null) {
      return;
    }
    if (!_withinLimit(bytes.length)) {
      _set(_ImageState.tooLarge);
      return;
    }
    await _decodeAndReady(bytes, image, generation);
  }

  Uint8List? _decodeDataUriBytes(String uri) {
    try {
      // Cheap pre-decode guard: a base64 data URI decodes to roughly 3/4 of
      // its encoded length, so reject clearly oversized input before paying
      // for the base64 decode.
      if ((uri.length * 3) ~/ 4 > widget.maxBytes) {
        _set(_ImageState.tooLarge);
        return null;
      }
      final data = Uri.parse(uri).data;
      final bytes = data?.contentAsBytes();
      if (bytes == null || bytes.isEmpty) {
        _set(_ImageState.error);
        return null;
      }
      return bytes;
    } on Object {
      _set(_ImageState.error);
      return null;
    }
  }

  Future<Uint8List?> _resolveBytes(
    AcpImageContent image,
    int generation,
  ) async {
    final resolver = widget.resolver;
    if (resolver == null) {
      _set(_ImageState.needsResolver);
      return null;
    }
    _set(_ImageState.loading);
    try {
      final bytes = await resolver(image);
      if (!_isCurrent(generation)) {
        return null;
      }
      if (bytes == null || bytes.isEmpty) {
        _set(_ImageState.error);
        return null;
      }
      return bytes;
    } on Object {
      if (_isCurrent(generation)) {
        _set(_ImageState.error);
      }
      return null;
    }
  }

  Future<void> _decodeAndReady(
    Uint8List bytes,
    AcpImageContent image,
    int generation,
  ) async {
    final target = await _computeDecodeTarget(bytes, image);
    if (!_isCurrent(generation)) {
      return;
    }
    switch (target.outcome) {
      case _DecodeOutcome.bomb:
        _set(_ImageState.tooLarge);
      case _DecodeOutcome.invalid:
        _set(_ImageState.error);
      case _DecodeOutcome.ok:
        _set(
          _ImageState.ready,
          bytes: bytes,
          width: target.width,
          height: target.height,
        );
    }
  }

  Future<({_DecodeOutcome outcome, int width, int height})>
  _computeDecodeTarget(Uint8List bytes, AcpImageContent image) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final intrinsicWidth = descriptor.width;
      final intrinsicHeight = descriptor.height;
      if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
        return (outcome: _DecodeOutcome.invalid, width: 0, height: 0);
      }
      if (intrinsicWidth * intrinsicHeight > kAcpMaxDecodableSourcePixels) {
        return (outcome: _DecodeOutcome.bomb, width: 0, height: 0);
      }
      final (width, height) = _targetDimensions(
        intrinsicWidth,
        intrinsicHeight,
        image,
      );
      return (outcome: _DecodeOutcome.ok, width: width, height: height);
    } on Object {
      return (outcome: _DecodeOutcome.invalid, width: 0, height: 0);
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// Computes bounded decode dimensions that preserve the intrinsic aspect
  /// ratio. The longer edge is capped to the hint-or-default budget (never
  /// exceeding [kAcpMaxImageDecodeDimension]) and the total is further scaled
  /// so it never exceeds [kAcpMaxImageDecodePixels].
  (int, int) _targetDimensions(
    int intrinsicWidth,
    int intrinsicHeight,
    AcpImageContent image,
  ) {
    final hintW = image.decodeWidth;
    final hintH = image.decodeHeight;
    var budget = (hintW == null && hintH == null)
        ? widget.defaultDecodeDimension
        : math.max(hintW ?? 0, hintH ?? 0);
    budget = math.min(budget, kAcpMaxImageDecodeDimension);
    if (budget <= 0) {
      budget = math.min(
        widget.defaultDecodeDimension,
        kAcpMaxImageDecodeDimension,
      );
    }

    final longerEdge = math.max(intrinsicWidth, intrinsicHeight);
    var scale = longerEdge > budget ? budget / longerEdge : 1.0;

    final scaledPixels = (intrinsicWidth * scale) * (intrinsicHeight * scale);
    if (scaledPixels > kAcpMaxImageDecodePixels) {
      scale *= math.sqrt(kAcpMaxImageDecodePixels / scaledPixels);
    }

    final width = math.max(1, (intrinsicWidth * scale).round());
    final height = math.max(1, (intrinsicHeight * scale).round());
    return (width, height);
  }

  String get _label => widget.image.label ?? 'Image';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = switch (_state) {
      _ImageState.ready => _buildImage(scheme),
      _ImageState.loading => _buildPlaceholder(
        scheme,
        label: _label,
        showProgress: true,
      ),
      _ImageState.needsResolver => _buildPlaceholder(
        scheme,
        icon: Icons.image_outlined,
        label: _label,
      ),
      _ImageState.error => _buildPlaceholder(
        scheme,
        icon: Icons.broken_image_outlined,
        label: 'Image failed to load',
        isError: true,
      ),
      _ImageState.tooLarge => _buildPlaceholder(
        scheme,
        icon: Icons.warning_amber_rounded,
        label: 'Image too large to display',
        isError: true,
      ),
    };

    final framed = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth,
        maxHeight: widget.maxHeight,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outline),
            borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          ),
          child: child,
        ),
      ),
    );

    final onTap = widget.onTap;
    return Semantics(
      label: _label,
      image: true,
      button: onTap != null,
      child: onTap == null
          ? framed
          : InkWell(
              onTap: () => onTap(widget.image),
              borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
              child: framed,
            ),
    );
  }

  Widget _buildImage(ColorScheme scheme) => Image.memory(
    _bytes!,
    fit: BoxFit.contain,
    cacheWidth: _decodeWidth,
    cacheHeight: _decodeHeight,
    errorBuilder: (context, error, stack) => _buildPlaceholder(
      scheme,
      icon: Icons.broken_image_outlined,
      label: 'Image failed to load',
      isError: true,
    ),
  );

  Widget _buildPlaceholder(
    ColorScheme scheme, {
    required String label,
    IconData? icon,
    bool showProgress = false,
    bool isError = false,
  }) {
    final foreground = isError ? scheme.error : scheme.onSurfaceVariant;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: SizedBox(
        width: widget.maxWidth,
        height: 120,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (showProgress)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              )
            else if (icon != null)
              Icon(icon, color: foreground, size: 28),
            const SizedBox(height: FluttyTheme.spacingSm),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluttyTheme.spacingMd,
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
