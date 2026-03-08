import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/settings_service.dart';

/// Resolves the terminal theme that should be reflected in a preview chip.
TerminalThemeData resolveConnectionPreviewTheme({
  required Brightness brightness,
  required TerminalThemeSettings themeSettings,
  required Iterable<TerminalThemeData> availableThemes,
  String? lightThemeId,
  String? darkThemeId,
}) {
  final isDark = brightness == Brightness.dark;
  final themeLookup = {for (final theme in availableThemes) theme.id: theme};
  final preferredThemeId = isDark
      ? darkThemeId ?? themeSettings.darkThemeId
      : lightThemeId ?? themeSettings.lightThemeId;

  return themeLookup[preferredThemeId] ??
      TerminalThemes.getById(preferredThemeId) ??
      (isDark ? TerminalThemes.midnightPurple : TerminalThemes.cleanWhite);
}

/// Renders connection metadata with a visually distinct live terminal preview.
class ConnectionPreviewSnippet extends StatelessWidget {
  /// Creates a [ConnectionPreviewSnippet].
  const ConnectionPreviewSnippet({
    required this.endpoint,
    this.preview,
    this.endpointStyle,
    this.terminalTheme,
    super.key,
  });

  /// Endpoint or connection metadata shown above the preview.
  final String endpoint;

  /// Latest terminal preview text, when available.
  final String? preview;

  /// Optional style override for the endpoint metadata.
  final TextStyle? endpointStyle;

  /// Terminal theme used to tint the preview surface.
  final TerminalThemeData? terminalTheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewText = preview?.trim();
    final colorScheme = theme.colorScheme;
    final surroundingBackground = theme.scaffoldBackgroundColor;
    final previewTheme = terminalTheme;
    final previewBackgroundBase = previewTheme == null
        ? colorScheme.surfaceContainerHighest
        : Color.alphaBlend(
            previewTheme.background.withAlpha(previewTheme.isDark ? 230 : 170),
            colorScheme.surfaceContainerHighest,
          );
    final previewTextColor =
        previewTheme?.foreground.withAlpha(230) ?? colorScheme.onSurfaceVariant;
    final borderColor = Color.alphaBlend(
      (previewTheme?.cursor ?? colorScheme.primary).withAlpha(18),
      colorScheme.outlineVariant,
    );
    final edgeFadeColor = surroundingBackground;

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
                    color: previewBackgroundBase,
                    border: Border.all(color: borderColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    previewText,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 9,
                      color: previewTextColor,
                      height: 1.25,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          radius: 1.15,
                          stops: const [0.7, 0.9, 1],
                          colors: [
                            Colors.transparent,
                            edgeFadeColor.withAlpha(220),
                            edgeFadeColor,
                          ],
                        ),
                      ),
                      child: const SizedBox.expand(),
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
