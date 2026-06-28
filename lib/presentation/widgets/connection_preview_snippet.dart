import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../app/theme.dart';
import '../../domain/models/terminal_preview.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import 'monkey_terminal_view.dart';

const _previewMaxLines = 17;
const _previewMinFontSize = 6.5;
const _previewMaxFontSize = 10.5;
const _styledPreviewMaxFontSize = 18.0;
const _previewLineHeight = 1.22;
const _stackPreviewCardHeight = 198.0;
const _stackPreviewMetadataHeight = 18.0;
const _stackPreviewCardVerticalPadding = 14.0;
// 10px padding + 1px border on each side.
const _stackPreviewCardHorizontalPadding = 22.0;
const _stackPreviewTitleGap = 3.0;
const _stackPreviewMetadataGap = 3.0;
const _stackPreviewTextTopInset = 3.0;
const _stackPreviewMinCardHeight = 72.0;

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
  TerminalPreviewSnapshot? previewSnapshot,
  TerminalThemeData? activeTerminalTheme,
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
    previewSnapshot: previewSnapshot,
    metadata: metadataSegments.isEmpty ? null : metadataSegments.join(' • '),
    terminalTheme:
        activeTerminalTheme ??
        resolveConnectionPreviewTheme(
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
    this.previewSnapshot,
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

  /// Latest styled terminal preview snapshot, when available.
  final TerminalPreviewSnapshot? previewSnapshot;

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
    final previewBackgroundBase = _previewSurfaceColor(
      previewTheme,
      colorScheme,
    );
    final previewTextColor =
        previewTheme?.foreground.withAlpha(230) ?? colorScheme.onSurfaceVariant;
    final borderColor = _previewBorderColor(previewTheme, colorScheme);

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
            ),
            child: _AdaptiveTerminalPreviewText(
              text: previewText,
              previewSnapshot: previewSnapshot,
              terminalTheme: terminalTheme,
              color: previewTextColor,
              maxLines: previewMaxLines,
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
    this.previewSnapshot,
    this.metadata,
    this.terminalTheme,
  });

  /// Short title shown at the top of the stacked card.
  final String title;

  /// Main preview or status text shown inside the card.
  final String body;

  /// Styled preview cell data shown inside the card, when available.
  final TerminalPreviewSnapshot? previewSnapshot;

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
          other.previewSnapshot == previewSnapshot &&
          other.metadata == metadata &&
          other.terminalTheme == terminalTheme;

  @override
  int get hashCode =>
      Object.hash(title, body, previewSnapshot, metadata, terminalTheme);
}

/// Renders one or more connection preview cards in a visibly offset stack.
class ConnectionPreviewStack extends StatelessWidget {
  /// Creates a [ConnectionPreviewStack].
  const ConnectionPreviewStack({
    required this.entries,
    this.cardHeight = _stackPreviewCardHeight,
    this.verticalOffset = 14,
    this.horizontalOffset = 10,
    this.onTap,
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

  /// Called when the preview stack is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHorizontalInset = (entries.length - 1) * horizontalOffset;
        final cardWidth = constraints.maxWidth > maxHorizontalInset
            ? constraints.maxWidth - maxHorizontalInset
            : 0.0;
        final cardHeights = [
          for (final entry in entries)
            _stackPreviewCardHeightForEntry(
              context: context,
              entry: entry,
              cardWidth: cardWidth,
              maxHeight:
                  cardHeight +
                  (entry.metadata != null ? _stackPreviewMetadataHeight : 0),
            ),
        ];
        final stackHeight = [
          for (var index = 0; index < cardHeights.length; index++)
            cardHeights[index] + (index * verticalOffset),
        ].reduce(math.max);

        final stack = SizedBox(
          width: double.infinity,
          height: stackHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var index = 0; index < entries.length; index++)
                Positioned(
                  top: index * verticalOffset,
                  left: index * horizontalOffset,
                  width: cardWidth,
                  child: _ConnectionPreviewStackCard(
                    entry: entries[index],
                    height: cardHeights[index],
                    opacity: index == entries.length - 1
                        ? 1
                        : 0.9 - ((entries.length - index - 2) * 0.05),
                    onTap: onTap,
                  ),
                ),
            ],
          ),
        );
        final handleTap = onTap;
        if (handleTap == null) {
          return stack;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: handleTap,
          child: stack,
        );
      },
    );
  }
}

