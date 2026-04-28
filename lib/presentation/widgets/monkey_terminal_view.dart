// Adapted from package:xterm 4.0.0 TerminalView internals to keep local
// terminal layout and trackpad/mobile gesture fixes. Keep this aligned with the
// pinned xterm dependency when upgrading.
// ignore_for_file: implementation_imports, public_member_api_docs, directives_ordering, always_put_required_named_parameters_first, cast_nullable_to_non_nullable, prefer_expression_function_bodies, sort_child_properties_last, use_if_null_to_convert_nulls_to_bools, avoid_bool_literals_in_conditional_expressions, avoid_setters_without_getters, prefer_int_literals, cascade_invocations, unnecessary_null_checks, invalid_use_of_internal_member

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

import 'monkey_terminal_gesture_handler.dart';
import 'monkey_terminal_scroll_gesture_handler.dart';
import 'terminal_selection_text.dart';

/// Terminal render padding.
///
/// Keep effective horizontal safe-area insets in landscape, but avoid adding
/// extra blank rows at the bottom or side gutters in portrait.
///
/// Some devices report larger lateral insets through [MediaQueryData.padding]
/// than [MediaQueryData.viewPadding] while the keyboard is visible. Use the
/// larger inset so the terminal stays aligned with the rest of the UI.
EdgeInsets resolveTerminalRenderPadding(MediaQueryData mediaQuery) {
  final viewportHeight = mediaQuery.size.height + mediaQuery.viewInsets.bottom;
  final isLandscape = mediaQuery.size.width > viewportHeight;
  if (!isLandscape) {
    return EdgeInsets.zero;
  }
  final leftInset = math.max(
    mediaQuery.padding.left,
    mediaQuery.viewPadding.left,
  );
  final rightInset = math.max(
    mediaQuery.padding.right,
    mediaQuery.viewPadding.right,
  );
  return EdgeInsets.only(left: leftInset, right: rightInset);
}

/// Whether terminal cell slack should be shifted off the trailing edges.
bool shouldAlignTerminalToTrailingEdges(MediaQueryData mediaQuery) {
  final viewportHeight = mediaQuery.size.height + mediaQuery.viewInsets.bottom;
  return mediaQuery.size.width > viewportHeight;
}

Widget _defaultSystemSelectionContextMenu(
  BuildContext _,
  SelectableRegionState selectableRegionState,
) => AdaptiveTextSelectionToolbar.selectableRegion(
  selectableRegionState: selectableRegionState,
);

/// Resolves the terminal grid origin inside the viewport.
@visibleForTesting
Offset resolveTerminalContentOrigin({
  required Size viewportSize,
  required Size cellSize,
  required int columns,
  required int rows,
  EdgeInsets padding = EdgeInsets.zero,
  bool alignToTrailingEdges = false,
}) {
  final availableWidth = math.max(0.0, viewportSize.width - padding.horizontal);
  final availableHeight = math.max(0.0, viewportSize.height - padding.vertical);
  final slackWidth = math.max(0.0, availableWidth - (columns * cellSize.width));
  final slackHeight = math.max(0.0, availableHeight - (rows * cellSize.height));
  return Offset(
    padding.left + (alignToTrailingEdges ? slackWidth : 0),
    padding.top + (alignToTrailingEdges ? slackHeight : 0),
  );
}

/// Terminal viewport padding applied outside the render object.
///
/// Horizontal safe-area insets are applied by the outer viewport container so
/// the terminal stays clear of cutouts while still filling the safe width.
EdgeInsets resolveTerminalViewportPadding(
  MediaQueryData mediaQuery, {
  EdgeInsets basePadding = EdgeInsets.zero,
}) {
  final renderPadding = resolveTerminalRenderPadding(mediaQuery);
  return EdgeInsets.fromLTRB(
    basePadding.left + renderPadding.left,
    basePadding.top + renderPadding.top,
    basePadding.right + renderPadding.right,
    basePadding.bottom + renderPadding.bottom,
  );
}

/// Slightly stretches the terminal horizontally to absorb the final remainder
/// when the viewport width does not divide evenly into whole cells.
@visibleForTesting
double resolveTerminalHorizontalFillScale({
  required double viewportWidth,
  required double cellWidth,
  required int columns,
}) {
  if (viewportWidth <= 0 || cellWidth <= 0 || columns <= 0) {
    return 1;
  }
  final contentWidth = cellWidth * columns;
  if (contentWidth <= 0) {
    return 1;
  }
  return (viewportWidth / contentWidth).clamp(1.0, 1.03);
}

/// Adapted xterm terminal view with a trackpad scroll fix for alt-buffer apps.
class MonkeyTerminalView extends StatefulWidget {
  const MonkeyTerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapDown,
    this.onTapUp,
    this.onDoubleTapDown,
    this.onLongPressStart,
    this.suppressLongPressDragSelection = false,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.resolveLinkTap,
    this.onLinkTapDown,
    this.onLinkTap,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.alwaysShowCursor = false,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
    this.touchScrollToTerminal = false,
    this.liveOutputAutoScroll = true,
    this.useSystemSelection = false,
    this.systemSelectionContextMenuBuilder,
    this.onSystemSelectionChanged,
    this.onInsertText,
    this.onPasteText,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps down on the terminal.
  final void Function(TapDownDetails, CellOffset)? onTapDown;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Callback for when the user double taps on the terminal.
  final void Function(TapDownDetails, CellOffset)? onDoubleTapDown;

  /// Callback for when the user long presses on the terminal.
  final void Function(LongPressStartDetails, CellOffset)? onLongPressStart;

  /// When true, the terminal's built-in drag-to-extend selection on touch
  /// long-press is suppressed. When no [onLongPressStart] override is
  /// provided, the initial word selection on long-press start still occurs,
  /// but subsequent move updates do not extend the selection.
  final bool suppressLongPressDragSelection;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// Resolves a tappable link for the tapped terminal cell, if any.
  final String? Function(CellOffset offset)? resolveLinkTap;

  /// Called when a primary tap is recognized as a pending link tap.
  final void Function(TapDownDetails, CellOffset)? onLinkTapDown;

