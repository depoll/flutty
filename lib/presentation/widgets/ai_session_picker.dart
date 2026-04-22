import 'package:flutter/material.dart';

import '../../domain/models/tmux_state.dart';

/// Derived UI state for a discovered-session provider row.
class AiSessionProviderEntry {
  /// Creates a new [AiSessionProviderEntry].
  const AiSessionProviderEntry({
    required this.toolName,
    required this.sessions,
    required this.wasAttempted,
    required this.hasFailure,
    required this.isLoading,
  });

  /// Provider display name.
  final String toolName;

  /// Sessions discovered for this provider.
  final List<ToolSessionInfo> sessions;

  /// Whether discovery finished for this provider in the current pass.
  final bool wasAttempted;

  /// Whether discovery failed for this provider.
  final bool hasFailure;

  /// Whether this provider is still pending during the current load.
  final bool isLoading;

  /// Whether the provider currently has at least one discovered session.
  bool get hasSessions => sessions.isNotEmpty;

  /// Whether the provider tile should open a session picker.
  bool get isSelectable => hasSessions;

  /// Full status text for roomy list tiles.
  String get statusLabel {
    if (hasFailure) return 'Could not load recent sessions';
    if (isLoading) return 'Loading recent sessions…';
    if (hasSessions) {
      return '${sessions.length} session${sessions.length == 1 ? '' : 's'}';
    }
    if (wasAttempted) return 'No recent sessions for this project';
    return 'Not loaded yet';
  }

  /// Compact status text for tighter provider rows.
  String get compactStatusLabel {
    if (hasFailure) return 'error';
    if (isLoading) return 'loading';
    if (hasSessions) return '${sessions.length}';
    if (wasAttempted) return 'no recent';
    return '';
  }
}

/// Builds stable provider rows from the current discovery snapshot.
List<AiSessionProviderEntry> buildAiSessionProviderEntries({
  required Iterable<String> orderedTools,
  required Map<String, List<ToolSessionInfo>> groupedSessions,
  required bool isLoading,
  Iterable<String> attemptedTools = const <String>[],
  Iterable<String> failedTools = const <String>[],
}) {
  final attemptedToolSet = attemptedTools.toSet();
  final failedToolSet = failedTools.toSet();

  return orderedTools
      .map(
        (toolName) => AiSessionProviderEntry(
          toolName: toolName,
          sessions: groupedSessions[toolName] ?? const <ToolSessionInfo>[],
          wasAttempted:
              attemptedToolSet.contains(toolName) ||
              failedToolSet.contains(toolName),
          hasFailure: failedToolSet.contains(toolName),
          isLoading:
              isLoading &&
              !attemptedToolSet.contains(toolName) &&
              !failedToolSet.contains(toolName) &&
              !(groupedSessions[toolName]?.isNotEmpty ?? false),
        ),
      )
      .toList(growable: false);
}

/// Returns the icon used for a discovered-session provider.
IconData aiSessionToolIconData(String toolName) => switch (toolName) {
  'Claude Code' => Icons.auto_awesome,
  'Codex' => Icons.code,
  'Copilot CLI' => Icons.flight,
  'Gemini CLI' => Icons.diamond_outlined,
  'OpenCode' => Icons.terminal,
  _ => Icons.smart_toy_outlined,
};

/// Shows a dialog for picking one of a provider's recent sessions.
Future<ToolSessionInfo?> showAiSessionPickerDialog({
  required BuildContext context,
  required String toolName,
  required List<ToolSessionInfo> sessions,
}) => showDialog<ToolSessionInfo>(
  context: context,
  builder: (context) =>
      AiSessionPickerDialog(toolName: toolName, sessions: sessions),
);

/// Dialog for picking one of a provider's recent sessions.
class AiSessionPickerDialog extends StatelessWidget {
  /// Creates a new [AiSessionPickerDialog].
  const AiSessionPickerDialog({
    required this.toolName,
    required this.sessions,
    super.key,
  });

  /// Provider display name.
  final String toolName;

  /// Candidate sessions to choose from.
  final List<ToolSessionInfo> sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxDialogHeight = MediaQuery.sizeOf(context).height * 0.6;

    return AlertDialog(
      title: Text(toolName),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: maxDialogHeight),
        child: SizedBox(
          width: double.maxFinite,
          child: sessions.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Text(
                    'No recent sessions found.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Scrollbar(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (
                          var index = 0;
                          index < sessions.length;
                          index++
                        ) ...[
                          if (index > 0) const Divider(height: 1),
                          _AiSessionPickerTile(
                            session: sessions[index],
                            onTap: () =>
                                Navigator.of(context).pop(sessions[index]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _AiSessionPickerTile extends StatelessWidget {
  const _AiSessionPickerTile({required this.session, required this.onTap});

  final ToolSessionInfo session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      horizontalTitleGap: 12,
      minLeadingWidth: 20,
      leading: Icon(
        aiSessionToolIconData(session.toolName),
        size: 20,
        color: theme.colorScheme.primary,
      ),
      title: Text(
        session.summary ?? session.sessionId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        session.lastUpdatedLabel.isNotEmpty
            ? session.lastUpdatedLabel
            : session.toolName,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
    );
  }
}
