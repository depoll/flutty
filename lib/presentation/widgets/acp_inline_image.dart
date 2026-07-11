import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';

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
/// is no implicit network access. Loading and error states render accessible
/// placeholders rather than throwing.
class AcpInlineImage extends StatefulWidget {
  /// Creates an inline image.
  const AcpInlineImage({
    required this.image,
    super.key,
    this.resolver,
    this.onTap,
    this.maxWidth = 360,
    this.maxHeight = 260,
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

  @override
  State<AcpInlineImage> createState() => _AcpInlineImageState();
}

enum _ImageState { loading, ready, needsResolver, error }

class _AcpInlineImageState extends State<AcpInlineImage> {
  _ImageState _state = _ImageState.loading;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AcpInlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.resolver != widget.resolver) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final image = widget.image;
    switch (image.sourceKind) {
      case AcpImageSourceKind.bytes:
        setState(() {
          _bytes = image.bytes;
          _state = _ImageState.ready;
        });
      case AcpImageSourceKind.dataUri:
        _decodeDataUri(image.uri!);
      case AcpImageSourceKind.fileUri:
      case AcpImageSourceKind.networkUri:
        await _resolveViaResolver(image);
    }
  }

  void _decodeDataUri(String uri) {
    try {
      final data = Uri.parse(uri).data;
      final bytes = data?.contentAsBytes();
      if (bytes == null || bytes.isEmpty) {
        setState(() => _state = _ImageState.error);
        return;
      }
      setState(() {
        _bytes = bytes;
        _state = _ImageState.ready;
      });
    } on Object {
      setState(() => _state = _ImageState.error);
    }
  }

  Future<void> _resolveViaResolver(AcpImageContent image) async {
    final resolver = widget.resolver;
    if (resolver == null) {
      setState(() => _state = _ImageState.needsResolver);
      return;
    }
    setState(() => _state = _ImageState.loading);
    try {
      final bytes = await resolver(image);
      if (!mounted) {
        return;
      }
      if (bytes == null || bytes.isEmpty) {
        setState(() => _state = _ImageState.error);
        return;
      }
      setState(() {
        _bytes = bytes;
        _state = _ImageState.ready;
      });
    } on Object {
      if (mounted) {
        setState(() => _state = _ImageState.error);
      }
    }
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
    cacheWidth: widget.image.decodeWidth,
    cacheHeight: widget.image.decodeHeight,
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
