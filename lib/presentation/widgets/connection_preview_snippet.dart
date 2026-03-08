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
    final previewTheme = terminalTheme;
    final previewBackgroundBase = previewTheme == null
        ? colorScheme.surfaceContainerHighest
        : Color.alphaBlend(
            previewTheme.background.withAlpha(previewTheme.isDark ? 230 : 170),
            colorScheme.surfaceContainerHighest,
          );
    final previewBackgroundStart = previewTheme == null
        ? colorScheme.surfaceContainerHighest
        : Color.alphaBlend(
            previewTheme.cursor.withAlpha(previewTheme.isDark ? 12 : 18),
            previewBackgroundBase,
          );
    final previewTextColor =
        previewTheme?.foreground.withAlpha(230) ?? colorScheme.onSurfaceVariant;
    final accentColor = previewTheme?.cursor ?? colorScheme.primary;
    final borderColor = Color.alphaBlend(
      accentColor.withAlpha(26),
      colorScheme.outlineVariant,
    );

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
                        previewBackgroundStart,
                        previewBackgroundBase,
                        previewBackgroundBase.withAlpha(248),
                      ],
                    ),
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
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            accentColor.withAlpha(72),
                            accentColor.withAlpha(8),
                          ],
                        ),
                      ),
                      child: const SizedBox(width: 3),
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
                            previewBackgroundBase.withAlpha(168),
                          ],
                        ),
                      ),
                      child: const SizedBox(width: 18),
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
