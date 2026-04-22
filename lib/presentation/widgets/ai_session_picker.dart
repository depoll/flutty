import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_session_discovery_service.dart';

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

  /// Provider rows stay tappable so users can load or retry on demand.
  bool get isSelectable => true;

  /// Full status text for roomy list tiles.
  String get statusLabel {
    if (hasFailure) return 'Could not load recent sessions';
    if (hasSessions) {
      return '${sessions.length} session${sessions.length == 1 ? '' : 's'}';
    }
    if (isLoading) return 'Loading recent sessions…';
    if (wasAttempted) return 'No recent sessions for this project';
    return 'Tap to view recent sessions';
  }

  /// Compact status text for tighter provider rows.
  String get compactStatusLabel {
    if (hasFailure) return 'error';
    if (hasSessions) return '${sessions.length}';
    if (isLoading) return 'loading';
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

/// Loader callback used by [AiSessionPickerDialog].
typedef AiSessionLoader =
    Stream<DiscoveredSessionsResult> Function(int maxSessions);

/// Loader callback used by [AiSessionProviderList].
typedef AiSessionProviderLoader =
    Stream<DiscoveredSessionsResult> Function(String toolName, int maxSessions);

/// Builder callback used by [AiSessionProviderList].
typedef AiSessionProviderEntryBuilder =
    Widget Function(BuildContext context, AiSessionProviderEntry provider);

/// Stable provider rows that live-update as each provider finishes loading.
class AiSessionProviderList extends StatefulWidget {
  /// Creates a new [AiSessionProviderList].
  const AiSessionProviderList({
    required this.orderedTools,
    required this.loadSessionsForTool,
    required this.itemBuilder,
    this.initialMaxSessions = 6,
    super.key,
  });

  /// Ordered provider names to render.
  final Iterable<String> orderedTools;

  /// Loads recent sessions for a single provider.
  final AiSessionProviderLoader loadSessionsForTool;

  /// Builds each provider row.
  final AiSessionProviderEntryBuilder itemBuilder;

  /// Initial number of sessions to request per provider row.
  final int initialMaxSessions;

  @override
  State<AiSessionProviderList> createState() => _AiSessionProviderListState();
}

class _AiSessionProviderListState extends State<AiSessionProviderList> {
  final Map<String, StreamSubscription<DiscoveredSessionsResult>>
  _subscriptions = <String, StreamSubscription<DiscoveredSessionsResult>>{};
  final Map<String, List<ToolSessionInfo>> _sessionsByTool =
      <String, List<ToolSessionInfo>>{};
  final Set<String> _attemptedTools = <String>{};
  final Set<String> _failedTools = <String>{};
  final Set<String> _loadingTools = <String>{};
  late List<String> _orderedTools;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _orderedTools = widget.orderedTools.toList(growable: false);
    _startLoadingProviders();
  }

  @override
  void didUpdateWidget(covariant AiSessionProviderList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final orderedTools = widget.orderedTools.toList(growable: false);
    if (_sameOrderedTools(_orderedTools, orderedTools) &&
        oldWidget.initialMaxSessions == widget.initialMaxSessions) {
      _orderedTools = orderedTools;
      return;
    }

    if (_sameToolSet(_orderedTools, orderedTools) &&
        oldWidget.initialMaxSessions == widget.initialMaxSessions) {
      return;
    }

    _orderedTools = orderedTools;
    unawaited(_restartLoadingProviders());
  }

  @override
  void dispose() {
    unawaited(_cancelSubscriptions());
    super.dispose();
  }

  bool _sameOrderedTools(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  bool _sameToolSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  Future<void> _restartLoadingProviders() async {
    await _cancelSubscriptions();
    if (!mounted) return;
    setState(() {
      final orderedToolSet = _orderedTools.toSet();
      _sessionsByTool.removeWhere(
        (toolName, _) => !orderedToolSet.contains(toolName),
      );
      _attemptedTools.removeWhere(
        (toolName) => !orderedToolSet.contains(toolName),
      );
      _failedTools.removeWhere(
        (toolName) => !orderedToolSet.contains(toolName),
      );
      _loadingTools.clear();
    });
    _startLoadingProviders();
  }

  Future<void> _cancelSubscriptions() async {
    _loadGeneration++;
    final subscriptions = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  void _startLoadingProviders() {
    final generation = _loadGeneration;
    for (final toolName in _orderedTools) {
      final existingSessions = _sessionsByTool[toolName];
      final hasVisibleState =
          (existingSessions?.isNotEmpty ?? false) ||
          _attemptedTools.contains(toolName) ||
          _failedTools.contains(toolName);
      if (!hasVisibleState) {
        _loadingTools.add(toolName);
      }
      _subscriptions[toolName] = widget
          .loadSessionsForTool(toolName, widget.initialMaxSessions)
          .listen(
            (result) {
              if (!mounted || generation != _loadGeneration) return;
              final sessions = result.sessions
                  .where((session) => session.toolName == toolName)
                  .toList(growable: false);
              final wasAttempted =
                  result.attemptedTools.contains(toolName) ||
                  result.failedTools.contains(toolName) ||
                  sessions.isNotEmpty;
              final hadFailure = result.failedTools.contains(toolName);
              const isLoading = false;
              final sessionsChanged = !listEquals(
                _sessionsByTool[toolName],
                sessions,
              );
              final attemptedChanged =
                  _attemptedTools.contains(toolName) != wasAttempted;
              final failureChanged =
                  _failedTools.contains(toolName) != hadFailure;
              final loadingChanged =
                  _loadingTools.contains(toolName) != isLoading;
              if (!sessionsChanged &&
                  !attemptedChanged &&
                  !failureChanged &&
                  !loadingChanged) {
                return;
              }
              setState(() {
                _sessionsByTool[toolName] = sessions;
                if (wasAttempted) {
                  _attemptedTools.add(toolName);
                } else {
                  _attemptedTools.remove(toolName);
                }
                if (hadFailure) {
                  _failedTools.add(toolName);
                } else {
                  _failedTools.remove(toolName);
                }
                _loadingTools.remove(toolName);
              });
            },
            onError: (Object _) {
              if (!mounted || generation != _loadGeneration) return;
              final needsUpdate =
                  !_attemptedTools.contains(toolName) ||
                  !_failedTools.contains(toolName) ||
                  _loadingTools.contains(toolName) ||
                  !_sessionsByTool.containsKey(toolName);
              if (!needsUpdate) {
                _subscriptions.remove(toolName);
                return;
              }
              setState(() {
                _attemptedTools.add(toolName);
                _failedTools.add(toolName);
                _loadingTools.remove(toolName);
                _sessionsByTool.putIfAbsent(
                  toolName,
                  () => const <ToolSessionInfo>[],
                );
              });
              _subscriptions.remove(toolName);
            },
            onDone: () {
              if (!mounted || generation != _loadGeneration) return;
              final needsUpdate =
                  !_attemptedTools.contains(toolName) ||
                  _loadingTools.contains(toolName);
              if (needsUpdate) {
                setState(() {
                  _attemptedTools.add(toolName);
                  _loadingTools.remove(toolName);
                });
              }
              _subscriptions.remove(toolName);
            },
            cancelOnError: true,
          );
    }
  }

  AiSessionProviderEntry _entryForTool(String toolName) =>
      AiSessionProviderEntry(
        toolName: toolName,
        sessions: _sessionsByTool[toolName] ?? const <ToolSessionInfo>[],
        wasAttempted: _attemptedTools.contains(toolName),
        hasFailure: _failedTools.contains(toolName),
        isLoading: _loadingTools.contains(toolName),
      );

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final toolName in _orderedTools)
        widget.itemBuilder(context, _entryForTool(toolName)),
    ],
  );
}

