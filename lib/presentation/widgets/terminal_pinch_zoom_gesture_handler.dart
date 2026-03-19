import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/widgets.dart';

/// Reports two-finger touch pinch gestures without stealing single-finger drags.
///
/// This wraps terminal content with a [Listener] instead of a scale
/// [GestureDetector] so normal touch scrolling can keep flowing to descendant
/// scrollables. Once two touch pointers are active, the child is temporarily
/// absorbed until the pinch ends.
class TerminalPinchZoomGestureHandler extends StatefulWidget {
  /// Creates a [TerminalPinchZoomGestureHandler].
  const TerminalPinchZoomGestureHandler({
    required this.child,
    this.onPinchStart,
    this.onPinchUpdate,
    this.onPinchEnd,
    super.key,
  });

  /// Called when a two-finger touch pinch begins.
  final VoidCallback? onPinchStart;

  /// Called when the active pinch scale changes.
  final ValueChanged<double>? onPinchUpdate;

  /// Called when the active pinch ends.
  final VoidCallback? onPinchEnd;

  /// The widget below this handler in the tree.
  final Widget child;

  @override
  State<TerminalPinchZoomGestureHandler> createState() =>
      _TerminalPinchZoomGestureHandlerState();
}

class _TerminalPinchZoomGestureHandlerState
    extends State<TerminalPinchZoomGestureHandler> {
  final Map<int, Offset> _trackedTouchPointers = <int, Offset>{};

  double? _initialDistance;
  bool _isPinching = false;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _handlePointerDown,
    onPointerMove: _handlePointerMove,
    onPointerUp: _handlePointerFinished,
    onPointerCancel: _handlePointerFinished,
    child: AbsorbPointer(absorbing: _isPinching, child: widget.child),
  );

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch ||
        _trackedTouchPointers.length >= 2) {
      return;
    }

    _trackedTouchPointers[event.pointer] = event.position;
    if (_trackedTouchPointers.length != 2) {
      return;
    }

    final initialDistance = _currentTrackedDistance;
    if (initialDistance == null || initialDistance == 0) {
      return;
    }

    _initialDistance = initialDistance;
    setState(() {
      _isPinching = true;
    });
    widget.onPinchStart?.call();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_trackedTouchPointers.containsKey(event.pointer)) {
      return;
    }

    _trackedTouchPointers[event.pointer] = event.position;
    if (!_isPinching) {
      return;
    }

    final initialDistance = _initialDistance;
    final currentDistance = _currentTrackedDistance;
    if (initialDistance == null ||
        initialDistance == 0 ||
        currentDistance == null) {
      return;
    }

    widget.onPinchUpdate?.call(currentDistance / initialDistance);
  }

  void _handlePointerFinished(PointerEvent event) {
    final removedPointer = _trackedTouchPointers.remove(event.pointer);
    if (removedPointer == null || !_isPinching) {
      return;
    }

    _initialDistance = null;
    setState(() {
      _isPinching = false;
    });
    widget.onPinchEnd?.call();
  }

  double? get _currentTrackedDistance {
    if (_trackedTouchPointers.length < 2) {
      return null;
    }

    final positions = _trackedTouchPointers.values.toList(growable: false);
    return (positions[0] - positions[1]).distance;
  }
}
