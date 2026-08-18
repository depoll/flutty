import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Supplies the monospace face used by the native agent conversation surface.
///
/// ACP widgets keep their own semantic sizes and weights, while inheriting the
/// same configured font face as the terminal. Outside an agent conversation,
/// they retain the app's default monospace style.
class AcpChatTypography extends InheritedWidget {
  /// Creates an ACP typography scope.
  const AcpChatTypography({
    required this.monoStyle,
    required super.child,
    super.key,
  });

  /// Base monospace style for agent content.
  final TextStyle monoStyle;

  /// Resolves the scoped native-agent monospace style.
  static TextStyle monoStyleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AcpChatTypography>()
          ?.monoStyle ??
      FluttyTheme.monoStyle;

  @override
  bool updateShouldNotify(AcpChatTypography oldWidget) =>
      monoStyle != oldWidget.monoStyle;
}