/// Shows a dialog for picking one of a provider's recent sessions.
Future<ToolSessionInfo?> showAiSessionPickerDialog({
  required BuildContext context,
  required String toolName,
  required AiSessionLoader loadSessions,
  int initialMaxSessions = 12,
  int sessionFetchStep = 12,
}) => showDialog<ToolSessionInfo>(
  context: context,
  builder: (context) => AiSessionPickerDialog(
    toolName: toolName,
    loadSessions: loadSessions,
    initialMaxSessions: initialMaxSessions,
    sessionFetchStep: sessionFetchStep,
  ),
);

/// Dialog for picking one of a provider's recent sessions.
class AiSessionPickerDialog extends StatefulWidget {
  /// Creates a new [AiSessionPickerDialog].
  const AiSessionPickerDialog({
    required this.toolName,
    required this.loadSessions,
    this.initialMaxSessions = 12,
    this.sessionFetchStep = 12,
    super.key,
  });

  /// Provider display name.
  final String toolName;

  /// Loads recent sessions for the selected provider.
  final AiSessionLoader loadSessions;

  /// Initial number of sessions to request.
  final int initialMaxSessions;

  /// Step to use when the user asks for more sessions.
  final int sessionFetchStep;

  @override
  State<AiSessionPickerDialog> createState() => _AiSessionPickerDialogState();
}

