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
    final previewTextColor =
        previewTheme?.foreground.withAlpha(230) ?? colorScheme.onSurfaceVariant;
    final borderColor = Color.alphaBlend(
      (previewTheme?.cursor ?? colorScheme.primary).withAlpha(18),
      colorScheme.outlineVariant,
    );
    final shadowColor = Color.alphaBlend(
      (previewTheme?.cursor ?? theme.shadowColor).withAlpha(12),
      theme.shadowColor.withAlpha(16),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(endpoint, style: endpointStyle),
        if (previewText != null && previewText.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            decoration: BoxDecoration(
              color: previewBackgroundBase,
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
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
        ],
      ],
    );
  }
}
