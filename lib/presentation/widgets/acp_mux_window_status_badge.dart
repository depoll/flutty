import 'package:flutter/material.dart';

import '../../domain/models/acp_session_state.dart';
import 'acp_session_presentation.dart';

/// Compact waiting/running badge for a native ACP mux window.
class AcpMuxWindowStatusBadge extends StatelessWidget {
  /// Creates a badge for a live [session], or a recent-session placeholder.
  const AcpMuxWindowStatusBadge({this.session, super.key});

  /// Live session state. Null denotes a recent, detached reference.
  final AcpSessionState? session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = session == null
        ? const AcpStatusDisplay(
            label: 'recent',
            icon: Icons.history,
            tone: AcpStatusTone.neutral,
          )
        : acpSessionMuxStatusDisplay(session!);
    final (foreground, background) = switch (display.tone) {
      AcpStatusTone.active => (
        theme.colorScheme.onPrimaryContainer,
        theme.colorScheme.primaryContainer,
      ),
      AcpStatusTone.warning => (
        theme.colorScheme.onTertiaryContainer,
        theme.colorScheme.tertiaryContainer,
      ),
      AcpStatusTone.error => (
        theme.colorScheme.onErrorContainer,
        theme.colorScheme.errorContainer,
      ),
      AcpStatusTone.neutral => (
        theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.surfaceContainerHighest,
      ),
    };

    return Semantics(
      label: 'native agent ${display.label}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(display.icon, size: 12, color: foreground),
              const SizedBox(width: 3),
              Text(
                display.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: foreground,
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