class _AiSessionPickerDialogState extends State<AiSessionPickerDialog> {
  StreamSubscription<DiscoveredSessionsResult>? _subscription;
  List<ToolSessionInfo>? _sessions;
  String? _error;
  late int _maxSessions;
  int _loadGeneration = 0;
  bool _isLoading = false;
  bool _hasFailure = false;
  bool _canLoadMore = false;

  @override
  void initState() {
    super.initState();
    _maxSessions = widget.initialMaxSessions;
    unawaited(_loadSessions());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final loadGeneration = ++_loadGeneration;
    await _subscription?.cancel();
    _subscription = null;
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _hasFailure = false;
      _canLoadMore = false;
    });

    _subscription = widget
        .loadSessions(_maxSessions)
        .listen(
          (result) {
            if (!mounted || loadGeneration != _loadGeneration) return;
            setState(() {
              _sessions = result.sessions;
              _hasFailure = result.hasFailures;
              _error = result.failureMessage;
            });
          },
          onError: (Object _) {
            if (!mounted || loadGeneration != _loadGeneration) return;
            setState(() {
              _sessions ??= const <ToolSessionInfo>[];
              _hasFailure = true;
              _error = 'Could not load recent AI sessions.';
              _isLoading = false;
              _canLoadMore = false;
            });
            _subscription = null;
          },
          onDone: () {
            if (!mounted || loadGeneration != _loadGeneration) return;
            final sessions = _sessions ?? const <ToolSessionInfo>[];
            setState(() {
              _isLoading = false;
              _canLoadMore = !_hasFailure && sessions.length >= _maxSessions;
            });
            _subscription = null;
          },
          cancelOnError: true,
        );
  }

  void _loadMore() {
    if (_isLoading) return;
    setState(() => _maxSessions += widget.sessionFetchStep);
    unawaited(_loadSessions());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = _sessions ?? const <ToolSessionInfo>[];
    final hasSessions = sessions.isNotEmpty;
    final maxDialogHeight = MediaQuery.sizeOf(context).height * 0.6;

    return AlertDialog(
      title: Text(widget.toolName),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: hasSessions
          ? SizedBox(
              width: double.maxFinite,
              height: maxDialogHeight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Scrollbar(
                      child: ListView.separated(
                        itemCount: sessions.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) => _AiSessionPickerTile(
                          session: sessions[index],
                          onTap: () =>
                              Navigator.of(context).pop(sessions[index]),
                        ),
                      ),
                    ),
                  ),
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                ],
              ),
            )
          : SizedBox(
              width: 420,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: _buildEmptyContent(theme),
              ),
            ),
      actions: [
        if (_canLoadMore)
          TextButton(onPressed: _loadMore, child: const Text('Load more')),
        if (!_isLoading && !hasSessions)
          TextButton(
            onPressed: () => unawaited(_loadSessions()),
            child: const Text('Retry'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildEmptyContent(ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator.adaptive(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Text(
        _error!,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    return Text(
      'No recent sessions found.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
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
