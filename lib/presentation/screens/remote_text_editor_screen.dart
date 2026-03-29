import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models/terminal_theme.dart';
import '../widgets/terminal_text_style.dart';

const _unwrappedEditorTrailingSlack = 24.0;
const _minRemoteEditorFontSize = 12.0;
const _maxRemoteEditorFontSize = 28.0;
const _remoteEditorFontStep = 1.0;
const _remoteTextEditorNowrapViewportKey = ValueKey<String>(
  'remoteTextEditorNowrapViewport',
);
const _remoteTextEditorStatusKey = ValueKey<String>('remoteTextEditorStatus');

/// Measures the width needed to display unwrapped editor lines without clipping.
@visibleForTesting
double measureUnwrappedEditorContentWidth({
  required Iterable<String> lines,
  required TextStyle style,
  required TextDirection textDirection,
  required TextScaler textScaler,
  double trailingSlack = _unwrappedEditorTrailingSlack,
  double Function(String line, TextStyle style)? measureLineWidth,
}) {
  final painter = measureLineWidth == null
      ? TextPainter(
          textDirection: textDirection,
          textScaler: textScaler,
          maxLines: 1,
        )
      : null;
  var maxWidth = 0.0;
  var hasVisibleText = false;

  for (final line in lines) {
    if (line.isEmpty) {
      continue;
    }

    hasVisibleText = true;
    final lineWidth =
        measureLineWidth?.call(line, style) ??
        (painter!
              ..text = TextSpan(text: line, style: style)
              ..layout())
            .width;
    if (lineWidth > maxWidth) {
      maxWidth = lineWidth;
    }
  }

  return hasVisibleText ? maxWidth + trailingSlack : 0;
}

/// Returns the current line prefix that appears before the text offset.
@visibleForTesting
String currentLinePrefixAtTextOffset(String text, int textOffset) {
  final clampedOffset = textOffset < 0
      ? 0
      : textOffset > text.length
      ? text.length
      : textOffset;
  if (clampedOffset == 0) {
    return '';
  }
  final lineStart = text.lastIndexOf('\n', clampedOffset - 1);
  final prefixStart = lineStart == -1 ? 0 : lineStart + 1;
  return text.substring(prefixStart, clampedOffset);
}

/// Resolves the horizontal scroll offset needed to keep the current selection visible.
@visibleForTesting
double resolveUnwrappedEditorSelectionScrollOffset({
  required String text,
  required TextSelection selection,
  required TextStyle style,
  required TextDirection textDirection,
  required TextScaler textScaler,
  required double viewportWidth,
  double currentOffset = 0,
  double trailingSlack = _unwrappedEditorTrailingSlack,
  double Function(String line, TextStyle style)? measureLineWidth,
}) {
  if (!selection.isValid || viewportWidth <= 0) {
    return currentOffset;
  }

  final prefix = currentLinePrefixAtTextOffset(text, selection.extentOffset);
  final caretOffset = measureUnwrappedEditorContentWidth(
    lines: [prefix],
    style: style,
    textDirection: textDirection,
    textScaler: textScaler,
    trailingSlack: 0,
    measureLineWidth: measureLineWidth,
  );
  final viewportEnd = currentOffset + viewportWidth;
  final caretLeadingEdge = caretOffset > trailingSlack
      ? caretOffset - trailingSlack
      : 0.0;
  final caretTrailingEdge = caretOffset + trailingSlack;

  if (caretLeadingEdge < currentOffset) {
    return caretLeadingEdge;
  }
  if (caretTrailingEdge > viewportEnd) {
    return caretTrailingEdge - viewportWidth;
  }
  return currentOffset;
}

/// Resolves the current editor line and column from a selection.
@visibleForTesting
({int line, int column}) resolveRemoteEditorCaretPosition(
  String text,
  TextSelection selection,
) {
  final rawOffset = selection.isValid ? selection.extentOffset : 0;
  final clampedOffset = rawOffset < 0
      ? 0
      : rawOffset > text.length
      ? text.length
      : rawOffset;
  var line = 1;
  var column = 1;

  for (var index = 0; index < clampedOffset; index++) {
    if (text.codeUnitAt(index) == 10) {
      line++;
      column = 1;
      continue;
    }
    column++;
  }

  return (line: line, column: column);
}

/// Builds the remote text editor screen for widget and integration tests.
@visibleForTesting
Widget buildRemoteTextEditorScreenForTesting({
  required String fileName,
  required TextEditingController controller,
  ScrollController? horizontalScrollController,
  TerminalThemeData? terminalTheme,
  String fontFamily = 'monospace',
  double initialFontSize = 14,
}) => RemoteTextEditorScreen(
  fileName: fileName,
  controller: controller,
  horizontalScrollController: horizontalScrollController,
  terminalTheme: terminalTheme,
  fontFamily: fontFamily,
  initialFontSize: initialFontSize,
);

