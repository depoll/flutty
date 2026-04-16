// Adapted from package:xterm 4.0.0 TerminalView internals to keep a local
// trackpad/mobile gesture fix. Keep this aligned with the pinned xterm
// dependency when upgrading.
// ignore_for_file: implementation_imports, public_member_api_docs, directives_ordering, always_put_required_named_parameters_first, cast_nullable_to_non_nullable, prefer_expression_function_bodies, sort_child_properties_last, use_if_null_to_convert_nulls_to_bools, avoid_bool_literals_in_conditional_expressions

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
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
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'monkey_terminal_gesture_handler.dart';
import 'monkey_terminal_scroll_gesture_handler.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

/// Terminal render padding.
///
/// Keep horizontal safe-area cutout insets in landscape, but avoid adding
/// extra blank rows at the bottom or side gutters in portrait.
EdgeInsets resolveTerminalRenderPadding(MediaQueryData mediaQuery) {
  final viewportHeight = mediaQuery.size.height + mediaQuery.viewInsets.bottom;
  final isLandscape = mediaQuery.size.width > viewportHeight;
  if (!isLandscape) {
    return EdgeInsets.zero;
  }
  return EdgeInsets.only(
    left: mediaQuery.viewPadding.left,
    right: mediaQuery.viewPadding.right,
  );
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
    this.onTapUp,
    this.onDoubleTapDown,
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

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Callback for when the user double taps on the terminal.
  final void Function(TapDownDetails, CellOffset)? onDoubleTapDown;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// Resolves a tappable link for the tapped terminal cell, if any.
  final String? Function(CellOffset offset)? resolveLinkTap;

  /// Called when a primary tap is recognized as a pending link tap.
  final VoidCallback? onLinkTapDown;

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

  /// Called before inserted text is sent to the terminal.
  final Future<bool> Function(String text)? onInsertText;

  /// Called to handle paste shortcuts before xterm pastes clipboard text.
  final Future<void> Function()? onPasteText;

  @override
  State<MonkeyTerminalView> createState() => MonkeyTerminalViewState();
}

class MonkeyTerminalViewState extends State<MonkeyTerminalView> {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  String? _composingText;
  Offset _lastTouchScrollPosition = Offset.zero;
  double _touchScrollRemainder = 0;

  late TerminalController _controller;

  late ScrollController _scrollController;

  RenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as RenderTerminal;

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    super.initState();
  }

  @override
  void didUpdateWidget(covariant MonkeyTerminalView oldWidget) {
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
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      physics: widget.touchScrollToTerminal
          ? const NeverScrollableScrollPhysics()
          : null,
      viewportBuilder: (context, offset) {
        return _TerminalView(
          key: _viewportKey,
          terminal: widget.terminal,
          controller: _controller,
          offset: offset,
          padding: resolveTerminalRenderPadding(MediaQuery.of(context)),
          autoResize: widget.autoResize,
          textStyle: widget.textStyle,
          textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
          theme: widget.theme,
          focusNode: _focusNode,
          cursorType: widget.cursorType,
          alwaysShowCursor: widget.alwaysShowCursor,
          onEditableRect: _onEditableRect,
          composingText: _composingText,
        );
      },
    );

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
      onTapUp: _onTapUp,
      onTapDown: _onTapDown,
      onDoubleTapDown: widget.onDoubleTapDown != null ? _onDoubleTapDown : null,
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
      onLinkTapDown: widget.onLinkTapDown,
      onLinkTap: widget.onLinkTap,
      onTouchScrollStart: widget.touchScrollToTerminal
          ? _onTouchScrollStart
          : null,
      onTouchScrollUpdate: widget.touchScrollToTerminal
          ? _onTouchScrollUpdate
          : null,
      readOnly: widget.readOnly,
      child: child,
    );

    child = MouseRegion(cursor: widget.mouseCursor, child: child);

    child = Container(
      color: widget.theme.background.withValues(
        alpha: widget.backgroundOpacity,
      ),
      padding: widget.padding,
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

  void _onTapDown(_) {
    if (_controller.selection != null) {
      _controller.clearSelection();
    } else {
      if (!widget.hardwareKeyboardOnly) {
        _customTextEditKey.currentState?.requestKeyboard();
      } else {
        _focusNode.requestFocus();
      }
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onDoubleTapDown?.call(details, offset);
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
    _lastTouchScrollPosition = details.localPosition;
    _touchScrollRemainder = 0;
  }

  void _onTouchScrollUpdate(DragUpdateDetails details) {
    _lastTouchScrollPosition = details.localPosition;
    _touchScrollRemainder += details.delta.dy;

    final lineHeight = renderTerminal.lineHeight;
    if (lineHeight <= 0) {
      return;
    }

    while (_touchScrollRemainder.abs() >= lineHeight) {
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

      _touchScrollRemainder += scrollUp ? -lineHeight : lineHeight;
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
    required this.autoResize,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.alwaysShowCursor,
    this.onEditableRect,
    this.composingText,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool autoResize;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool alwaysShowCursor;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  @override
  RenderTerminal createRenderObject(BuildContext context) {
    return RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      autoResize: autoResize,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      alwaysShowCursor: alwaysShowCursor,
      onEditableRect: onEditableRect,
      composingText: composingText,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..autoResize = autoResize
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..alwaysShowCursor = alwaysShowCursor
      ..onEditableRect = onEditableRect
      ..composingText = composingText;
  }
}