  /// Called when a primary tap should open a resolved terminal link.
  final ValueChanged<String>? onLinkTap;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Preferred on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  /// If true, vertical touch drags are converted into terminal scroll input
  /// instead of scrolling the Flutter viewport.
  final bool touchScrollToTerminal;

  /// If true, the terminal keeps the viewport pinned to the newest output while
  /// it is already scrolled to the bottom.
  final bool liveOutputAutoScroll;

  /// True when Flutter's [SelectableRegion] should own terminal selection
  /// gestures and handles.
  final bool useSystemSelection;

  /// Builds the context menu for system terminal selection.
  final SelectableRegionContextMenuBuilder? systemSelectionContextMenuBuilder;

  /// Called when system terminal selection changes.
  final ValueChanged<SelectedContent?>? onSystemSelectionChanged;

  /// Called before inserted text is sent to the terminal.
  final Future<bool> Function(String text)? onInsertText;

  /// Called to handle paste shortcuts before xterm pastes clipboard text.
  final Future<void> Function()? onPasteText;

  @override
  State<MonkeyTerminalView> createState() => MonkeyTerminalViewState();
}

class MonkeyTerminalViewState extends State<MonkeyTerminalView>
    with SingleTickerProviderStateMixin {
  static const _touchScrollReportedWheelLinesPerEvent = 3.0;

  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  String? _composingText;
  Offset _lastTouchScrollPosition = Offset.zero;
  double _touchScrollRemainder = 0;
  late final Ticker _touchScrollInertiaTicker;
  Simulation? _touchScrollInertiaSimulation;
  double _lastTouchScrollInertiaOffset = 0;
  int _lastTerminalViewWidth = 0;

  late TerminalController _controller;

  late ScrollController _scrollController;

  MonkeyRenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as MonkeyRenderTerminal;

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _lastTerminalViewWidth = widget.terminal.viewWidth;
    widget.terminal.addListener(_handleTerminalMetricsChanged);
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    super.initState();
    _touchScrollInertiaTicker = createTicker(_onTouchScrollInertiaTick);
  }

  @override
  void didUpdateWidget(covariant MonkeyTerminalView oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_handleTerminalMetricsChanged);
      _lastTerminalViewWidth = widget.terminal.viewWidth;
      widget.terminal.addListener(_handleTerminalMetricsChanged);
      _stopTouchScrollInertia();
      _touchScrollRemainder = 0;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
    }
    if (oldWidget.simulateScroll != widget.simulateScroll) {
      _stopTouchScrollInertia();
      _touchScrollRemainder = 0;
    }
    if (oldWidget.touchScrollToTerminal && !widget.touchScrollToTerminal) {
      _stopTouchScrollInertia();
      _touchScrollRemainder = 0;
    }
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_handleTerminalMetricsChanged);
    _stopTouchScrollInertia();
    _touchScrollInertiaTicker.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    super.dispose();
  }

  void _handleTerminalMetricsChanged() {
    final currentViewWidth = widget.terminal.viewWidth;
    if (currentViewWidth == _lastTerminalViewWidth) {
      return;
    }
    _lastTerminalViewWidth = currentViewWidth;
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final terminalViewportPadding = resolveTerminalViewportPadding(
      mediaQuery,
      basePadding: widget.padding ?? EdgeInsets.zero,
    );
    final shouldFillHorizontalRemainder =
        terminalViewportPadding.left == 0 && terminalViewportPadding.right == 0;

    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      physics: widget.touchScrollToTerminal
          ? const NeverScrollableScrollPhysics()
          : null,
      viewportBuilder: (context, offset) {
        final mediaQuery = MediaQuery.of(context);
        Widget buildTerminalLeaf(BuildContext context) => _TerminalView(
          key: _viewportKey,
          terminal: widget.terminal,
          controller: _controller,
          offset: offset,
          padding: EdgeInsets.zero,
          alignToTrailingEdges: shouldAlignTerminalToTrailingEdges(mediaQuery),
          autoResize: widget.autoResize,
          liveOutputAutoScroll: widget.liveOutputAutoScroll,
          textStyle: widget.textStyle,
          textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
          theme: widget.theme,
          focusNode: _focusNode,
          cursorType: widget.cursorType,
          alwaysShowCursor: widget.alwaysShowCursor,
          onEditableRect: _onEditableRect,
          composingText: _composingText,
          selectionRegistrar: SelectionContainer.maybeOf(context),
        );
        return Builder(builder: buildTerminalLeaf);
      },
    );

    if (widget.useSystemSelection) {
      child = SelectionArea(
        contextMenuBuilder:
            widget.systemSelectionContextMenuBuilder ??
            _defaultSystemSelectionContextMenu,
        onSelectionChanged: widget.onSystemSelectionChanged,
        child: child,
      );
    }

    if (!widget.touchScrollToTerminal) {
      child = MonkeyTerminalScrollGestureHandler(
        terminal: widget.terminal,
        simulateScroll: widget.simulateScroll,
        getCellOffset: (offset) => renderTerminal.getCellOffset(offset),
        getLineHeight: () => renderTerminal.lineHeight,
        child: child,
      );
    }

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        onInsert: _onInsert,
        onDelete: () {
          _scrollToBottom();
          widget.terminal.keyInput(TerminalKey.backspace);
        },
        onComposing: _onComposing,
        onAction: (action) {
          _scrollToBottom();
          if (action == TextInputAction.done) {
            widget.terminal.keyInput(TerminalKey.enter);
          }
        },
        onKeyEvent: _handleKeyEvent,
        readOnly: widget.readOnly,
        child: child,
      );
    } else if (!widget.readOnly) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        child: child,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
      );
    }

    child = Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) async {
            if (widget.onPasteText != null) {
              await widget.onPasteText!();
              _controller.clearSelection();
              return null;
            }

            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text;
            if (text != null) {
              widget.terminal.paste(text);
              _controller.clearSelection();
            }
            return null;
          },
        ),
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (intent) async {
            final selection = _controller.selection;

            if (selection == null) {
              return null;
            }

            final text = widget.terminal.buffer.getText(selection);
            await Clipboard.setData(ClipboardData(text: text));
            return null;
          },
        ),
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
          onInvoke: (intent) {
            _controller.setSelection(
              widget.terminal.buffer.createAnchor(
                0,
                widget.terminal.buffer.height - widget.terminal.viewHeight,
              ),
              widget.terminal.buffer.createAnchor(
                widget.terminal.viewWidth,
                widget.terminal.buffer.height - 1,
              ),
              mode: SelectionMode.line,
            );
            return null;
          },
        ),
      },
      child: child,
    );

    child = KeyboardVisibilty(onKeyboardShow: _onKeyboardShow, child: child);

    child = MonkeyTerminalGestureHandler(
      terminalView: this,
      terminalController: _controller,
      onSingleTapUp: _onTapUp,
      onTapDown: _onTapDown,
      onDoubleTapDown: widget.onDoubleTapDown != null ? _onDoubleTapDown : null,
      onLongPressStart: widget.onLongPressStart != null
          ? _onLongPressStart
          : null,
      suppressLongPressDragSelection: widget.suppressLongPressDragSelection,
      onSecondaryTapDown: widget.onSecondaryTapDown != null
          ? _onSecondaryTapDown
          : null,
      onSecondaryTapUp: widget.onSecondaryTapUp != null
          ? _onSecondaryTapUp
          : null,
      resolveLinkTap: widget.resolveLinkTap == null
          ? null
          : (localPosition) => widget.resolveLinkTap!(
              renderTerminal.getCellOffset(localPosition),
            ),
      onLinkTapDown: widget.onLinkTapDown == null ? null : _onLinkTapDown,
      onLinkTap: widget.onLinkTap,
      onTouchScrollStart: widget.touchScrollToTerminal
          ? _onTouchScrollStart
          : null,
      onTouchScrollUpdate: widget.touchScrollToTerminal
          ? _onTouchScrollUpdate
          : null,
      onTouchScrollEnd: widget.touchScrollToTerminal ? _onTouchScrollEnd : null,
      readOnly: widget.readOnly || widget.useSystemSelection,
      enableTerminalSelectionGestures: !widget.useSystemSelection,
      child: child,
    );

    child = MouseRegion(cursor: widget.mouseCursor, child: child);

    if (shouldFillHorizontalRemainder && _viewportKey.currentContext != null) {
      final horizontalFillScale = resolveTerminalHorizontalFillScale(
        viewportWidth: renderTerminal.size.width,
        cellWidth: renderTerminal.cellSize.width,
        columns: widget.terminal.viewWidth,
      );
      if (horizontalFillScale > 1) {
        child = Transform.scale(
          alignment: Alignment.centerLeft,
          scaleX: horizontalFillScale,
          child: child,
        );
      }
    }

    child = ClipRect(child: child);

    child = Container(
      color: widget.theme.background.withValues(
        alpha: widget.backgroundOpacity,
      ),
      padding: terminalViewportPadding,
      child: child,
    );

    return child;
  }

  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard();
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  bool get shouldSendTerminalTapPointerInput =>
      !widget.readOnly && _controller.shouldSendPointerInput(PointerInput.tap);

  bool sendTerminalPrimaryTap(Offset globalPosition) {
    if (!shouldSendTerminalTapPointerInput) {
      return false;
    }

    final localPosition = renderTerminal.globalToLocal(globalPosition);
    final handledDown = renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.down,
      localPosition,
    );
    final handledUp = renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.up,
      localPosition,
    );
    return handledDown || handledUp;
  }

  Rect get cursorRect {
    return renderTerminal.cursorOffset & renderTerminal.cellSize;
  }

  Rect get globalCursorRect {
    return renderTerminal.localToGlobal(renderTerminal.cursorOffset) &
        renderTerminal.cellSize;
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapUp?.call(details, offset);
  }

  void _onTapDown(TapDownDetails details) {
    _stopTouchScrollInertia();
    if (_controller.selection != null) {
      _controller.clearSelection();
    } else if (!widget.useSystemSelection) {
      _requestInputFocus();
    }

    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapDown?.call(details, offset);
  }

  void _requestInputFocus() {
    if (!widget.hardwareKeyboardOnly) {
      _customTextEditKey.currentState?.requestKeyboard();
    } else {
      _focusNode.requestFocus();
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onDoubleTapDown?.call(details, offset);
  }

  void _onLinkTapDown(TapDownDetails details) {
    _stopTouchScrollInertia();
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onLinkTapDown?.call(details, offset);
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onLongPressStart?.call(details, offset);
  }

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  void _onTouchScrollStart(DragStartDetails details) {
    _stopTouchScrollInertia();
    _lastTouchScrollPosition = details.localPosition;
    _touchScrollRemainder = 0;
  }

  void _onTouchScrollUpdate(DragUpdateDetails details) {
    _lastTouchScrollPosition = details.localPosition;
    _applyTouchScrollDelta(details.delta.dy);
  }

  void _onTouchScrollEnd(DragEndDetails details) {
    final primaryVelocity = details.primaryVelocity;
    if (primaryVelocity == null) {
      return;
    }
    _startTouchScrollInertia(primaryVelocity);
  }

  Tolerance get _touchScrollTolerance {
    final devicePixelRatio = View.of(context).devicePixelRatio;
    return Tolerance(
      velocity: 1.0 / (0.050 * devicePixelRatio),
      distance: 1.0 / devicePixelRatio,
    );
  }

  double get _touchScrollStepHeight {
    final lineHeight = renderTerminal.lineHeight;
    if (lineHeight <= 0) {
      return 0;
    }
    if (widget.terminal.mouseMode.reportScroll) {
      return lineHeight * _touchScrollReportedWheelLinesPerEvent;
    }
    return lineHeight;
  }

  void _applyTouchScrollDelta(double delta) {
    _touchScrollRemainder += delta;

    final stepHeight = _touchScrollStepHeight;
    if (stepHeight <= 0) {
      return;
    }

    while (_touchScrollRemainder.abs() >= stepHeight) {
      final scrollUp = _touchScrollRemainder > 0;
      final handled = _sendTouchScrollMouseInput(
        scrollUp ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        _resolveViewportMousePosition(_lastTouchScrollPosition),
      );

      if (!handled && widget.simulateScroll) {
        widget.terminal.keyInput(
          scrollUp ? TerminalKey.arrowUp : TerminalKey.arrowDown,
        );
      }

      _touchScrollRemainder += scrollUp ? -stepHeight : stepHeight;
    }
  }

  void _startTouchScrollInertia(double velocity) {
    final clampedVelocity = velocity.clamp(
      -kMaxFlingVelocity,
      kMaxFlingVelocity,
    );
    if (clampedVelocity.abs() < kMinFlingVelocity) {
      return;
    }

    _stopTouchScrollInertia();
    _touchScrollInertiaSimulation = ClampingScrollSimulation(
      position: 0,
      velocity: clampedVelocity,
      tolerance: _touchScrollTolerance,
    );
    _touchScrollInertiaTicker.start();
  }

  void _stopTouchScrollInertia() {
    _touchScrollInertiaTicker.stop();
    _touchScrollInertiaSimulation = null;
    _lastTouchScrollInertiaOffset = 0;
  }

  void _onTouchScrollInertiaTick(Duration elapsed) {
    final simulation = _touchScrollInertiaSimulation;
    if (simulation == null) {
      _touchScrollInertiaTicker.stop();
      return;
    }

    final elapsedSeconds =
        elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final scrollOffset = simulation.x(elapsedSeconds);
    _applyTouchScrollDelta(scrollOffset - _lastTouchScrollInertiaOffset);
    _lastTouchScrollInertiaOffset = scrollOffset;

    if (simulation.isDone(elapsedSeconds)) {
      _stopTouchScrollInertia();
    }
  }

  bool _sendTouchScrollMouseInput(
    TerminalMouseButton button,
    CellOffset position,
  ) {
    if (widget.terminal.mouseMode.reportScroll &&
        widget.terminal.mouseReportMode == MouseReportMode.sgr) {
      final sgrButtonId = switch (button) {
        TerminalMouseButton.wheelUp => 64,
        TerminalMouseButton.wheelDown => 65,
        TerminalMouseButton.wheelLeft => 66,
        TerminalMouseButton.wheelRight => 67,
        _ => button.id,
      };
      widget.terminal.onOutput?.call(
        '\x1b[<$sgrButtonId;${position.x + 1};${position.y + 1}M',
      );
      return true;
    }

    return widget.terminal.mouseInput(
      button,
      TerminalMouseButtonState.down,
      position,
    );
  }

  CellOffset _resolveViewportMousePosition(Offset localPosition) {
    final cellSize = renderTerminal.cellSize;
    final cellWidth = cellSize.width <= 0 ? 1.0 : cellSize.width;
    final cellHeight = cellSize.height <= 0 ? 1.0 : cellSize.height;
    final maxColumn = widget.terminal.viewWidth - 1;
    final maxRow = widget.terminal.viewHeight - 1;

    return CellOffset(
      (localPosition.dx / cellWidth).floor().clamp(0, maxColumn),
      (localPosition.dy / cellHeight).floor().clamp(0, maxRow),
    );
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    unawaited(_handleInsert(text));
  }

  Future<void> _handleInsert(String text) async {
    if (widget.onInsertText != null) {
      final shouldInsert = await widget.onInsertText!(text);
      if (!mounted || !shouldInsert) {
        return;
      }
    }

    final key = charToTerminalKey(text.trim());

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
  }

  void _onComposing(String? text) {
    setState(() => _composingText = text);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);

    if (key == null) {
      return KeyEventResult.ignored;
    }

    final handled = widget.terminal.keyInput(
      key,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );

    if (handled) {
      _scrollToBottom();
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onKeyboardShow() {
    if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onEditableRect(Rect rect, Rect caretRect) {
    _customTextEditKey.currentState?.setEditableRect(rect, caretRect);
  }

  void _scrollToBottom() {
    final position = _scrollableKey.currentState?.position;
    if (position != null) {
      position.jumpTo(position.maxScrollExtent);
    }
  }
}

class _TerminalView extends LeafRenderObjectWidget {
  const _TerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.alignToTrailingEdges,
    required this.autoResize,
    required this.liveOutputAutoScroll,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.alwaysShowCursor,
    this.onEditableRect,
    this.composingText,
    this.selectionRegistrar,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool alignToTrailingEdges;

  final bool autoResize;

  final bool liveOutputAutoScroll;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool alwaysShowCursor;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  final SelectionRegistrar? selectionRegistrar;

  @override
  MonkeyRenderTerminal createRenderObject(BuildContext context) {
    return MonkeyRenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      alignToTrailingEdges: alignToTrailingEdges,
      autoResize: autoResize,
      liveOutputAutoScroll: liveOutputAutoScroll,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      alwaysShowCursor: alwaysShowCursor,
      onEditableRect: onEditableRect,
      composingText: composingText,
      selectionRegistrar: selectionRegistrar,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    MonkeyRenderTerminal renderObject,
  ) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..alignToTrailingEdges = alignToTrailingEdges
      ..autoResize = autoResize
      ..liveOutputAutoScroll = liveOutputAutoScroll
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..alwaysShowCursor = alwaysShowCursor
      ..onEditableRect = onEditableRect
      ..composingText = composingText
      ..selectionRegistrar = selectionRegistrar;
  }
}

class MonkeyRenderTerminal extends RenderBox
    with RelayoutWhenSystemFontsChangeMixin, Selectable, SelectionRegistrant {
  MonkeyRenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool alignToTrailingEdges,
    required bool autoResize,
    required bool liveOutputAutoScroll,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool alwaysShowCursor,
    EditableRectCallback? onEditableRect,
    String? composingText,
    SelectionRegistrar? selectionRegistrar,
  }) : _terminal = terminal,
       _controller = controller,
       _offset = offset,
       _padding = padding,
       _alignToTrailingEdges = alignToTrailingEdges,
       _autoResize = autoResize,
       _liveOutputAutoScroll = liveOutputAutoScroll,
       _focusNode = focusNode,
       _cursorType = cursorType,
       _alwaysShowCursor = alwaysShowCursor,
       _onEditableRect = onEditableRect,
       _composingText = composingText,
       _selectionGeometry = SelectionGeometry(
         status: SelectionStatus.none,
         hasContent: terminal.buffer.lines.length > 0,
       ),
       _painter = TerminalPainter(
         theme: theme,
         textStyle: textStyle,
         textScaler: textScaler,
       ) {
    registrar = selectionRegistrar;
  }

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _syncSelectableSelectionFromController();
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    _syncSelectableSelectionFromController();
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _alignToTrailingEdges;
  set alignToTrailingEdges(bool value) {
    if (value == _alignToTrailingEdges) return;
    _alignToTrailingEdges = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  /// Whether layout should keep the viewport pinned to the newest output while
  /// the user is already at the bottom.
  bool get liveOutputAutoScroll => _liveOutputAutoScroll;

  bool _liveOutputAutoScroll;
  set liveOutputAutoScroll(bool value) {
    if (value == _liveOutputAutoScroll) {
      return;
    }

    _liveOutputAutoScroll = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    markNeedsPaint();
  }

  set selectionRegistrar(SelectionRegistrar? value) {
    registrar = value;
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  var _stickToBottom = true;

  int? _selectionStartOffset;
  int? _selectionEndOffset;
  bool _isApplyingSelectableSelection = false;
  LayerLink? _startHandleLayerLink;
  LayerLink? _endHandleLayerLink;
  SelectionGeometry _selectionGeometry;
  bool _selectionGeometryNotificationScheduled = false;
  final Set<VoidCallback> _selectionListeners = <VoidCallback>{};

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    markNeedsLayout();
    _updateSelectionGeometry(deferNotification: true);
    _notifyEditableRect();
  }

  void _onFocusChange() {
    markNeedsPaint();
  }

  void _onTerminalChange() {
    if (registrar != null && _hasSelectableTextSelection) {
      _preserveSelectableSelectionAcrossTerminalChange();
    } else {
      _syncSelectableSelectionFromController();
    }
    markNeedsLayout();
    _notifyEditableRect();
  }

  void _onControllerUpdate() {
    if (!_isApplyingSelectableSelection) {
      _syncSelectableSelectionFromController();
    }
    markNeedsLayout();
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  void dispose() {
    _selectionListeners.clear();
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  SelectionGeometry get value => _selectionGeometry;

  @override
  int get contentLength => _terminalSelectionContentLength;

  @override
  List<Rect> get boundingBoxes => <Rect>[Offset.zero & size];

  @override
  void addListener(VoidCallback listener) {
    _selectionListeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _selectionListeners.remove(listener);
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();
    _updateScrollOffset();

    if (_liveOutputAutoScroll && _stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }
    _updateSelectionGeometry(deferNotification: true);
  }

  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  double get _scrollOffset => _offset.pixels;

  double get lineHeight => _painter.cellSize.height;

  Offset get _contentOrigin => resolveTerminalContentOrigin(
    viewportSize: size,
    cellSize: _painter.cellSize,
    columns: _terminal.viewWidth,
    rows: _terminal.viewHeight,
    padding: _padding,
    alignToTrailingEdges: _alignToTrailingEdges,
  );

  Offset getOffset(CellOffset cellOffset) {
    final origin = _contentOrigin;
    return Offset(
      origin.dx + (cellOffset.x * _painter.cellSize.width),
      origin.dy + (cellOffset.y * _painter.cellSize.height) - _scrollOffset,
    );
  }

  CellOffset getCellOffset(Offset offset) {
    final origin = _contentOrigin;
    final x = offset.dx - origin.dx;
    final y = offset.dy - origin.dy + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;

    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      var toPosition = getCellOffset(to);
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  int get _lineSelectionStride => _terminal.viewWidth + 1;

  int get _terminalSelectionContentLength {
    final lineCount = _terminal.buffer.lines.length;
    if (lineCount == 0 || _terminal.viewWidth <= 0) {
      return 0;
    }
    return (lineCount * _lineSelectionStride) - 1;
  }

  int _clampSelectionOffset(int offset) =>
      offset.clamp(0, _terminalSelectionContentLength);

  bool get _hasSelectableTextSelection =>
      _selectionStartOffset != null && _selectionEndOffset != null;

  int _textOffsetForCell(CellOffset cellOffset) {
    final lineCount = _terminal.buffer.lines.length;
    if (lineCount == 0 || _terminal.viewWidth <= 0) {
      return 0;
    }
    final row = cellOffset.y.clamp(0, lineCount - 1);
    final column = cellOffset.x.clamp(0, _terminal.viewWidth);
    return _clampSelectionOffset((row * _lineSelectionStride) + column);
  }

  CellOffset _cellForTextOffset(int textOffset) {
    final lineCount = _terminal.buffer.lines.length;
    if (lineCount == 0 || _terminal.viewWidth <= 0) {
      return const CellOffset(0, 0);
    }
    final offset = _clampSelectionOffset(textOffset);
    final row = (offset ~/ _lineSelectionStride).clamp(0, lineCount - 1);
    final column = (offset % _lineSelectionStride).clamp(
      0,
      _terminal.viewWidth,
    );
    return CellOffset(column, row);
  }

  CellOffset _getSelectableCellOffset(Offset offset) {
    if (_terminal.buffer.lines.length == 0 || _terminal.viewWidth <= 0) {
      return const CellOffset(0, 0);
    }
    final origin = _contentOrigin;
    final x = offset.dx - origin.dx;
    final y = offset.dy - origin.dy + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  int _textOffsetForLocalPosition(Offset localPosition) {
    if (_terminalSelectionContentLength <= 0) {
      return 0;
    }
    return _textOffsetForCell(_getSelectableCellOffset(localPosition));
  }

  BufferRange _bufferRangeForTextOffsets(int start, int end) {
    final normalizedStart = math.min(start, end);
    final normalizedEnd = math.max(start, end);
    return BufferRangeLine(
      _cellForTextOffset(normalizedStart),
      _cellForTextOffset(normalizedEnd),
    );
  }

  ({int start, int end})? _wordTextOffsetsAt(Offset localPosition) {
    final cellOffset = getCellOffset(localPosition);
    final boundary = _terminal.buffer.getWordBoundary(cellOffset);
    if (boundary == null) {
      return null;
    }
    return (
      start: _textOffsetForCell(boundary.begin),
      end: _textOffsetForCell(boundary.end),
    );
  }

  ({int start, int end}) _lineTextOffsetsAt(Offset localPosition) {
    final cellOffset = _getSelectableCellOffset(localPosition);
    final row = cellOffset.y.clamp(0, _terminal.buffer.lines.length - 1);
    return (
      start: _textOffsetForCell(CellOffset(0, row)),
      end: _textOffsetForCell(CellOffset(_terminal.viewWidth, row)),
    );
  }

  void _applySelectableTextSelection(int start, int end) {
    if (_terminalSelectionContentLength <= 0) {
      _clearSelectableTextSelection();
      return;
    }
    final nextStart = _clampSelectionOffset(start);
    final nextEnd = _clampSelectionOffset(end);
    _selectionStartOffset = nextStart;
    _selectionEndOffset = nextEnd;
    _isApplyingSelectableSelection = true;
    try {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(_cellForTextOffset(nextStart)),
        _terminal.buffer.createAnchorFromOffset(_cellForTextOffset(nextEnd)),
        mode: SelectionMode.line,
      );
    } finally {
      _isApplyingSelectableSelection = false;
    }
    markNeedsPaint();
    _updateSelectionGeometry(deferNotification: true);
  }

  void _clearSelectableTextSelection() {
    if (_selectionStartOffset == null && _selectionEndOffset == null) {
      return;
    }
    _selectionStartOffset = null;
    _selectionEndOffset = null;
    _isApplyingSelectableSelection = true;
    try {
      _controller.clearSelection();
    } finally {
      _isApplyingSelectableSelection = false;
    }
    markNeedsPaint();
    _updateSelectionGeometry(deferNotification: true);
  }

  void _preserveSelectableSelectionAcrossTerminalChange() {
    if (_terminalSelectionContentLength <= 0) {
      _clearSelectableTextSelection();
      return;
    }

    final nextStart = _clampSelectionOffset(_selectionStartOffset!);
    final nextEnd = _clampSelectionOffset(_selectionEndOffset!);
    if (_selectionStartOffset != nextStart || _selectionEndOffset != nextEnd) {
      _selectionStartOffset = nextStart;
      _selectionEndOffset = nextEnd;
      markNeedsPaint();
    }
    _updateSelectionGeometry(deferNotification: true, forceNotify: true);
  }

  void _syncSelectableSelectionFromController() {
    final selection = _controller.selection;
    if (selection == null) {
      if (_selectionStartOffset != null || _selectionEndOffset != null) {
        _selectionStartOffset = null;
        _selectionEndOffset = null;
        markNeedsPaint();
        _updateSelectionGeometry(deferNotification: true);
      }
      return;
    }
    final nextStart = _textOffsetForCell(selection.begin);
    final nextEnd = _textOffsetForCell(selection.end);
    if (_selectionStartOffset == nextStart && _selectionEndOffset == nextEnd) {
      return;
    }
    _selectionStartOffset = nextStart;
    _selectionEndOffset = nextEnd;
    markNeedsPaint();
    _updateSelectionGeometry(deferNotification: true);
  }

  Offset _localPositionForTextOffset(int textOffset) {
    final cellOffset = _cellForTextOffset(textOffset);
    return getOffset(cellOffset);
  }

  Offset _selectionPointForTextOffset(int textOffset) =>
      _localPositionForTextOffset(textOffset) +
      Offset(0, _painter.cellSize.height);

  List<Rect> _selectionRectsForOffsets(int start, int end) {
    if (start == end || _terminal.buffer.lines.length == 0) {
      return const <Rect>[];
    }
    final begin = _cellForTextOffset(math.min(start, end));
    final finish = _cellForTextOffset(math.max(start, end));
    final rects = <Rect>[];
    for (var row = begin.y; row <= finish.y; row++) {
      final startColumn = row == begin.y ? begin.x : 0;
      final endColumn = row == finish.y ? finish.x : _terminal.viewWidth;
      if (endColumn <= startColumn) {
        continue;
      }
      final topLeft = getOffset(CellOffset(startColumn, row));
      rects.add(
        Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy,
          (endColumn - startColumn) * _painter.cellSize.width,
          _painter.cellSize.height,
        ),
      );
    }
    return rects;
  }

  SelectionGeometry _computeSelectionGeometry() {
    final hasContent = _terminalSelectionContentLength > 0;
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (!hasContent || start == null || end == null) {
      return SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: hasContent,
      );
    }

    final isCollapsed = start == end;
    final isReversed = start > end;
    final startHandleType = isCollapsed
        ? TextSelectionHandleType.collapsed
        : isReversed
        ? TextSelectionHandleType.right
        : TextSelectionHandleType.left;
    final endHandleType = isCollapsed
        ? TextSelectionHandleType.collapsed
        : isReversed
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;

    return SelectionGeometry(
      startSelectionPoint: SelectionPoint(
        localPosition: _selectionPointForTextOffset(start),
        lineHeight: _painter.cellSize.height,
        handleType: startHandleType,
      ),
      endSelectionPoint: SelectionPoint(
        localPosition: _selectionPointForTextOffset(end),
        lineHeight: _painter.cellSize.height,
        handleType: endHandleType,
      ),
      selectionRects: _selectionRectsForOffsets(start, end),
      status: isCollapsed
          ? SelectionStatus.collapsed
          : SelectionStatus.uncollapsed,
      hasContent: hasContent,
    );
  }

  void _updateSelectionGeometry({
    bool deferNotification = false,
    bool forceNotify = false,
  }) {
    final nextGeometry = _computeSelectionGeometry();
    final didChange = nextGeometry != _selectionGeometry;
    if (!didChange && !forceNotify) {
      return;
    }
    if (didChange) {
      _selectionGeometry = nextGeometry;
    }
    if (deferNotification) {
      _scheduleSelectionGeometryNotification();
      return;
    }
    _notifySelectionGeometryListeners();
  }

  void _scheduleSelectionGeometryNotification() {
    if (_selectionGeometryNotificationScheduled) {
      return;
    }
    _selectionGeometryNotificationScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _selectionGeometryNotificationScheduled = false;
      if (!attached) {
        return;
      }
      _notifySelectionGeometryListeners();
    });
  }

  void _notifySelectionGeometryListeners() {
    for (final listener in List<VoidCallback>.of(_selectionListeners)) {
      listener();
    }
  }

  @override
  SelectedContent? getSelectedContent() {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (start == null || end == null || start == end) {
      return null;
    }
    final text = _terminal.buffer.getText(
      _bufferRangeForTextOffsets(start, end),
    );
    final trimmedText = trimTerminalSelectionText(text);
    return trimmedText.isEmpty ? null : SelectedContent(plainText: trimmedText);
  }

  @override
  SelectedContentRange? getSelection() {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (start == null || end == null) {
      return null;
    }
    return SelectedContentRange(startOffset: start, endOffset: end);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final previousStart = _selectionStartOffset;
    final previousEnd = _selectionEndOffset;
    final result = switch (event.type) {
      SelectionEventType.clear => _handleSelectableClearSelection(),
      SelectionEventType.selectAll => _handleSelectableSelectAll(),
      SelectionEventType.selectWord => _handleSelectableSelectWord(
        event as SelectWordSelectionEvent,
      ),
      SelectionEventType.selectParagraph => _handleSelectableSelectParagraph(
        event as SelectParagraphSelectionEvent,
      ),
      SelectionEventType.startEdgeUpdate || SelectionEventType.endEdgeUpdate =>
        _handleSelectableEdgeUpdate(event as SelectionEdgeUpdateEvent),
      SelectionEventType.granularlyExtendSelection =>
        _handleSelectableGranularExtension(
          event as GranularlyExtendSelectionEvent,
        ),
      SelectionEventType.directionallyExtendSelection =>
        _handleSelectableDirectionalExtension(
          event as DirectionallyExtendSelectionEvent,
        ),
    };
    if (previousStart != _selectionStartOffset ||
        previousEnd != _selectionEndOffset) {
      _updateSelectionGeometry(deferNotification: true, forceNotify: true);
    }
    return result;
  }

  SelectionResult _handleSelectableClearSelection() {
    _clearSelectableTextSelection();
    return SelectionResult.none;
  }

  SelectionResult _handleSelectableSelectAll() {
    _applySelectableTextSelection(0, _terminalSelectionContentLength);
    return SelectionResult.none;
  }

  SelectionResult _handleSelectableSelectWord(SelectWordSelectionEvent event) {
    final before = _controller.selection;
    selectWord(globalToLocal(event.globalPosition));
    _syncSelectableSelectionFromController();
    if (_controller.selection == before) {
      return SelectionResult.none;
    }
    return SelectionResult.end;
  }

  SelectionResult _handleSelectableSelectParagraph(
    SelectParagraphSelectionEvent event,
  ) {
    final offsets = _lineTextOffsetsAt(globalToLocal(event.globalPosition));
    _applySelectableTextSelection(offsets.start, offsets.end);
    return SelectionResult.end;
  }

  SelectionResult _handleSelectableEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (_terminalSelectionContentLength <= 0) {
      _clearSelectableTextSelection();
      return SelectionResult.none;
    }
    final localPosition = globalToLocal(event.globalPosition);
    final adjustedPosition = _adjustSelectableDragPosition(localPosition);
    final hitOffset = event.granularity == TextGranularity.word
        ? _wordEdgeOffsetForPosition(
            adjustedPosition,
            updateEnd: event.type == SelectionEventType.endEdgeUpdate,
          )
        : _textOffsetForLocalPosition(adjustedPosition);
    if (event.type == SelectionEventType.startEdgeUpdate) {
      _applySelectableTextSelection(
        hitOffset,
        _selectionEndOffset ?? hitOffset,
      );
    } else {
      _applySelectableTextSelection(
        _selectionStartOffset ?? hitOffset,
        hitOffset,
      );
    }
    return _selectionResultForDragPosition(localPosition, hitOffset);
  }

  Rect get _selectableContentRect {
    final origin = _contentOrigin;
    return Rect.fromLTWH(
      origin.dx,
      origin.dy - _scrollOffset,
      _terminal.viewWidth * _painter.cellSize.width,
      _terminalHeight,
    );
  }

  Offset _adjustSelectableDragPosition(Offset localPosition) {
    final contentRect = _selectableContentRect;
    if (contentRect.isEmpty) {
      return localPosition;
    }
    return Offset(
      localPosition.dx.clamp(contentRect.left, contentRect.right),
      localPosition.dy.clamp(contentRect.top, contentRect.bottom),
    );
  }

  SelectionResult _selectionResultForDragPosition(
    Offset localPosition,
    int hitOffset,
  ) {
    final contentRect = _selectableContentRect;
    if (contentRect.isEmpty) {
      return SelectionResult.none;
    }
    if (localPosition.dy < contentRect.top ||
        (hitOffset == 0 && localPosition.dx < contentRect.left)) {
      return SelectionResult.previous;
    }
    if (localPosition.dy > contentRect.bottom ||
        (hitOffset == _terminalSelectionContentLength &&
            localPosition.dx > contentRect.right)) {
      return SelectionResult.next;
    }
    return SelectionResult.end;
  }

  int _wordEdgeOffsetForPosition(
    Offset localPosition, {
    required bool updateEnd,
  }) {
    final offsets = _wordTextOffsetsAt(localPosition);
    if (offsets == null) {
      return _textOffsetForLocalPosition(localPosition);
    }
    final staticEdge = updateEnd ? _selectionStartOffset : _selectionEndOffset;
    if (staticEdge == null) {
      return updateEnd ? offsets.end : offsets.start;
    }
    final hit = _textOffsetForLocalPosition(localPosition);
    if (hit < staticEdge) {
      return offsets.start;
    }
    if (hit > staticEdge) {
      return offsets.end;
    }
    return updateEnd ? offsets.end : offsets.start;
  }

  SelectionResult _handleSelectableGranularExtension(
    GranularlyExtendSelectionEvent event,
  ) {
    final currentStart =
        _selectionStartOffset ??
        (event.forward ? 0 : _terminalSelectionContentLength);
    final currentEnd = _selectionEndOffset ?? currentStart;
    final movingOffset = event.isEnd ? currentEnd : currentStart;
    final nextOffset = event.forward
        ? (movingOffset + 1).clamp(0, _terminalSelectionContentLength)
        : (movingOffset - 1).clamp(0, _terminalSelectionContentLength);
    if (event.isEnd) {
      _applySelectableTextSelection(currentStart, nextOffset);
    } else {
      _applySelectableTextSelection(nextOffset, currentEnd);
    }
    return nextOffset == 0
        ? SelectionResult.previous
        : nextOffset == _terminalSelectionContentLength
        ? SelectionResult.next
        : SelectionResult.end;
  }

  SelectionResult _handleSelectableDirectionalExtension(
    DirectionallyExtendSelectionEvent event,
  ) {
    final currentStart =
        _selectionStartOffset ??
        (event.direction == SelectionExtendDirection.backward
            ? contentLength
            : 0);
    final currentEnd = _selectionEndOffset ?? currentStart;
    final movingOffset = event.isEnd ? currentEnd : currentStart;
    final movingCell = _cellForTextOffset(movingOffset);
    final nextCell = switch (event.direction) {
      SelectionExtendDirection.previousLine => CellOffset(
        (event.dx / _painter.cellSize.width).round().clamp(
          0,
          _terminal.viewWidth,
        ),
        (movingCell.y - 1).clamp(0, _terminal.buffer.lines.length - 1),
      ),
      SelectionExtendDirection.nextLine => CellOffset(
        (event.dx / _painter.cellSize.width).round().clamp(
          0,
          _terminal.viewWidth,
        ),
        (movingCell.y + 1).clamp(0, _terminal.buffer.lines.length - 1),
      ),
      SelectionExtendDirection.forward => CellOffset(
        (movingCell.x + 1).clamp(0, _terminal.viewWidth),
        movingCell.y,
      ),
      SelectionExtendDirection.backward => CellOffset(
        (movingCell.x - 1).clamp(0, _terminal.viewWidth),
        movingCell.y,
      ),
    };
    final nextOffset = _textOffsetForCell(nextCell);
    if (event.isEnd) {
      _applySelectableTextSelection(currentStart, nextOffset);
    } else {
      _applySelectableTextSelection(nextOffset, currentEnd);
    }
    return nextOffset == 0
        ? SelectionResult.previous
        : nextOffset == _terminalSelectionContentLength
        ? SelectionResult.next
        : SelectionResult.end;
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    var needsPaint = false;
    if (_startHandleLayerLink != startHandle) {
      _startHandleLayerLink = startHandle;
      needsPaint = true;
    }
    if (_endHandleLayerLink != endHandle) {
      _endHandleLayerLink = endHandle;
      needsPaint = true;
    }
    if (needsPaint && attached) {
      markNeedsPaint();
    }
  }

  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  void _updateViewportSize() {
    final availableWidth = size.width - _padding.horizontal;
    final availableHeight = _viewportHeight;
    if (availableWidth <= _painter.cellSize.width ||
        availableHeight <= _painter.cellSize.height) {
      return;
    }

    final viewportSize = TerminalSize(
      availableWidth ~/ _painter.cellSize.width,
      availableHeight ~/ _painter.cellSize.height,
    );

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  void _resizeTerminalIfNeeded() {
    if (_autoResize && _viewportSize != null) {
      _terminal.resize(
        _viewportSize!.width,
        _viewportSize!.height,
        _painter.cellSize.width.round(),
        _painter.cellSize.height.round(),
      );
    }
  }

  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText =>
      _composingText != null && _composingText!.isNotEmpty;

  bool get _shouldShowCursor =>
      _terminal.cursorVisibleMode || _alwaysShowCursor || _isComposingText;

  double get _viewportHeight => size.height - _padding.vertical;

  double get _maxScrollExtent =>
      math.max(_terminalHeight - _viewportHeight, 0.0);

  double get _lineOffset => -_scrollOffset + _contentOrigin.dy;

  Offset get cursorOffset => Offset(
    _contentOrigin.dx + (_terminal.buffer.cursorX * _painter.cellSize.width),
    (_terminal.buffer.absoluteCursorY * _painter.cellSize.height) + _lineOffset,
  );

  Size get cellSize => _painter.cellSize;

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;
    final origin = _contentOrigin;
    final firstLineOffset = _scrollOffset - origin.dy;
    final lastLineOffset = _scrollOffset - origin.dy + size.height;
    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;
    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLine(
        canvas,
        offset.translate(
          origin.dx,
          (i * charHeight + _lineOffset).truncateToDouble(),
        ),
        lines[i],
      );
    }

    if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
      }

      if (_shouldShowCursor) {
        _painter.paintCursor(
          canvas,
          offset + cursorOffset,
          cursorType: _cursorType,
          hasFocus: _focusNode.hasFocus,
        );
      }
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );

    final selection = _selectionRangeForPaint;
    if (selection != null) {
      _paintSelection(canvas, selection, effectFirstLine, effectLastLine);
    }

    _paintSelectionHandleLayers(context, offset);
  }

  BufferRange? get _selectionRangeForPaint {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (registrar != null && start != null && end != null && start != end) {
      return _bufferRangeForTextOffsets(start, end);
    }
    return _controller.selection;
  }

  void _paintSelectionHandleLayers(PaintingContext context, Offset offset) {
    if (_startHandleLayerLink != null && value.startSelectionPoint != null) {
      context.pushLayer(
        LeaderLayer(
          link: _startHandleLayerLink!,
          offset: offset + value.startSelectionPoint!.localPosition,
        ),
        (context, offset) {},
        Offset.zero,
      );
    }
    if (_endHandleLayerLink != null && value.endSelectionPoint != null) {
      context.pushLayer(
        LeaderLayer(
          link: _endHandleLayerLink!,
          offset: offset + value.endSelectionPoint!.localPosition,
        ),
        (context, offset) {},
        Offset.zero,
      );
    }
  }

  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(style.getTextStyle(textScaler: _painter.textScaler));
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
  }

  void _paintSelection(
    Canvas canvas,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(canvas, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (final highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (final segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, segment, highlight.color);
      }
    }
  }

  void _paintSegment(Canvas canvas, BufferSegment segment, Color color) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;
    final startOffset = Offset(
      _contentOrigin.dx + (start * _painter.cellSize.width),
      (segment.line * _painter.cellSize.height) + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }
}
