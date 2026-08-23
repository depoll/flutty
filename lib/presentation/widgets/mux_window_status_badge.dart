import 'package:flutter/material.dart';

/// Shared visual treatment for native and terminal MonkeyMux status pills.
class MuxWindowStatusBadge extends StatelessWidget {
  /// Creates a compact status pill with explicit semantic colors.
  const MuxWindowStatusBadge({
    required this.semanticsLabel,
    required this.label,
    required this.icon,
    required this.foregroundColor,
    required this.backgroundColor,
    super.key,
  });

  /// Screen-reader label that includes the kind of mux window.
  final String semanticsLabel;

  /// Short visible status label.
  final String label;

  /// Status icon shown before [label].
  final IconData icon;

  /// High-contrast content color.
  final Color foregroundColor;

  /// Semantic container color.
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: semanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: foregroundColor),
              const SizedBox(width: 3),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
