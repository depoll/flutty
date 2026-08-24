import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';

/// Renders a status, stop-reason, or error entry as a compact, icon-tagged
/// line.
///
/// Severity is conveyed with both an icon and colour so it is legible without
/// relying on colour alone.
class AcpStatusEntryView extends StatelessWidget {
  /// Creates a status entry view.
  const AcpStatusEntryView({required this.entry, super.key});

  /// The status entry to render.
  final AcpStatusEntry entry;

  ({IconData icon, Color color}) _visual(ColorScheme scheme) =>
      switch (entry.severity) {
        AcpStatusSeverity.info => (
          icon: Icons.info_outline,
          color: scheme.onSurfaceVariant,
        ),
        AcpStatusSeverity.warning => (
          icon: Icons.warning_amber_rounded,
          color: scheme.tertiary,
        ),
        AcpStatusSeverity.error => (
          icon: Icons.error_outline,
          color: scheme.error,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visual = _visual(scheme);
    final detail = entry.detail;

    return Semantics(
      container: true,
      label: '${entry.severity.name}: ${entry.message}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(visual.icon, size: 16, color: visual.color),
          ),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: visual.color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail != null && detail.isNotEmpty)
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
