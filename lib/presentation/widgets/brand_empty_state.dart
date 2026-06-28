import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'cursor_block.dart';

/// A secondary action shown beneath the primary call-to-action of a
/// [BrandEmptyState].
class BrandEmptyAction {
  /// Creates a [BrandEmptyAction].
  const BrandEmptyAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// Leading icon.
  final IconData icon;

  /// Button label.
  final String label;

  /// Tap handler.
  final VoidCallback onTap;
}

/// The MonkeySSH brand empty state: a faux shell-prompt mark with a live
/// cursor, a mono title, one dry line of copy, and a single clear call to
/// action.
///
/// Empty states are one of the few places the app's personality is allowed to
/// show. Keep [message] dry and useful — the voice of a good CLI — never a
/// joke, and never on a surface the user reaches under pressure.
class BrandEmptyState extends StatelessWidget {
  /// Creates a [BrandEmptyState].
  const BrandEmptyState({
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimary,
    this.primaryIcon = Icons.add,
    this.secondaryActions = const [],
    super.key,
  });

  /// Mono title stating the fact plainly, e.g. `no hosts yet`.
  final String title;

  /// One dry line of terminal-native copy beneath the title.
  final String message;

  /// Primary call-to-action label. When null (or [onPrimary] is null) no
  /// primary button is shown.
  final String? primaryLabel;

  /// Primary call-to-action handler.
  final VoidCallback? onPrimary;

  /// Primary call-to-action icon.
  final IconData primaryIcon;

  /// Optional secondary actions shown beneath the primary call-to-action.
  final List<BrandEmptyAction> secondaryActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Crafted mono mark: a faux shell prompt with a live cursor.
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'monkey@ssh',
                style: FluttyTheme.displayMono(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface.withAlpha(160),
                  letterSpacing: 0,
                ),
              ),
              TextSpan(
                text: r':~$',
                style: FluttyTheme.displayMono(
                  fontSize: 15,
                  color: colorScheme.onSurface.withAlpha(110),
                  letterSpacing: 0,
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: CursorBlock(
                    size: 16,
                    color: colorScheme.onSurface.withAlpha(170),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: FluttyTheme.spacingLg),
        Text(
          title,
          textAlign: TextAlign.center,
          style: FluttyTheme.displayMono(
            color: colorScheme.onSurface.withAlpha(230),
          ),
        ),
        const SizedBox(height: FluttyTheme.spacingSm),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurface.withAlpha(140),
          ),
        ),
        if (primaryLabel != null && onPrimary != null) ...[
          const SizedBox(height: FluttyTheme.spacingXl),
          FilledButton.icon(
            onPressed: onPrimary,
            icon: Icon(primaryIcon, size: 18),
            label: Text(primaryLabel!),
          ),
        ],
        if (secondaryActions.isNotEmpty) ...[
          const SizedBox(height: FluttyTheme.spacingSm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: FluttyTheme.spacingSm,
            runSpacing: FluttyTheme.spacingSm,
            children: [
              for (final action in secondaryActions)
                TextButton.icon(
                  onPressed: action.onTap,
                  icon: Icon(action.icon, size: 18),
                  label: Text(action.label),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
