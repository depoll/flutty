import 'package:flutter/material.dart';

/// Small badge used to label MonkeySSH Pro features.
class PremiumBadge extends StatelessWidget {
  /// Creates a new [PremiumBadge].
  const PremiumBadge({this.label = 'Pro', super.key});

  /// Badge label text.
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.primary.withAlpha(24),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
