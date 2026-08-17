import 'package:flutter/widgets.dart';

/// Provides CLI-specific touch-scroll behavior without changing terminal input
/// semantics for every mouse-reporting application.
class MonkeyTerminalTouchScrollPolicy extends InheritedWidget {
  /// Creates a policy scope for [child].
  const MonkeyTerminalTouchScrollPolicy({
    required this.coalesce,
    required super.child,
    super.key,
  });

  /// Whether reported touch-wheel input should be coalesced to remote frames.
  final bool coalesce;

  /// Returns the nearest policy, or null when native terminal cadence applies.
  static MonkeyTerminalTouchScrollPolicy? maybeOf(
    BuildContext context,
  ) => context
      .dependOnInheritedWidgetOfExactType<MonkeyTerminalTouchScrollPolicy>();

  @override
  bool updateShouldNotify(MonkeyTerminalTouchScrollPolicy oldWidget) =>
      coalesce != oldWidget.coalesce;
}
