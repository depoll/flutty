import 'dart:math' as math;
import 'dart:typed_data';

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

/// Upper bound applied to any caller-supplied decode hint, so an oversized
/// hint cannot defeat the memory bound.
const int kAcpMaxImageDecodeDimension = 4096;

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
/// rejected before decoding, decode dimensions are bounded to limit memory,
/// and stale asynchronous resolver completions can never overwrite a newer
/// image. Loading and error states render accessible placeholders rather than
/// throwing.
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

  /// Decode dimension applied when [AcpImageContent] carries no decode hint.
  final int defaultDecodeDimension;

  @override
  State<AcpInlineImage> createState() => _AcpInlineImageState();
}

enum _ImageState { loading, ready, needsResolver, error, tooLarge }

class _AcpInlineImageState extends State<AcpInlineImage> {
  _ImageState _state = _ImageState.loading;
  Uint8List? _bytes;

  // Monotonic guard so stale async resolver completions from a previous image
  // or resolver cannot overwrite the current one.
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
        oldWidget.maxBytes != widget.maxBytes) {
      _resolve();
    }
  }

  bool _withinLimit(int byteLength) => byteLength <= widget.maxBytes;

  void _set(_ImageState state, {Uint8List? bytes}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _state = state;
      _bytes = bytes;
    });
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    final image = widget.image;
    switch (image.sourceKind) {
      case AcpImageSourceKind.bytes:
        final bytes = image.bytes!;
        if (!_withinLimit(bytes.length)) {
          _set(_ImageState.tooLarge);
          return;
        }
        _set(_ImageState.ready, bytes: bytes);
      case AcpImageSourceKind.dataUri:
        _decodeDataUri(image.uri!);
      case AcpImageSourceKind.fileUri:
      case AcpImageSourceKind.networkUri:
        await _resolveViaResolver(image, generation);
    }
  }

  void _decodeDataUri(String uri) {
    try {
      // Cheap pre-decode guard: a base64 data URI decodes to roughly 3/4 of
      // its encoded length, so reject clearly oversized input before paying
      // for the base64 decode.
      if ((uri.length * 3) ~/ 4 > widget.maxBytes) {
        _set(_ImageState.tooLarge);
        return;
      }
      final data = Uri.parse(uri).data;
      final bytes = data?.contentAsBytes();
      if (bytes == null || bytes.isEmpty) {
        _set(_ImageState.error);
        return;
      }
      if (!_withinLimit(bytes.length)) {
        _set(_ImageState.tooLarge);
        return;
      }
      _set(_ImageState.ready, bytes: bytes);
    } on Object {
      _set(_ImageState.error);
    }
  }

  Future<void> _resolveViaResolver(
    AcpImageContent image,
    int generation,
  ) async {
    final resolver = widget.resolver;
    if (resolver == null) {
      _set(_ImageState.needsResolver);
      return;
    }
    _set(_ImageState.loading);
    try {
      final bytes = await resolver(image);
      // Ignore completions superseded by a newer image/resolver.
      if (!mounted || generation != _generation) {
        return;
      }
      if (bytes == null || bytes.isEmpty) {
        _set(_ImageState.error);
        return;
      }
      if (!_withinLimit(bytes.length)) {
        _set(_ImageState.tooLarge);
        return;
      }
      _set(_ImageState.ready, bytes: bytes);
    } on Object {
      if (mounted && generation == _generation) {
        _set(_ImageState.error);
      }
    }
  }

  String get _label => widget.image.label ?? 'Image';

  ({int? width, int? height}) get _decodeDimensions {
    var width = widget.image.decodeWidth;
    var height = widget.image.decodeHeight;
    if (width == null && height == null) {
      width = widget.defaultDecodeDimension;
    }
    if (width != null) {
      width = math.min(width, kAcpMaxImageDecodeDimension);
    }
    if (height != null) {
      height = math.min(height, kAcpMaxImageDecodeDimension);
    }
    return (width: width, height: height);
  }

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

  Widget _buildImage(ColorScheme scheme) {
    final dimensions = _decodeDimensions;
    return Image.memory(
      _bytes!,
      fit: BoxFit.contain,
      cacheWidth: dimensions.width,
      cacheHeight: dimensions.height,
      errorBuilder: (context, error, stack) => _buildPlaceholder(
        scheme,
        icon: Icons.broken_image_outlined,
        label: 'Image failed to load',
        isError: true,
      ),
    );
  }

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
