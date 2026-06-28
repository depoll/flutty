import 'package:flutter/material.dart';

/// A connection-status indicator that conveys state by **shape** (a filled dot
/// when connected, an outlined ring otherwise) and a text tooltip/label — never
/// by color alone — so it stays legible to color-blind users.
class ConnectionStatusDot extends StatelessWidget {
  /// Creates a [ConnectionStatusDot].
  const ConnectionStatusDot({
    required this.isConnected,
    this.isConnecting = false,
    this.size = 9,
    super.key,
  });

  /// Whether the connection is established.
  final bool isConnected;

  /// Whether a connection attempt is in progress. Ignored when [isConnected].
  final bool isConnecting;

  /// Diameter of the dot in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final (Color color, bool filled, String label) = isConnected
        ? (colorScheme.primary, true, 'Connected')
        : isConnecting
        ? (colorScheme.tertiary, false, 'Connecting')
        : (colorScheme.onSurface.withAlpha(70), false, 'Not connected');

    return Tooltip(
      message: label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? color : Colors.transparent,
          border: filled ? null : Border.all(color: color, width: 1.5),
          boxShadow: filled && isDark
              ? [BoxShadow(color: color.withAlpha(100), blurRadius: 6)]
              : null,
        ),
      ),
    );
  }
}
