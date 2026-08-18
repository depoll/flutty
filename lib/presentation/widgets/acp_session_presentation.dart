/// Shared, content-safe presentation helpers for rendering ACP session
/// metadata across the MonkeyMux navigator, session switcher, and chat screen.
///
/// None of these helpers persist or log transcript content; they only format
/// already-in-memory identifiers, coarse status, and timestamps for display.
library;

import 'package:flutter/material.dart';

import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_updates.dart';

/// A short, mono status label plus a color role for an ACP connection status.
@immutable
class AcpStatusDisplay {
  /// Creates a status display descriptor.
  const AcpStatusDisplay({
    required this.label,
    required this.icon,
    required this.tone,
    this.progressFraction,
    this.indeterminate = false,
    this.needsInput = false,
    this.isReady = false,
  });

  /// Lowercase, terminal-native status label (e.g. `ready`, `reconnecting`).
  final String label;

  /// Status icon paired with the label so color is never the sole signal.
  final IconData icon;

  /// Semantic tone used to resolve a theme color.
  final AcpStatusTone tone;

  /// Determinate progress from zero to one when the agent exposes a plan.
  final double? progressFraction;

  /// Whether work is active without a determinate progress value.
  final bool indeterminate;

  /// Whether the session is blocked on a local user decision.
  final bool needsInput;

  /// Whether the agent is connected and idle, ready for another prompt.
  final bool isReady;
}

/// Semantic tone for a status, resolved to a concrete color from the theme.
enum AcpStatusTone {
  /// Active / healthy.
  active,

  /// Neutral / idle.
  neutral,

  /// At-risk / transitional.
  warning,

  /// Failed / terminal error.
  error,
}

/// Resolves a [tone] to a concrete color from [scheme], never using color as
/// the only signal (labels and icons always accompany it).
Color acpStatusColor(ColorScheme scheme, AcpStatusTone tone) => switch (tone) {
  AcpStatusTone.active => scheme.primary,
  AcpStatusTone.neutral => scheme.onSurfaceVariant,
  AcpStatusTone.warning => scheme.tertiary,
  AcpStatusTone.error => scheme.error,
};

/// Maps a coarse [status] onto a display descriptor.
AcpStatusDisplay acpStatusDisplay(AcpConnectionStatus status) =>
    switch (status) {
      AcpConnectionStatus.idle => const AcpStatusDisplay(
        label: 'idle',
        icon: Icons.circle_outlined,
        tone: AcpStatusTone.neutral,
      ),
      AcpConnectionStatus.connecting => const AcpStatusDisplay(
        label: 'connecting',
        icon: Icons.sync,
        tone: AcpStatusTone.warning,
      ),
      AcpConnectionStatus.initializing => const AcpStatusDisplay(
        label: 'initializing',
        icon: Icons.sync,
        tone: AcpStatusTone.warning,
      ),
      AcpConnectionStatus.authenticationRequired => const AcpStatusDisplay(
        label: 'auth required',
        icon: Icons.lock_outline,
        tone: AcpStatusTone.warning,
      ),
      AcpConnectionStatus.ready => const AcpStatusDisplay(
        label: 'ready',
        icon: Icons.check_circle_outline,
        tone: AcpStatusTone.active,
        isReady: true,
      ),
      AcpConnectionStatus.reconnecting => const AcpStatusDisplay(
        label: 'reconnecting',
        icon: Icons.sync_problem,
        tone: AcpStatusTone.warning,
      ),
      AcpConnectionStatus.detached => const AcpStatusDisplay(
        label: 'detached',
        icon: Icons.pause_circle_outline,
        tone: AcpStatusTone.neutral,
      ),
      AcpConnectionStatus.bridgeExpired => const AcpStatusDisplay(
        label: 'expired',
        icon: Icons.error_outline,
        tone: AcpStatusTone.error,
      ),
      AcpConnectionStatus.providerExited => const AcpStatusDisplay(
        label: 'exited',
        icon: Icons.error_outline,
        tone: AcpStatusTone.error,
      ),
      AcpConnectionStatus.failed => const AcpStatusDisplay(
        label: 'failed',
        icon: Icons.error_outline,
        tone: AcpStatusTone.error,
      ),
      AcpConnectionStatus.closed => const AcpStatusDisplay(
        label: 'closed',
        icon: Icons.remove_circle_outline,
        tone: AcpStatusTone.neutral,
      ),
    };

/// Resolves connection, prompt-turn, permission, and plan state into one
/// terminal-like activity descriptor. User decisions take priority over active
/// work so a background native session cannot silently wait for attention.
AcpStatusDisplay acpSessionActivityDisplay(AcpSessionState session) {
  if (session.status != AcpConnectionStatus.ready) {
    return acpStatusDisplay(session.status);
  }
  if (session.pendingPermissions.isNotEmpty ||
      session.pendingWrites.isNotEmpty) {
    return const AcpStatusDisplay(
      label: 'waiting for input',
      icon: Icons.pending_actions,
      tone: AcpStatusTone.warning,
      needsInput: true,
    );
  }

  switch (session.promptStatus) {
    case AcpPromptStatus.idle:
      return acpStatusDisplay(AcpConnectionStatus.ready);
    case AcpPromptStatus.sending:
      return const AcpStatusDisplay(
        label: 'sending',
        icon: Icons.arrow_upward_rounded,
        tone: AcpStatusTone.active,
        indeterminate: true,
      );
    case AcpPromptStatus.streaming:
      final plan = session.plan;
      final progress = plan.isEmpty
          ? null
          : plan
                    .where((entry) => entry.status == AcpPlanStatus.completed)
                    .length /
                plan.length;
      return AcpStatusDisplay(
        label: 'working',
        icon: Icons.auto_awesome,
        tone: AcpStatusTone.active,
        progressFraction: progress,
        indeterminate: progress == null,
      );
    case AcpPromptStatus.cancelling:
      return const AcpStatusDisplay(
        label: 'cancelling',
        icon: Icons.stop_circle_outlined,
        tone: AcpStatusTone.warning,
        indeterminate: true,
      );
  }
}

/// Returns a compact, content-safe working-directory summary.
///
/// Home is shown as `~`; other paths keep their final segment prefixed with a
/// leading `…/` when they are nested, so a long absolute path never dominates a
/// row. The full path is never logged; it is display-only.
String acpCwdSummary(String? cwd) {
  final trimmed = cwd?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == '~' || trimmed == '~/') {
    return '~';
  }
  final normalized = trimmed.endsWith('/') && trimmed.length > 1
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    return normalized;
  }
  final last = segments.last;
  return segments.length > 1
      ? '…/$last'
      : (normalized.startsWith('/') ? '/$last' : last);
}

/// Formats a coarse, human-friendly "time ago" label from [instant] to [now].
String acpRelativeTime(DateTime instant, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  var delta = reference.difference(instant);
  if (delta.isNegative) {
    delta = Duration.zero;
  }
  if (delta.inSeconds < 45) {
    return 'just now';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes}m ago';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours}h ago';
  }
  return '${delta.inDays}d ago';
}

/// A short one-line title for a session, preferring the agent-reported title
/// and otherwise the provider label.
String acpSessionDisplayTitle(AcpSessionState session) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  return session.providerLabel;
}
