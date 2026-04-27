// Adapted from package:xterm 4.0.0 gesture detector internals used by
// TerminalView. Keep this aligned with the pinned xterm dependency when
// upgrading.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class MonkeyTerminalGestureDetector extends StatefulWidget {
  const MonkeyTerminalGestureDetector({
    super.key,
    this.child,
    this.onSingleTapUp,
    this.onTapDown,
    this.onTapCancel,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressUp,
    this.onDragStart,
    this.onDragUpdate,
    this.onTouchScrollStart,
    this.onTouchScrollUpdate,
    this.onTouchScrollEnd,
    this.onDoubleTapDown,
    this.shouldBypassDoubleTap,
  });

  final Widget? child;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapCancelCallback? onTapCancel;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onDoubleTapDown;

  /// Returns true when the current tap should not be treated as part of a
  /// double tap gesture even if it falls within the standard slop window.
  final bool Function()? shouldBypassDoubleTap;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final GestureLongPressStartCallback? onLongPressStart;

  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;

  final GestureLongPressUpCallback? onLongPressUp;

  final GestureDragStartCallback? onDragStart;

  final GestureDragUpdateCallback? onDragUpdate;

  final GestureDragStartCallback? onTouchScrollStart;

  final GestureDragUpdateCallback? onTouchScrollUpdate;

  final GestureDragEndCallback? onTouchScrollEnd;

  @override
  State<MonkeyTerminalGestureDetector> createState() =>
      _MonkeyTerminalGestureDetectorState();
}

class _MonkeyTerminalGestureDetectorState
    extends State<MonkeyTerminalGestureDetector> {
  Timer? _doubleTapTimer;

  Offset? _lastTapOffset;

  // True if a second tap down of a double tap is detected. Used to discard
  // subsequent tap up / tap hold of the same tap.
  bool _isDoubleTap = false;

  // The down handler is force-run on success of a single tap and optimistically
  // run before a long press success.
  void _handleTapDown(TapDownDetails details) {
    widget.onTapDown?.call(details);
    final shouldBypassDoubleTap = widget.shouldBypassDoubleTap?.call() ?? false;
    if (shouldBypassDoubleTap) {
      _clearDoubleTapState();
      return;
    }

    if (_doubleTapTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition)) {
      // If there was already a previous tap, the second down hold/tap is a
      // double tap down.
      widget.onDoubleTapDown?.call(details);

      _doubleTapTimer!.cancel();
      _doubleTapTimeout();
      _isDoubleTap = true;
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isDoubleTap) {
      widget.onSingleTapUp?.call(details);
      _lastTapOffset = details.globalPosition;
      _doubleTapTimer?.cancel();
      _doubleTapTimer = Timer(kDoubleTapTimeout, _doubleTapTimeout);
    }
    _isDoubleTap = false;
  }

  void _clearDoubleTapState() {
    _doubleTapTimer?.cancel();
    _doubleTapTimer = null;
    _lastTapOffset = null;
    _isDoubleTap = false;
  }

  void _doubleTapTimeout() {
    _doubleTapTimer = null;
    _lastTapOffset = null;
  }

  bool _isWithinDoubleTapTolerance(Offset secondTapOffset) {
    if (_lastTapOffset == null) {
      return false;
    }

    final difference = secondTapOffset - _lastTapOffset!;
    return difference.distance <= kDoubleTapSlop;
  }

  @override
  void dispose() {
    _doubleTapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gestures = <Type, GestureRecognizerFactory>{};

    gestures[TapGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(debugOwner: this),
          (TapGestureRecognizer instance) {
            instance
              ..onTapDown = _handleTapDown
              ..onTapUp = _handleTapUp
              ..onTapCancel = widget.onTapCancel
              ..onSecondaryTapDown = widget.onSecondaryTapDown
              ..onSecondaryTapUp = widget.onSecondaryTapUp
              ..onTertiaryTapDown = widget.onTertiaryTapDown
              ..onTertiaryTapUp = widget.onTertiaryTapUp;
          },
        );

    if (widget.onLongPressStart != null ||
        widget.onLongPressMoveUpdate != null ||
        widget.onLongPressUp != null) {
      gestures[LongPressGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              debugOwner: this,
              supportedDevices: {
                PointerDeviceKind.touch,
                // PointerDeviceKind.mouse, // for debugging purposes only
              },
            ),
            (LongPressGestureRecognizer instance) {
              instance
                ..onLongPressStart = widget.onLongPressStart
                ..onLongPressMoveUpdate = widget.onLongPressMoveUpdate
                ..onLongPressUp = widget.onLongPressUp;
            },
          );
    }

    if (widget.onDragStart != null || widget.onDragUpdate != null) {
      gestures[PanGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(
              debugOwner: this,
              supportedDevices: <PointerDeviceKind>{PointerDeviceKind.mouse},
            ),
            (PanGestureRecognizer instance) {
              instance
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = widget.onDragStart
                ..onUpdate = widget.onDragUpdate;
            },
          );
    }

    if (widget.onTouchScrollStart != null ||
        widget.onTouchScrollUpdate != null ||
        widget.onTouchScrollEnd != null) {
      gestures[VerticalDragGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(
              debugOwner: this,
              supportedDevices: <PointerDeviceKind>{PointerDeviceKind.touch},
            ),
            (VerticalDragGestureRecognizer instance) {
              instance
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = widget.onTouchScrollStart
                ..onUpdate = widget.onTouchScrollUpdate
                ..onEnd = widget.onTouchScrollEnd;
            },
          );
    }

    return RawGestureDetector(
      gestures: gestures,
      excludeFromSemantics: true,
      child: widget.child,
    );
  }
}
