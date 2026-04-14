import 'package:flutter/material.dart';

import '../../domain/models/tmux_state.dart';

/// Compact status badge for a tmux window.
class TmuxWindowStatusBadge extends StatelessWidget {
  /// Creates a new [TmuxWindowStatusBadge].
  const TmuxWindowStatusBadge({required this.window, super.key});

  /// The tmux window whose status is being displayed.
  final TmuxWindow window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = _statusVisual(theme, window);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: visual.backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(visual.icon, size: 12, color: visual.foregroundColor),
            const SizedBox(width: 3),
            Text(
              window.statusLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                color: visual.foregroundColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static _TmuxWindowStatusVisual _statusVisual(
    ThemeData theme,
    TmuxWindow window,
  ) {
    if (window.hasAlert) {
      return _TmuxWindowStatusVisual(
        icon: Icons.notifications_active,
        foregroundColor: theme.colorScheme.error,
        backgroundColor: theme.colorScheme.errorContainer.withAlpha(150),
      );
    }
    if (window.isIdle) {
      return _TmuxWindowStatusVisual(
        icon: Icons.hourglass_bottom,
        foregroundColor: theme.colorScheme.tertiary,
        backgroundColor: theme.colorScheme.tertiaryContainer.withAlpha(170),
      );
    }
    return _TmuxWindowStatusVisual(
      icon: Icons.play_arrow,
      foregroundColor: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.primaryContainer.withAlpha(170),
    );
  }
}

class _TmuxWindowStatusVisual {
  const _TmuxWindowStatusVisual({
    required this.icon,
    required this.foregroundColor,
    required this.backgroundColor,
  });

  final IconData icon;
  final Color foregroundColor;
  final Color backgroundColor;
}