class _ConnectionPreviewStackCard extends StatelessWidget {
  const _ConnectionPreviewStackCard({
    required this.entry,
    required this.height,
    required this.opacity,
    this.onTap,
  });

  final ConnectionPreviewStackEntry entry;
  final double height;
  final double opacity;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final previewTheme = entry.terminalTheme;
    final backgroundColor = _previewSurfaceColor(previewTheme, colorScheme);
    final borderColor = _previewBorderColor(previewTheme, colorScheme);
    final textColor =
        previewTheme?.foreground.withAlpha(230) ?? colorScheme.onSurfaceVariant;

    final card = Opacity(
      opacity: opacity.clamp(0.7, 1).toDouble(),
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        decoration: BoxDecoration(
          color: backgroundColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(12),
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
              child: ClipRect(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: _stackPreviewTextTopInset,
                  ),
                  child: _AdaptiveTerminalPreviewText(
                    text: entry.body,
                    previewSnapshot: entry.previewSnapshot,
                    terminalTheme: entry.terminalTheme,
                    color: textColor,
                    maxLines: _previewMaxLines,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final handleTap = onTap;
    if (handleTap == null) {
      return card;
    }

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: handleTap,
        borderRadius: BorderRadius.circular(12),
        child: card,
      ),
    );
  }
}

Color _previewSurfaceColor(
  TerminalThemeData? previewTheme,
  ColorScheme colorScheme,
) => previewTheme?.background ?? colorScheme.surfaceContainerHighest;

Color _previewBorderColor(
  TerminalThemeData? previewTheme,
  ColorScheme colorScheme,
) {
  if (previewTheme == null) {
    return Color.alphaBlend(
      colorScheme.primary.withAlpha(18),
      colorScheme.outlineVariant,
    );
  }
  return Color.alphaBlend(
    previewTheme.foreground.withAlpha(previewTheme.isDark ? 46 : 64),
    previewTheme.background,
  );
}

double _stackPreviewCardHeightForEntry({
  required BuildContext context,
  required ConnectionPreviewStackEntry entry,
  required double cardWidth,
  required double maxHeight,
}) {
  final textDirection = Directionality.of(context);
  final textScaler = MediaQuery.textScalerOf(context);
  final theme = Theme.of(context);
  final titleHeight = _singleLineTextHeight(
    style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
    textDirection: textDirection,
    textScaler: textScaler,
  );
  final metadataHeight = entry.metadata == null
      ? 0.0
      : _singleLineTextHeight(
          style: theme.textTheme.labelSmall,
          textDirection: textDirection,
          textScaler: textScaler,
        );
  final chromeHeight =
      _stackPreviewCardVerticalPadding +
      titleHeight +
      _stackPreviewTitleGap +
      (entry.metadata == null
          ? 0.0
          : metadataHeight + _stackPreviewMetadataGap);
  final previewMaxHeight = math.max<double>(0, maxHeight - chromeHeight);
  final previewTextMaxHeight = math.max<double>(
    0,
    previewMaxHeight - _stackPreviewTextTopInset,
  );
  final previewTextMaxWidth = math.max<double>(
    0,
    cardWidth - _stackPreviewCardHorizontalPadding,
  );

  final styledSnapshot = entry.previewSnapshot;
  final styledTheme = entry.terminalTheme;
  double previewHeight;
  if (styledSnapshot != null && styledTheme != null) {
    final lineCount = math.max(
      1,
      math.min(styledSnapshot.lines.length, _previewMaxLines),
    );
    final columnCount = _styledContentColumns(styledSnapshot);
    final cellHeight = _styledPreviewCellHeight(
      terminalTheme: styledTheme,
      columnCount: columnCount,
      maxWidth: previewTextMaxWidth,
      textScaler: textScaler,
    );
    final naturalHeight = cellHeight * lineCount;
    previewHeight =
        math.min(naturalHeight, previewTextMaxHeight) +
        _stackPreviewTextTopInset;
  } else {
    final baseStyle = FluttyTheme.monoStyle.copyWith(
      fontSize: _previewMaxFontSize,
      height: _previewLineHeight,
    );
    final fontSize = _fitPreviewFontSize(
      text: entry.body,
      maxLines: _previewMaxLines,
      constraints: BoxConstraints(maxHeight: previewTextMaxHeight),
    );
    previewHeight =
        _previewTextHeight(
          text: entry.body,
          maxLines: _previewMaxLines,
          style: baseStyle.copyWith(fontSize: fontSize),
          textDirection: textDirection,
          textScaler: textScaler,
        ) +
        _stackPreviewTextTopInset;
  }
  return (chromeHeight + math.min(previewHeight, previewMaxHeight)).clamp(
    _stackPreviewMinCardHeight,
    maxHeight,
  );
}

