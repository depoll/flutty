import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Compact identity badge distinguishing native ACP windows from terminals.
class AcpNativeBadge extends StatelessWidget {
  /// Creates a native-agent identity badge using [color] for its accent.
  const AcpNativeBadge({required this.color, super.key});

  /// Accent derived from the live native-agent activity state.
  final Color color;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Native agent',
    child: Semantics(
      label: 'Native agent',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: color.withAlpha(24),
          border: Border.all(color: color.withAlpha(110)),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          'NATIVE',
          style: FluttyTheme.monoStyle.copyWith(
            color: color,
            fontSize: 8,
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    ),
  );
}