/// Full-screen editor used for editing remote text files over SFTP.
class RemoteTextEditorScreen extends StatefulWidget {
  /// Creates a [RemoteTextEditorScreen].
  const RemoteTextEditorScreen({
    required this.fileName,
    required this.controller,
    required this.fontFamily,
    required this.initialFontSize,
    this.horizontalScrollController,
    this.terminalTheme,
    super.key,
  });

  /// File name shown in the app bar.
  final String fileName;

  /// Text controller for the editable content.
  final TextEditingController controller;

  /// Monospace font family matching the active connection.
  final String fontFamily;

  /// Starting font size for the editor.
  final double initialFontSize;

  /// Optional external horizontal scroll controller for tests.
  final ScrollController? horizontalScrollController;

  /// Optional terminal theme to adapt the editor surface to the connection.
  final TerminalThemeData? terminalTheme;

  @override
  State<RemoteTextEditorScreen> createState() => _RemoteTextEditorScreenState();
}

class _RemoteTextEditorScreenState extends State<RemoteTextEditorScreen> {
  bool _wrapLines = false;
  late double _fontSize;
  late ScrollController _horizontalScrollController;
  late bool _ownsHorizontalScrollController;
  final ScrollController _editorScrollController = ScrollController();
  final ScrollController _lineNumberScrollController = ScrollController();
  bool _selectionVisibilityUpdateScheduled = false;
  double _editorViewportWidth = 0;
  String? _cachedText;
  int _cachedLineCount = 1;
  TextSelection? _cachedSelection;
  ({int line, int column}) _cachedCaretPosition = (line: 1, column: 1);

  @override
  void initState() {
    super.initState();
    _fontSize = widget.initialFontSize.clamp(
      _minRemoteEditorFontSize,
      _maxRemoteEditorFontSize,
    );
    _horizontalScrollController =
        widget.horizontalScrollController ?? ScrollController();
    _ownsHorizontalScrollController = widget.horizontalScrollController == null;
    widget.controller.addListener(_handleControllerChanged);
    _editorScrollController.addListener(_syncLineNumberScrollOffset);
    _refreshCachedMetrics();
    _scheduleSelectionVisibilityUpdate();
  }

  @override
  void didUpdateWidget(covariant RemoteTextEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _cachedText = null;
      _cachedSelection = null;
      _refreshCachedMetrics();
      _scheduleSelectionVisibilityUpdate();
    }
    if (oldWidget.horizontalScrollController !=
        widget.horizontalScrollController) {
      if (_ownsHorizontalScrollController) {
        _horizontalScrollController.dispose();
      }
      _horizontalScrollController =
          widget.horizontalScrollController ?? ScrollController();
      _ownsHorizontalScrollController =
          widget.horizontalScrollController == null;
      _scheduleSelectionVisibilityUpdate();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _editorScrollController
      ..removeListener(_syncLineNumberScrollOffset)
      ..dispose();
    _lineNumberScrollController.dispose();
    if (_ownsHorizontalScrollController) {
      _horizontalScrollController.dispose();
    }
    super.dispose();
  }

  int get _lineCount => _cachedLineCount;

  ({int line, int column}) get _caretPosition => _cachedCaretPosition;

  void _refreshCachedMetrics() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final textChanged = !identical(_cachedText, text);
    final selectionChanged = _cachedSelection != selection;

    if (!textChanged && !selectionChanged) {
      return;
    }

    if (textChanged) {
      _cachedText = text;
      _cachedLineCount = '\n'.allMatches(text).length + 1;
    }