double _singleLineTextHeight({
  required TextStyle? style,
  required TextDirection textDirection,
  required TextScaler textScaler,
}) {
  final painter = TextPainter(
    text: TextSpan(text: 'Hg', style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  return painter.height;
}

class _AdaptiveTerminalPreviewText extends StatelessWidget {
  const _AdaptiveTerminalPreviewText({
    required this.text,
    required this.previewSnapshot,
    required this.terminalTheme,
    required this.color,
    required this.maxLines,
  });

  final String text;
  final TerminalPreviewSnapshot? previewSnapshot;
  final TerminalThemeData? terminalTheme;
  final Color color;
  final int maxLines;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final style = FluttyTheme.monoStyle.copyWith(
        fontSize: _previewMaxFontSize,
        color: color,
        height: _previewLineHeight,
      );
      final fontSize = _fitPreviewFontSize(
        text: text,
        maxLines: maxLines,
        constraints: constraints,
      );

      final styledPreview = previewSnapshot;
      final resolvedTerminalTheme = terminalTheme;
      if (styledPreview != null && resolvedTerminalTheme != null) {
        return _StyledTerminalPreviewText(
          preview: styledPreview,
          terminalTheme: resolvedTerminalTheme,
          maxLines: maxLines,
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
        );
      }

      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.clip,
        softWrap: false,
        style: style.copyWith(fontSize: fontSize),
      );
    },
  );
}

class _StyledTerminalPreviewText extends StatelessWidget {
  const _StyledTerminalPreviewText({
    required this.preview,
    required this.terminalTheme,
    required this.maxLines,
    required this.maxWidth,
    required this.maxHeight,
  });

  final TerminalPreviewSnapshot preview;
  final TerminalThemeData terminalTheme;
  final int maxLines;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final lineCount = math.max(1, math.min(preview.lines.length, maxLines));
    final columnCount = _styledContentColumns(preview);
    final fontSize = _fitStyledPreviewFontSize(
      terminalTheme: terminalTheme,
      columnCount: columnCount,
      maxWidth: maxWidth,
      textScaler: textScaler,
    );
    final painter = _buildStyledPreviewPainter(
      terminalTheme: terminalTheme,
      fontSize: fontSize,
      textScaler: textScaler,
    );
    final naturalHeight = painter.cellSize.height * lineCount;
    final height = maxHeight.isFinite
        ? math.min(maxHeight, naturalHeight)
        : naturalHeight;
    final paint = CustomPaint(
      painter: _TerminalPreviewPainter(
        preview: preview,
        maxLines: maxLines,
        painter: painter,
      ),
    );

    return ClipRect(
      child: maxWidth.isFinite
          ? SizedBox(width: maxWidth, height: height, child: paint)
          : SizedBox(height: height, child: paint),
    );
  }
}

double _fitStyledPreviewFontSize({
  required TerminalThemeData terminalTheme,
  required int columnCount,
  required double maxWidth,
  required TextScaler textScaler,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0 || columnCount <= 0) {
    return _previewMinFontSize;
  }
  // Pick the largest font size where columnCount * cellWidth(F) <= maxWidth,
  // so the snapshot content fills the card horizontally without stretching.
  var low = _previewMinFontSize;
  var high = _styledPreviewMaxFontSize;
  for (var index = 0; index < 14; index++) {
    final midpoint = (low + high) / 2;
    final painter = _buildStyledPreviewPainter(
      terminalTheme: terminalTheme,
      fontSize: midpoint,
      textScaler: textScaler,
    );
    if (painter.cellSize.width * columnCount <= maxWidth) {
      low = midpoint;
    } else {
      high = midpoint;
    }
  }
  return low;
}

