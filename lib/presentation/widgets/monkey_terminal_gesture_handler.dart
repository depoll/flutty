// Adapted from package:xterm 4.0.0 gesture internals used by TerminalView.
// Keep this aligned with the pinned xterm dependency when upgrading.
// ignore_for_file: implementation_imports, public_member_api_docs, directives_ordering, always_put_required_named_parameters_first, use_late_for_private_fields_and_variables, prefer_expression_function_bodies, sort_child_properties_last, invalid_use_of_internal_member

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

import 'monkey_terminal_gesture_detector.dart';
import 'monkey_terminal_view.dart';

/// Adapted xterm gesture handler for [MonkeyTerminalView].
class MonkeyTerminalGestureHandler extends StatefulWidget {
  const MonkeyTerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onTouchScrollStart,
    this.onTouchScrollUpdate,
    this.resolveLinkTap,
    this.onLinkTap,
    this.readOnly = false,
  });

  final MonkeyTerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final GestureDragStartCallback? onTouchScrollStart;

  final GestureDragUpdateCallback? onTouchScrollUpdate;

  /// Resolves a tappable link at the given local position, if any.
  final String? Function(Offset localPosition)? resolveLinkTap;

  /// Called when a primary tap should open a resolved link instead of sending
  /// mouse input to the terminal.
  final ValueChanged<String>? onLinkTap;

  final bool readOnly;

  @override
  State<MonkeyTerminalGestureHandler> createState() =>
      _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<MonkeyTerminalGestureHandler> {
  MonkeyTerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;

  LongPressStartDetails? _lastLongPressStartDetails;

  String? _pendingLinkTap;

  @override
  Widget build(BuildContext context) {
    return MonkeyTerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onTapCancel: _clearPendingLinkTap,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onTertiaryTapDown,
      onTertiaryTapUp: onTertiaryTapUp,
      onTouchScrollStart: onTouchScrollStart,
      onTouchScrollUpdate: onTouchScrollUpdate,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      // onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDoubleTapDown: onDoubleTapDown,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    _pendingLinkTap = _resolveLinkTap(details.localPosition);
    if (_pendingLinkTap != null) {
      // Link taps are handled separately in onSingleTapUp and do not
      // trigger the generic tap-down callback here.
      return;
    }
    // For non-link taps, onTapDown is special, as it will always call the
    // supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    final pendingLinkTap =
        _pendingLinkTap ?? _resolveLinkTap(details.localPosition);
    _pendingLinkTap = null;
    if (pendingLinkTap != null) {
      widget.onLinkTap?.call(pendingLinkTap);
      return;
    }
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onTouchScrollStart(DragStartDetails details) {
    _clearPendingLinkTap();
    widget.onTouchScrollStart?.call(details);
  }

  void onTouchScrollUpdate(DragUpdateDetails details) {
    _clearPendingLinkTap();
    widget.onTouchScrollUpdate?.call(details);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.middle);
  }

  void onDoubleTapDown(TapDownDetails details) {
    _pendingLinkTap = null;
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    _pendingLinkTap = null;
    _lastLongPressStartDetails = details;
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    renderTerminal.selectWord(
      _lastLongPressStartDetails!.localPosition,
      details.localPosition,
    );
  }

  // void onLongPressUp() {}

  void onDragStart(DragStartDetails details) {
    _pendingLinkTap = null;
    _lastDragStartDetails = details;

    details.kind == PointerDeviceKind.mouse
        ? renderTerminal.selectCharacters(details.localPosition)
        : renderTerminal.selectWord(details.localPosition);
  }

  void onDragUpdate(DragUpdateDetails details) {
    renderTerminal.selectCharacters(
      _lastDragStartDetails!.localPosition,
      details.localPosition,
    );
  }

  String? _resolveLinkTap(Offset localPosition) {
    final resolveLinkTap = widget.resolveLinkTap;
    final onLinkTap = widget.onLinkTap;
    if (resolveLinkTap == null || onLinkTap == null) {
      return null;
    }
    return resolveLinkTap(localPosition);
  }

  void _clearPendingLinkTap() {
    _pendingLinkTap = null;
  }
}
