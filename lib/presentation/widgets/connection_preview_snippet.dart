import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';

const _previewMaxLines = 15;
const _previewFontSize = 8.0;
const _previewLineHeight = 1.18;
const _stackPreviewCardHeight = 178.0;
const _stackPreviewMetadataHeight = 18.0;

/// Resolves the terminal theme that should be reflected in a preview chip.
TerminalThemeData resolveConnectionPreviewTheme({
  required Brightness brightness,
  required TerminalThemeSettings themeSettings,
  required Iterable<TerminalThemeData> availableThemes,
  String? lightThemeId,
  String? darkThemeId,
}) {
  final isDark = brightness == Brightness.dark;
  final preferredThemeId = isDark
      ? darkThemeId ?? themeSettings.darkThemeId
      : lightThemeId ?? themeSettings.lightThemeId;

  return TerminalThemes.resolveById(
    brightness: brightness,
    themeId: preferredThemeId,
    additionalThemes: availableThemes,
  );
}

/// Fallback status text for a connection preview with no terminal output yet.
String fallbackConnectionPreviewStatus(SshConnectionState state) =>
    switch (state) {
      SshConnectionState.connecting => 'Connecting…',
      SshConnectionState.authenticating => 'Authenticating…',
      SshConnectionState.error => 'Connection failed',
      SshConnectionState.reconnecting => 'Reconnecting…',
      _ => 'Waiting for terminal output…',
    };

String? _trimmedNonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String? _connectionActivityTitle({
  required String? sessionTitle,
  required String? windowTitle,
  required String? iconName,
}) =>
    _trimmedNonEmpty(sessionTitle) ??
    _trimmedNonEmpty(windowTitle) ??
    _trimmedNonEmpty(iconName);

/// Builds a stacked preview entry for a connection.
ConnectionPreviewStackEntry buildConnectionPreviewStackEntry({
  required int connectionId,
  required SshConnectionState state,
  required Brightness brightness,
  required TerminalThemeSettings themeSettings,
  required Iterable<TerminalThemeData> availableThemes,
  String? preview,
  String? sessionTitle,
  String? windowTitle,
  String? iconName,
  Uri? workingDirectory,
  TerminalShellStatus? shellStatus,
  int? lastExitCode,
  String? hostLightThemeId,
  String? hostDarkThemeId,
  String? connectionLightThemeId,
  String? connectionDarkThemeId,
}) {
  final activityTitle = _connectionActivityTitle(
    sessionTitle: sessionTitle,
    windowTitle: windowTitle,
    iconName: iconName,
  );
  final titleSegments = <String>['Connection #$connectionId'];
  if (activityTitle != null) {
    titleSegments.add(activityTitle);
  }
  final resolvedPreview = preview?.trim();
  final workingDirectoryLabel = formatTerminalWorkingDirectoryLabel(
    workingDirectory,
  );
  final shellStatusLabel = describeTerminalShellStatus(
    shellStatus,
    lastExitCode: lastExitCode,
  );
  final metadataSegments = <String>[];
  if ((workingDirectoryLabel ?? '').isNotEmpty) {
    metadataSegments.add(workingDirectoryLabel!);
  }
  if ((shellStatusLabel ?? '').isNotEmpty) {
    metadataSegments.add(shellStatusLabel!);
  }
  final body = resolvedPreview == null || resolvedPreview.isEmpty
      ? fallbackConnectionPreviewStatus(state)
      : resolvedPreview;

  return ConnectionPreviewStackEntry(
    title: titleSegments.join(' • '),
    body: body,
    metadata: metadataSegments.isEmpty ? null : metadataSegments.join(' • '),
    terminalTheme: resolveConnectionPreviewTheme(
      brightness: brightness,
      themeSettings: themeSettings,
      availableThemes: availableThemes,
      lightThemeId: connectionLightThemeId ?? hostLightThemeId,
      darkThemeId: connectionDarkThemeId ?? hostDarkThemeId,
    ),
  );
}

/// Renders connection metadata with a visually distinct live terminal preview.
class ConnectionPreviewSnippet extends StatelessWidget {
  /// Creates a [ConnectionPreviewSnippet].
  const ConnectionPreviewSnippet({
    required this.endpoint,
    this.preview,
    this.sessionTitle,
    this.windowTitle,
    this.iconName,
    this.workingDirectory,
    this.shellStatus,
    this.lastExitCode,
    this.endpointStyle,
    this.terminalTheme,
    this.showEndpoint = true,
    this.previewMaxLines = _previewMaxLines,
    super.key,
  });