MonkeyTerminalPainter _buildStyledPreviewPainter({
  required TerminalThemeData terminalTheme,
  required double fontSize,
  required TextScaler textScaler,
}) => MonkeyTerminalPainter(
  theme: terminalTheme.toXtermTheme(),
  textStyle: TerminalStyle.fromTextStyle(
    FluttyTheme.monoStyle.copyWith(
      fontSize: fontSize,
      height: _previewLineHeight,
    ),
  ),
  textScaler: textScaler,
);

double _styledPreviewCellHeight({
  required TerminalThemeData terminalTheme,
  required int columnCount,
  required double maxWidth,
  required TextScaler textScaler,
}) {
  final fontSize = _fitStyledPreviewFontSize(
    terminalTheme: terminalTheme,
    columnCount: columnCount,
    maxWidth: maxWidth,
    textScaler: textScaler,
  );
  return _buildStyledPreviewPainter(
    terminalTheme: terminalTheme,
    fontSize: fontSize,
    textScaler: textScaler,
  ).cellSize.height;
}

int _styledContentColumns(TerminalPreviewSnapshot snapshot) {
  var columns = 0;
  for (final line in snapshot.lines) {
    if (line.text.length > columns) {
      columns = line.text.length;
    }
  }
  return math.max(1, columns);
}

class _TerminalPreviewPainter extends CustomPainter {
  const _TerminalPreviewPainter({
    required this.preview,
    required this.maxLines,
    required this.painter,
  });

  final TerminalPreviewSnapshot preview;
  final int maxLines;
  final MonkeyTerminalPainter painter;

  @override
  void paint(Canvas canvas, Size size) {
    final cellData = CellData.empty();
    final cellWidth = painter.cellSize.width;
    final lineHeight = painter.cellSize.height;
    final availableRows = math.max(1, size.height ~/ lineHeight);
    final totalRows = math.min(preview.lines.length, maxLines);
    final lineCount = math.min(totalRows, availableRows);
    // Show the most recent rows when the snapshot exceeds the available height.
    final startRow = math.max(0, totalRows - lineCount);
    final visibleColumns = math.max(1, (size.width / cellWidth).ceil());

    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..drawRect(Offset.zero & size, Paint()..color = painter.theme.background);

    for (var visibleIndex = 0; visibleIndex < lineCount; visibleIndex++) {
      final row = startRow + visibleIndex;
      final line = preview.lines[row].cells;
      final y = visibleIndex * lineHeight;
      canvas
        ..save()
        ..clipRect(Rect.fromLTWH(0, y, size.width, lineHeight));
      for (
        var column = 0;
        column < line.length && column < visibleColumns;
        column++
      ) {
        line.getCellData(column, cellData);
        final width = cellData.content >> CellContent.widthShift;
        final x = column * cellWidth;
        if (x >= size.width) {
          break;
        }
        painter.paintCell(canvas, Offset(x, y), cellData);
        if (width == 2) {
          column++;
        }
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TerminalPreviewPainter oldDelegate) =>
      oldDelegate.preview != preview ||
      oldDelegate.maxLines != maxLines ||
      oldDelegate.painter.theme != painter.theme ||
      oldDelegate.painter.textStyle != painter.textStyle ||
      oldDelegate.painter.textScaler != painter.textScaler;
}

double _fitPreviewFontSize({
  required String text,
  required int maxLines,
  required BoxConstraints constraints,
}) {
  final lines = text.split('\n').take(maxLines).toList(growable: false);
  final visibleLineCount = math.max(lines.length, 1);
  var maxFontSize = _previewMaxFontSize;
  if (constraints.maxHeight.isFinite && constraints.maxHeight > 0) {
    maxFontSize = math.min(
      maxFontSize,
      constraints.maxHeight / (visibleLineCount * _previewLineHeight),
    );
  }

  return maxFontSize.clamp(_previewMinFontSize, _previewMaxFontSize);
}

double _previewTextHeight({
  required String text,
  required int maxLines,
  required TextStyle style,
  required TextDirection textDirection,
  required TextScaler textScaler,
}) {
  final lineCount = math.max(text.split('\n').take(maxLines).length, 1);
  final linePainter = TextPainter(
    text: TextSpan(text: 'Hg', style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  return linePainter.height * lineCount;
}
