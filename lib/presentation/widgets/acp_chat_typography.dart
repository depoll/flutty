import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Supplies the monospace face used by native-agent machine content.
///
/// Code, diffs, paths, tool output, and status labels inherit the configured
/// terminal face. Conversation prose and prompt input retain the app's
/// proportional body typography.
class AcpChatTypography extends InheritedWidget {
  /// Creates an ACP typography scope.
  const AcpChatTypography({
    required this.monoStyle,
    required super.child,
    super.key,
  });

  /// Base monospace style for machine-authored agent content.
  final TextStyle monoStyle;

  /// Resolves the scoped native-agent machine-content style.
  static TextStyle monoStyleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AcpChatTypography>()
          ?.monoStyle ??
      FluttyTheme.monoStyle;

  @override
  bool updateShouldNotify(AcpChatTypography oldWidget) =>
      monoStyle != oldWidget.monoStyle;
}