    if (textChanged || selectionChanged) {
      _cachedSelection = selection;
      _cachedCaretPosition = resolveRemoteEditorCaretPosition(text, selection);
    }
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    _refreshCachedMetrics();
    setState(() {});
    _scheduleSelectionVisibilityUpdate();
  }

  void _syncLineNumberScrollOffset() {
    if (!_lineNumberScrollController.hasClients) {
      return;
    }
    final maxOffset = _lineNumberScrollController.position.maxScrollExtent;
    final targetOffset = _editorScrollController.offset.clamp(0.0, maxOffset);
    if ((_lineNumberScrollController.offset - targetOffset).abs() < 0.5) {
      return;
    }
    _lineNumberScrollController.jumpTo(targetOffset);
  }

  void _scheduleSelectionVisibilityUpdate() {
    if (_wrapLines ||
        !mounted ||
        _selectionVisibilityUpdateScheduled ||
        _editorViewportWidth <= 0) {
      return;
    }
    _selectionVisibilityUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionVisibilityUpdateScheduled = false;
      if (!mounted ||
          _wrapLines ||
          !_horizontalScrollController.hasClients ||
          !_editorScrollController.hasClients) {
        return;
      }
      _ensureSelectionVisible();
    });
  }

  void _ensureSelectionVisible() {
    final editorStyle = _buildEditorTextStyle(
      Theme.of(context),
      widget.terminalTheme,
    );
    final targetOffset = resolveUnwrappedEditorSelectionScrollOffset(
      text: widget.controller.text,
      selection: widget.controller.selection,
      style: editorStyle,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      viewportWidth: _editorViewportWidth,
      currentOffset: _horizontalScrollController.offset,
    );
    final clampedOffset = targetOffset.clamp(
      0.0,
      _horizontalScrollController.position.maxScrollExtent,
    );
    if ((clampedOffset - _horizontalScrollController.offset).abs() < 0.5) {
      return;
    }
    _horizontalScrollController.jumpTo(clampedOffset);
  }

  void _updateEditorViewportWidth(double viewportWidth) {
    if ((_editorViewportWidth - viewportWidth).abs() < 0.5) {
      return;
    }
    _editorViewportWidth = viewportWidth;
    _scheduleSelectionVisibilityUpdate();
  }

  void _changeFontSize(double delta) {
    final nextFontSize = (_fontSize + delta).clamp(
      _minRemoteEditorFontSize,
      _maxRemoteEditorFontSize,
    );
    if ((_fontSize - nextFontSize).abs() < 0.01) {
      return;
    }
    setState(() => _fontSize = nextFontSize);
    _scheduleSelectionVisibilityUpdate();
  }

  TextStyle _buildEditorTextStyle(
    ThemeData theme,
    TerminalThemeData? terminalTheme,
  ) {
    final colors = _resolveEditorColors(theme, terminalTheme);
    return resolveMonospaceTextStyle(
      widget.fontFamily,
      fontSize: _fontSize,
    ).copyWith(color: colors.foreground, height: 1.35);
  }

  double _measureLineHeight(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.height;
  }

  double _resolveGutterWidth(BuildContext context, TextStyle style) {
    final digits = math.max(2, _lineCount.toString().length);
    final painter = TextPainter(
      text: TextSpan(text: '8' * digits, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width + 28;
  }

  double _measureUnwrappedContentWidth(BuildContext context, TextStyle style) =>
      measureUnwrappedEditorContentWidth(
        lines: widget.controller.text.split('\n'),
        style: style,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _resolveEditorColors(theme, widget.terminalTheme);
    final editorTextStyle = _buildEditorTextStyle(theme, widget.terminalTheme);
    final lineHeight = _measureLineHeight(context, editorTextStyle);
    final caretPosition = _caretPosition;

    return Theme(
      data: theme.copyWith(
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: colors.cursor,
          selectionColor: colors.selection,
          selectionHandleColor: colors.cursor,
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: Text('Edit ${widget.fileName}'),
          actions: [
            IconButton(
              onPressed: _fontSize <= _minRemoteEditorFontSize
                  ? null
                  : () => _changeFontSize(-_remoteEditorFontStep),
              icon: const Icon(Icons.zoom_out),
              tooltip: 'Zoom out',
            ),
            IconButton(
              onPressed: () {
                setState(() {
                  _wrapLines = !_wrapLines;
                });
                if (!_wrapLines) {
                  _scheduleSelectionVisibilityUpdate();
                }
              },
              icon: Icon(_wrapLines ? Icons.wrap_text : Icons.segment),
              tooltip: _wrapLines ? 'Disable line wrap' : 'Enable line wrap',
            ),
            IconButton(
              onPressed: _fontSize >= _maxRemoteEditorFontSize
                  ? null
                  : () => _changeFontSize(_remoteEditorFontStep),
              icon: const Icon(Icons.zoom_in),
              tooltip: 'Zoom in',
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, widget.controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: colors.background,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: colors.border),
              ),
              shadows: [
                BoxShadow(blurRadius: 18, color: colors.border.withAlpha(28)),
              ],
            ),
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final gutterWidth = _wrapLines
                          ? 0.0
                          : _resolveGutterWidth(context, editorTextStyle);
                      final viewportWidth = math.max<double>(
                        constraints.maxWidth - gutterWidth,
                        0,
                      );
                      _updateEditorViewportWidth(viewportWidth);

                      final editor = TextField(
                        controller: widget.controller,
                        autofocus: true,
                        expands: true,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        style: editorTextStyle,
                        scrollController: _editorScrollController,
                        scrollPhysics: const ClampingScrollPhysics(),
                        strutStyle: StrutStyle.fromTextStyle(
                          editorTextStyle,
                          forceStrutHeight: true,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                      );

                      final editorPane = _wrapLines
                          ? SizedBox(
                              width: viewportWidth,
                              height: constraints.maxHeight,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  12,
                                  0,
                                ),
                                child: editor,
                              ),
                            )
                          : _buildNowrapEditorPane(
                              context,
                              constraints.maxHeight,
                              viewportWidth,
                              editorTextStyle,
                              editor,
                            );

                      return Row(
                        children: [
                          if (!_wrapLines)
                            Container(
                              width: gutterWidth,
                              height: constraints.maxHeight,
                              padding: const EdgeInsets.only(
                                left: 12,
                                right: 8,
                                top: 12,
                              ),
                              decoration: BoxDecoration(
                                color: colors.gutterBackground,
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                ),
                              ),
                              child: IgnorePointer(
                                child: ListView.builder(
                                  controller: _lineNumberScrollController,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _lineCount,
                                  itemExtent: lineHeight,
                                  itemBuilder: (context, index) => Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      '${index + 1}',
                                      style: editorTextStyle.copyWith(
                                        color: colors.gutterForeground,
                                        fontSize: _fontSize * 0.88,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Expanded(child: editorPane),
                        ],
                      );
                    },
                  ),
                ),
                Container(
                  key: _remoteTextEditorStatusKey,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: colors.statusBackground,
                    border: Border(top: BorderSide(color: colors.border)),
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    runSpacing: 8,
                    spacing: 16,
                    children: [
                      Text(
                        'Line ${caretPosition.line}, Column ${caretPosition.column}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.statusForeground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _wrapLines ? 'Wrap on' : 'Wrap off',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.statusForeground,
                        ),
                      ),
                      Text(
                        '${_fontSize.toStringAsFixed(0)} pt',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.statusForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNowrapEditorPane(
    BuildContext context,
    double height,
    double viewportWidth,
    TextStyle editorTextStyle,
    Widget editor,
  ) {
    final measuredContentWidth = _measureUnwrappedContentWidth(
      context,
      editorTextStyle,
    );
    final contentWidth = measuredContentWidth > viewportWidth
        ? measuredContentWidth
        : viewportWidth;

    return SizedBox(
      key: _remoteTextEditorNowrapViewportKey,
      width: viewportWidth,
      height: height,
      child: ClipRect(
        child: Scrollbar(
          controller: _horizontalScrollController,
          thumbVisibility: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _horizontalScrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(
              width: contentWidth,
              height: height,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: editor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteEditorColors {
  const _RemoteEditorColors({
    required this.background,
    required this.foreground,
    required this.border,
    required this.cursor,
    required this.selection,
    required this.gutterBackground,
    required this.gutterForeground,
    required this.statusBackground,
    required this.statusForeground,
  });

  final Color background;
  final Color foreground;
  final Color border;
  final Color cursor;
  final Color selection;
  final Color gutterBackground;
  final Color gutterForeground;
  final Color statusBackground;
  final Color statusForeground;
}

_RemoteEditorColors _resolveEditorColors(
  ThemeData theme,
  TerminalThemeData? terminalTheme,
) {
  final colorScheme = theme.colorScheme;
  if (terminalTheme == null) {
    final foreground = colorScheme.onSurface;
    return _RemoteEditorColors(
      background: colorScheme.surface,
      foreground: foreground,
      border: colorScheme.outlineVariant,
      cursor: colorScheme.primary,
      selection: colorScheme.primary.withAlpha(60),
      gutterBackground: colorScheme.surfaceContainerHighest,
      gutterForeground: colorScheme.onSurfaceVariant,
      statusBackground: colorScheme.surfaceContainerHigh,
      statusForeground: foreground,
    );
  }

  final surfaceBase = Color.alphaBlend(
    terminalTheme.background.withAlpha(244),
    colorScheme.surface,
  );
  final gutterBackground = Color.alphaBlend(
    terminalTheme.background.withAlpha(220),
    colorScheme.surfaceContainerHighest,
  );
  final statusBackground = Color.alphaBlend(
    terminalTheme.cursor.withAlpha(18),
    surfaceBase,
  );

  return _RemoteEditorColors(
    background: surfaceBase,
    foreground: terminalTheme.foreground,
    border: Color.alphaBlend(
      terminalTheme.cursor.withAlpha(38),
      colorScheme.outlineVariant,
    ),
    cursor: terminalTheme.cursor,
    selection: terminalTheme.selection,
    gutterBackground: gutterBackground,
    gutterForeground: terminalTheme.foreground.withAlpha(170),
    statusBackground: statusBackground,
    statusForeground: terminalTheme.foreground.withAlpha(235),
  );
}