  /// Endpoint or connection metadata shown above the preview.
  final String endpoint;

  /// Latest terminal preview text, when available.
  final String? preview;

  /// Active coding-agent session title, when available.
  final String? sessionTitle;

  /// Latest remote window title, when available.
  final String? windowTitle;

  /// Latest remote icon name, when available. Used as a fallback when the
  /// window title is unavailable.
  final String? iconName;

  /// Latest working-directory URI, when available.
  final Uri? workingDirectory;

  /// Latest shell integration status, when available.
  final TerminalShellStatus? shellStatus;

  /// Latest command exit code emitted through shell integration.
  final int? lastExitCode;

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
    final activityTitle = _connectionActivityTitle(
      sessionTitle: sessionTitle,
      windowTitle: windowTitle,
      iconName: iconName,
    );
    final workingDirectoryLabel = formatTerminalWorkingDirectoryLabel(
      workingDirectory,
    );
    final shellStatusLabel = describeTerminalShellStatus(
      shellStatus,
      lastExitCode: lastExitCode,
    );
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
        if (activityTitle != null) ...[
          if (showEndpoint) const SizedBox(height: 2),
          Text(
            'Active: $activityTitle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: previewTextColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if ((workingDirectoryLabel?.isNotEmpty ?? false) ||
            (shellStatusLabel?.isNotEmpty ?? false)) ...[
          if (showEndpoint || activityTitle != null) const SizedBox(height: 2),
          Text(
            [
              if ((workingDirectoryLabel ?? '').isNotEmpty)
                workingDirectoryLabel!,
              if ((shellStatusLabel ?? '').isNotEmpty) shellStatusLabel!,
            ].join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (previewText != null && previewText.isNotEmpty) ...[
          if (showEndpoint ||
              activityTitle != null ||
              (workingDirectoryLabel?.isNotEmpty ?? false) ||
              (shellStatusLabel?.isNotEmpty ?? false))
            const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
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
                fontSize: _previewFontSize,
                color: previewTextColor,
                height: _previewLineHeight,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Data for a single card in a stacked connection preview.
@immutable
class ConnectionPreviewStackEntry {
  /// Creates a [ConnectionPreviewStackEntry].
  const ConnectionPreviewStackEntry({
    required this.title,
    required this.body,
    this.metadata,
    this.terminalTheme,
  });

  /// Short title shown at the top of the stacked card.
  final String title;

  /// Main preview or status text shown inside the card.
  final String body;

  /// Connection metadata shown separately from the terminal preview.
  final String? metadata;

  /// Terminal theme used to tint the preview surface.
  final TerminalThemeData? terminalTheme;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionPreviewStackEntry &&
          other.title == title &&
          other.body == body &&
          other.metadata == metadata &&
          other.terminalTheme == terminalTheme;

  @override
  int get hashCode => Object.hash(title, body, metadata, terminalTheme);
}

/// Renders one or more connection preview cards in a visibly offset stack.
class ConnectionPreviewStack extends StatelessWidget {
  /// Creates a [ConnectionPreviewStack].
  const ConnectionPreviewStack({
    required this.entries,
    this.cardHeight = _stackPreviewCardHeight,
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

    final effectiveCardHeight =
        cardHeight +
        (entries.any((entry) => entry.metadata != null)
            ? _stackPreviewMetadataHeight
            : 0);
    final stackHeight =
        effectiveCardHeight + ((entries.length - 1) * verticalOffset);

    return SizedBox(
      width: double.infinity,
      height: stackHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHorizontalInset = (entries.length - 1) * horizontalOffset;
          final cardWidth = constraints.maxWidth > maxHorizontalInset
              ? constraints.maxWidth - maxHorizontalInset
              : 0.0;

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
                    height: effectiveCardHeight,
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
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
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
            const SizedBox(height: 3),
            if (entry.metadata != null) ...[
              Text(
                entry.metadata!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: textColor.withAlpha(190),
                ),
              ),
              const SizedBox(height: 3),
            ],
            Expanded(
              child: Text(
                entry.body,
                maxLines: _previewMaxLines,
                overflow: TextOverflow.ellipsis,
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: _previewFontSize,
                  color: textColor,
                  height: _previewLineHeight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
