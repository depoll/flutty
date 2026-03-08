import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Renders connection metadata with a visually distinct live terminal preview.
class ConnectionPreviewSnippet extends StatelessWidget {
  /// Creates a [ConnectionPreviewSnippet].
  const ConnectionPreviewSnippet({
    required this.endpoint,
    this.preview,
    this.endpointStyle,
    super.key,
  });

  /// Endpoint or connection metadata shown above the preview.
  final String endpoint;

  /// Latest terminal preview text, when available.
  final String? preview;

  /// Optional style override for the endpoint metadata.
  final TextStyle? endpointStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewText = preview?.trim();
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(endpoint, style: endpointStyle),
        if (previewText != null && previewText.isNotEmpty) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colorScheme.primary.withAlpha(26),
                        colorScheme.surfaceContainerHighest,
                        colorScheme.surfaceContainerHighest.withAlpha(235),
                      ],
                    ),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withAlpha(140),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    previewText,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 9,
                      color: colorScheme.onSurfaceVariant,
                      height: 1.25,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            colorScheme.primary.withAlpha(210),
                            colorScheme.primary.withAlpha(60),
                          ],
                        ),
                      ),
                      child: const SizedBox(width: 4),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            colorScheme.surfaceContainerHighest.withAlpha(180),
                          ],
                        ),
                      ),
                      child: const SizedBox(width: 24),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
