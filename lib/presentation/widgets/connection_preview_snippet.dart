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
    this.windowTitle,
    this.endpointStyle,
    this.terminalTheme,
    this.showEndpoint = true,
    this.previewMaxLines = 5,
    super.key,
  });

  /// Endpoint or connection metadata shown above the preview.
  final String endpoint;

  /// Latest terminal preview text, when available.
  final String? preview;

  /// Latest remote window title, when available.
  final String? windowTitle;

  /// Optional style override for the endpoint metadata.
  final TextStyle? endpointStyle;

  /// Terminal theme used to tint the preview surface.
  final TerminalThemeData? terminalTheme;

  /// Whether to render the endpoint metadata line above the preview.
  final bool showEndpoint;

  /// Maximum number of preview lines to render before truncating.
  final int previewMaxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewText = preview?.trim();
    final resolvedWindowTitle = windowTitle?.trim();
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
        if (showEndpoint) Text(endpoint, style: endpointStyle),
        if (resolvedWindowTitle != null && resolvedWindowTitle.isNotEmpty) ...[
          if (showEndpoint) const SizedBox(height: 2),
          Text(
            resolvedWindowTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: previewTextColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (previewText != null && previewText.isNotEmpty) ...[
          if (showEndpoint || (resolvedWindowTitle?.isNotEmpty ?? false))
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
              maxLines: previewMaxLines,
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

/// Data for a single card in a stacked connection preview.
class ConnectionPreviewStackEntry {
  /// Creates a [ConnectionPreviewStackEntry].
  const ConnectionPreviewStackEntry({
    required this.title,
    required this.body,
    this.terminalTheme,
  });

  /// Short title shown at the top of the stacked card.
  final String title;

  /// Main preview or status text shown inside the card.
  final String body;

  /// Terminal theme used to tint the preview surface.
  final TerminalThemeData? terminalTheme;
}

/// Renders one or more connection preview cards in a visibly offset stack.
class ConnectionPreviewStack extends StatelessWidget {
  /// Creates a [ConnectionPreviewStack].
  const ConnectionPreviewStack({
    required this.entries,
    this.cardHeight = 74,
    this.verticalOffset = 14,
    this.horizontalOffset = 10,
    super.key,
  });

  /// Cards to render in the stack, ordered from oldest to newest.
  final List<ConnectionPreviewStackEntry> entries;

  /// Height of each stacked preview card.
  final double cardHeight;

  /// Vertical offset applied between stacked cards.
  final double verticalOffset;

  /// Horizontal offset applied between stacked cards.
  final double horizontalOffset;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }

    final stackHeight = cardHeight + ((entries.length - 1) * verticalOffset);

    return SizedBox(
      width: double.infinity,
      height: stackHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHorizontalInset = (entries.length - 1) * horizontalOffset;
          final cardWidth = constraints.maxWidth - maxHorizontalInset;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (var index = 0; index < entries.length; index++)
                Positioned(
                  top: index * verticalOffset,
                  left: index * horizontalOffset,
                  width: cardWidth,
                  child: _ConnectionPreviewStackCard(
                    entry: entries[index],
                    height: cardHeight,
                    opacity: index == entries.length - 1
                        ? 1
                        : 0.9 - ((entries.length - index - 2) * 0.05),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ConnectionPreviewStackCard extends StatelessWidget {
  const _ConnectionPreviewStackCard({
    required this.entry,
    required this.height,
    required this.opacity,
  });

  final ConnectionPreviewStackEntry entry;
  final double height;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final previewTheme = entry.terminalTheme;
    final backgroundColor = previewTheme == null
        ? colorScheme.surfaceContainerHighest
        : Color.alphaBlend(
            previewTheme.background.withAlpha(previewTheme.isDark ? 230 : 170),
            colorScheme.surfaceContainerHighest,
          );
    final borderColor = Color.alphaBlend(
      (previewTheme?.cursor ?? colorScheme.primary).withAlpha(28),
      colorScheme.outlineVariant,
    );
    final shadowColor = Color.alphaBlend(
      (previewTheme?.cursor ?? theme.shadowColor).withAlpha(14),
      theme.shadowColor.withAlpha(20),
    );
    final textColor =
        previewTheme?.foreground.withAlpha(230) ?? colorScheme.onSurfaceVariant;

    return Opacity(
      opacity: opacity.clamp(0.7, 1).toDouble(),
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(
          color: backgroundColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                entry.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 9,
                  color: textColor,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
