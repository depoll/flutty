import 'package:flutter/material.dart';

/// Compact identity badge distinguishing native ACP windows from terminals.
class AcpNativeBadge extends StatelessWidget {
  /// Creates a native-agent identity badge using [color] for its accent.
  const AcpNativeBadge({required this.color, this.size = 12, super.key});

  /// Accent derived from the live native-agent activity state.
  final Color color;

  /// Square badge dimension.
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Native agent',
    child: Semantics(
      label: 'Native agent',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Icon(Icons.chat_bubble, size: size * 0.62, color: color),
        ),
      ),
    ),
  );
}
