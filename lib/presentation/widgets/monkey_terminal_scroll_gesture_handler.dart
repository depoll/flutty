// ignore_for_file: implementation_imports, public_member_api_docs, always_put_required_named_parameters_first, type_annotate_public_apis, use_setters_to_change_properties

import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/ui/infinite_scroll_view.dart';

import 'terminal_scroll_mouse_input.dart';

/// Handles alt-buffer scrolling while preserving trackpad gesture position.
class MonkeyTerminalScrollGestureHandler extends StatefulWidget {
  const MonkeyTerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    required this.child,
  });

  final Terminal terminal;

  /// Returns the cell offset for the pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  final Widget child;

  @override
  State<MonkeyTerminalScrollGestureHandler> createState() =>
      _MonkeyTerminalScrollGestureHandlerState();
}

class _MonkeyTerminalScrollGestureHandlerState
    extends State<MonkeyTerminalScrollGestureHandler> {
  /// Whether the application is in alternate screen buffer. If false, then this
  /// widget does nothing.
  var isAltBuffer = false;

  /// Tracks the last scroll offset reported by [InfiniteScrollView].
  var lastScrollOffset = 0.0;

  /// Accumulates partial scroll deltas so reversing direction still requires a
  /// full line-height of movement before another terminal wheel event is sent.
  var scrollRemainder = 0.0;

  /// This variable tracks the last offset where the scroll gesture started.
  /// Used to calculate the cell offset of the terminal mouse event.
  var lastPointerPosition = Offset.zero;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    isAltBuffer = widget.terminal.isUsingAltBuffer;
    super.initState();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MonkeyTerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      _resetScrollTracking();
    }
    super.didUpdateWidget(oldWidget);
  }

  void _onTerminalUpdated() {
    if (isAltBuffer != widget.terminal.isUsingAltBuffer) {
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      _resetScrollTracking();
      setState(() {});
    }
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  void _sendScrollEvent(bool up) {
    final position = widget.getCellOffset(lastPointerPosition);
    final button = up
        ? TerminalMouseButton.wheelUp
        : TerminalMouseButton.wheelDown;

    final handled = sendTerminalScrollMouseInput(
      terminal: widget.terminal,
      button: button,
      position: position,
    );

    if (!handled && widget.simulateScroll) {
      widget.terminal.keyInput(
        up ? TerminalKey.arrowUp : TerminalKey.arrowDown,
      );
    }
  }

  void _resetScrollTracking() {
    lastScrollOffset = 0;
    scrollRemainder = 0;
  }

  void _onScroll(double offset) {
    final lineHeight = widget.getLineHeight();
    if (lineHeight <= 0) {
      return;
    }

    scrollRemainder += offset - lastScrollOffset;
    lastScrollOffset = offset;

    while (scrollRemainder.abs() >= lineHeight) {
      final scrollUp = scrollRemainder < 0;
      _sendScrollEvent(scrollUp);
      scrollRemainder += scrollUp ? lineHeight : -lineHeight;
    }
  }

  void _rememberPointerPosition(Offset position) {
    lastPointerPosition = position;
  }

  @override
  Widget build(BuildContext context) {
    if (!isAltBuffer) {
      return widget.child;
    }

    return Listener(
      onPointerSignal: (event) => _rememberPointerPosition(event.localPosition),
      onPointerHover: (event) => _rememberPointerPosition(event.localPosition),
      onPointerMove: (event) => _rememberPointerPosition(event.localPosition),
      onPointerDown: (event) => _rememberPointerPosition(event.localPosition),
      onPointerPanZoomStart: (event) =>
          _rememberPointerPosition(event.localPosition),
      onPointerPanZoomUpdate: (event) =>
          _rememberPointerPosition(event.localPosition + event.pan),
      child: InfiniteScrollView(onScroll: _onScroll, child: widget.child),
    );
  }
}
