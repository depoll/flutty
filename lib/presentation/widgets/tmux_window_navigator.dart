import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/tmux_service.dart';
import '../widgets/premium_badge.dart';
import 'ai_session_picker.dart';
import 'tmux_window_status_badge.dart';

const _tmuxNavigatorDenseVisualDensity = VisualDensity(vertical: -2);
const _tmuxNavigatorTilePadding = EdgeInsets.symmetric(horizontal: 16);
const _tmuxNavigatorGroupTilePadding = EdgeInsets.only(left: 16, right: 16);
const _tmuxNavigatorMaxHeightFactor = 0.48;
const _tmuxNavigatorMaxHeightCap = 440.0;
const _tmuxToolPickerMaxHeightFactor = 0.36;
const _tmuxToolPickerMaxHeightCap = 320.0;

List<AgentLaunchTool> _orderedAgentLaunchTools(
  Iterable<AgentLaunchTool> tools, {
  AgentLaunchTool? preferredTool,
}) {
  final ordered = tools.toList(growable: false);
  if (preferredTool == null) {
    return ordered;
  }

  final preferredIndex = ordered.indexOf(preferredTool);
  if (preferredIndex <= 0) {
    return ordered;
  }

  return <AgentLaunchTool>[
    ordered[preferredIndex],
    ...ordered.take(preferredIndex),
    ...ordered.skip(preferredIndex + 1),
  ];
}

/// Shows the tmux window navigator bottom sheet.
///
/// Returns the action the user selected, or `null` if dismissed.
Future<TmuxNavigatorAction?> showTmuxNavigator({
  required BuildContext context,
  required WidgetRef ref,
  required SshSession session,
  required String tmuxSessionName,
  required bool isProUser,
  String? scopeWorkingDirectory,
}) => showModalBottomSheet<TmuxNavigatorAction>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _TmuxNavigatorSheet(
    session: session,
    tmuxSessionName: tmuxSessionName,
    isProUser: isProUser,
    ref: ref,
    scopeWorkingDirectory: scopeWorkingDirectory,
  ),
);

/// An action selected from the tmux navigator.
sealed class TmuxNavigatorAction {
  /// Creates a new [TmuxNavigatorAction].
  const TmuxNavigatorAction();
}

/// Switch the current terminal to a different tmux window.
class TmuxSwitchWindowAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxSwitchWindowAction].
  const TmuxSwitchWindowAction(this.windowIndex);

  /// The window index to switch to.
  final int windowIndex;
}

/// Create a new tmux window, optionally running a command.
class TmuxNewWindowAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxNewWindowAction].
  const TmuxNewWindowAction({this.command, this.windowName});

  /// Optional command to run in the new window.
  final String? command;

  /// Optional name for the new window.
  final String? windowName;
}

/// Resume an AI tool session in a new tmux window.
class TmuxResumeSessionAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxResumeSessionAction].
  const TmuxResumeSessionAction(this.resumeCommand, {this.workingDirectory});

  /// The full resume command to run.
  final String resumeCommand;

  /// The working directory to start in.
  final String? workingDirectory;
}

/// Close a tmux window.
class TmuxCloseWindowAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxCloseWindowAction].
  const TmuxCloseWindowAction(this.windowIndex);

  /// The window index to close.
  final int windowIndex;
}

class _TmuxNavigatorSheet extends StatefulWidget {
  const _TmuxNavigatorSheet({
    required this.session,
    required this.tmuxSessionName,
    required this.isProUser,
    required this.ref,
    this.scopeWorkingDirectory,
  });

  final SshSession session;
  final String tmuxSessionName;
  final bool isProUser;
  final WidgetRef ref;
  final String? scopeWorkingDirectory;

  @override
  State<_TmuxNavigatorSheet> createState() => _TmuxNavigatorSheetState();
}

class _TmuxNavigatorSheetState extends State<_TmuxNavigatorSheet> {
  /// Maximum number of recent sessions to show per tool.
  static const _maxSessionsPerTool = 16;

  List<TmuxWindow>? _windows;
  List<ToolSessionInfo>? _recentSessions;
  Set<String> _attemptedSessionTools = const <String>{};
  Set<String> _failedSessionTools = const <String>{};
  AgentLaunchTool? _preferredLaunchTool;
  Future<Set<AgentLaunchTool>>? _installedToolsFuture;
  StreamSubscription<DiscoveredSessionsResult>? _sessionDiscoverySubscription;
  StreamSubscription<void>? _windowChangeSubscription;
  bool _isLoadingWindows = true;
  bool _isLoadingSessions = false;
  bool _showRecentSessions = false;
  String? _sessionLoadError;
  String? _error;
  int _sessionLoadGeneration = 0;
  bool _loadingWindows = false;
  bool _pendingWindowReload = false;

  TmuxService get _tmux => widget.ref.read(tmuxServiceProvider);

  AgentSessionDiscoveryService get _discovery =>
      widget.ref.read(agentSessionDiscoveryServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferredLaunchTool());
    _installedToolsFuture = _tmux.detectInstalledAgentTools(widget.session);
    _windowChangeSubscription = _tmux
        .watchWindowChanges(widget.session, widget.tmuxSessionName)
        .listen((_) {
          if (!mounted) return;
          _loadWindows();
        });
    _loadWindows();
  }

  @override
  void didUpdateWidget(covariant _TmuxNavigatorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.hostId != widget.session.hostId) {
      unawaited(_loadPreferredLaunchTool());
    }
  }

  @override
  void dispose() {
    unawaited(_sessionDiscoverySubscription?.cancel());
    unawaited(_windowChangeSubscription?.cancel());
    super.dispose();
  }

  Future<void> _loadPreferredLaunchTool() async {
    final hostId = widget.session.hostId;
    final preset = await widget.ref
        .read(agentLaunchPresetServiceProvider)
        .getPresetForHost(hostId);
    if (!mounted || widget.session.hostId != hostId) return;

    final preferredLaunchTool = preset?.tool;
    if (_preferredLaunchTool == preferredLaunchTool) return;
    setState(() => _preferredLaunchTool = preferredLaunchTool);
  }

  Future<void> _loadWindows() async {
    if (_loadingWindows) {
      _pendingWindowReload = true;
      return;
    }
    _loadingWindows = true;
    try {
      final windows = await _tmux.listWindows(
        widget.session,
        widget.tmuxSessionName,
      );
      if (!mounted) return;
      setState(() {
        _windows = windows;
        _isLoadingWindows = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoadingWindows = false;
      });
    } finally {
      _loadingWindows = false;
      if (_pendingWindowReload) {
        _pendingWindowReload = false;
        unawaited(_loadWindows());
      }
    }
  }

  Future<void> _loadRecentSessions() async {
    if (_isLoadingSessions || _recentSessions != null) return;
    final loadGeneration = ++_sessionLoadGeneration;
    await _sessionDiscoverySubscription?.cancel();
    _sessionDiscoverySubscription = null;
    setState(() {
      _isLoadingSessions = true;
      _sessionLoadError = null;
      _failedSessionTools = const <String>{};
    });

    try {
      // Get working directory from the active window if available.
      final activeWindow = _windows?.where((w) => w.isActive).firstOrNull;
      final scopeWorkingDirectory =
          widget.scopeWorkingDirectory ??
          resolveAgentSessionScopeWorkingDirectory(
            activeWorkingDirectory: activeWindow?.currentPath,
            sessionWorkingDirectory: widget.session.workingDirectory,
          );
      _sessionDiscoverySubscription = _discovery
          .discoverSessionsStream(
            widget.session,
            workingDirectory: scopeWorkingDirectory,
            maxPerTool: _maxSessionsPerTool,
          )
          .listen(
            (result) {
              if (!mounted || loadGeneration != _sessionLoadGeneration) return;
              setState(() {
                _recentSessions = result.sessions;
                _attemptedSessionTools = result.attemptedTools;
                _failedSessionTools = result.failedTools;
                _sessionLoadError = result.failureMessage;
              });
            },
            onError: (Object _) {
              if (!mounted || loadGeneration != _sessionLoadGeneration) return;
              setState(() {
                _recentSessions ??= const [];
                _failedSessionTools = const <String>{};
                _sessionLoadError = 'Could not load recent AI sessions.';
                _isLoadingSessions = false;
              });
              _sessionDiscoverySubscription = null;
            },
            onDone: () {
              if (!mounted || loadGeneration != _sessionLoadGeneration) return;
              setState(() {
                _isLoadingSessions = false;
              });
              _sessionDiscoverySubscription = null;
            },
            cancelOnError: true,
          );
    } on Exception {
      if (!mounted || loadGeneration != _sessionLoadGeneration) return;
      setState(() {
        _recentSessions ??= const [];
        _failedSessionTools = const <String>{};
        _sessionLoadError = 'Could not load recent AI sessions.';
        _isLoadingSessions = false;
      });
      _sessionDiscoverySubscription = null;
    }
  }

  void _switchToWindow(int windowIndex) {
    Navigator.pop(context, TmuxSwitchWindowAction(windowIndex));
  }

  void _closeWindow(int windowIndex) {
    Navigator.pop(context, TmuxCloseWindowAction(windowIndex));
  }

  void _createNewWindow({String? command, String? name}) {
    Navigator.pop(
      context,
      TmuxNewWindowAction(command: command, windowName: name),
    );
  }

  void _resumeSession(ToolSessionInfo info) {
    final command = _discovery.buildResumeCommand(info);
    Navigator.pop(
      context,
      TmuxResumeSessionAction(command, workingDirectory: info.workingDirectory),
    );
  }

  Future<void> _showSessionPickerForTool(
    AiSessionProviderEntry provider,
  ) async {
    if (!provider.isSelectable) return;
    final selected = await showAiSessionPickerDialog(
      context: context,
      toolName: provider.toolName,
      sessions: provider.sessions,
    );
    if (!mounted || selected == null) return;
    _resumeSession(selected);
  }

  void _showNewWindowPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => TmuxToolPickerSheet(
        isProUser: widget.isProUser,
        installedToolsFuture: _installedToolsFuture,
        preferredTool: _preferredLaunchTool,
        onToolSelected: (tool) {
          Navigator.pop(context);
          _createNewWindow(command: tool.commandName, name: tool.commandName);
        },
        onEmptyWindow: () {
          Navigator.pop(context);
          _createNewWindow();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxSheetHeight = math.min(
      screenHeight * _tmuxNavigatorMaxHeightFactor,
      _tmuxNavigatorMaxHeightCap,
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.window_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('Windows', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 4),

            // Scrollable window list
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (_isLoadingWindows)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                    )
                  else if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not load windows: $_error',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    )
                  else if (_windows != null && _windows!.isNotEmpty)
                    ..._windows!.map(_buildWindowTile),
                ],
              ),
            ),

            const Divider(height: 1),

            // New Window button
            ListTile(
              visualDensity: _tmuxNavigatorDenseVisualDensity,
              minTileHeight: 42,
              contentPadding: _tmuxNavigatorTilePadding,
              horizontalTitleGap: 12,
              minLeadingWidth: 20,
              leading: Icon(
                Icons.add_circle_outline,
                color: theme.colorScheme.primary,
                size: 18,
              ),
              title: const Text('New Window'),
              dense: true,
              onTap: _showNewWindowPicker,
            ),

            // Recent AI Sessions (collapsed by default)
            if (widget.isProUser) ...[
              const Divider(height: 1),
              _buildRecentSessionsSection(theme),
            ],

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowTile(TmuxWindow window) {
    final theme = Theme.of(context);
    final isActive = window.isActive;
    final secondaryTitle = window.secondaryTitle;

    return ListTile(
      dense: true,
      visualDensity: _tmuxNavigatorDenseVisualDensity,
      minVerticalPadding: 2,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      horizontalTitleGap: 10,
      minLeadingWidth: 28,
      tileColor: isActive
          ? theme.colorScheme.primaryContainer.withAlpha(80)
          : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Text(
          '${window.index}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: isActive
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        window.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isActive
            ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
            : null,
      ),
      subtitle: secondaryTitle != null
          ? Text(
              secondaryTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TmuxWindowStatusBadge(window: window),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            tooltip: 'Close window',
            onPressed: () => _closeWindow(window.index),
          ),
        ],
      ),
      // Active window: dismiss. Other windows: switch.
      onTap: isActive
          ? () => Navigator.pop(context)
          : () => _switchToWindow(window.index),
    );
  }

  Widget _buildRecentSessionsSection(ThemeData theme) {
    final visibleCount = _recentSessions?.length ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          visualDensity: _tmuxNavigatorDenseVisualDensity,
          minTileHeight: 42,
          contentPadding: _tmuxNavigatorTilePadding,
          horizontalTitleGap: 12,
          minLeadingWidth: 18,
          leading: Icon(
            _showRecentSessions ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: Row(
            children: [
              const Text('Recent AI Sessions'),
              if (visibleCount > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '($visibleCount)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const Spacer(),
              const PremiumBadge(),
            ],
          ),
          onTap: () {
            setState(() => _showRecentSessions = !_showRecentSessions);
            if (_showRecentSessions) {
              _loadRecentSessions();
            }
          },
        ),
        if (_showRecentSessions) ...[
          if (_hasVisibleSessionProviders) ...[
            if (_sessionLoadError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _sessionLoadError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ..._buildSessionProviderEntries().map(
              (provider) => _buildSessionProviderTile(theme, provider),
            ),
          ] else if (_sessionLoadError != null && _recentSessions != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _sessionLoadError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else if (_recentSessions != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'No recent AI sessions found on this host.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }

  bool get _hasVisibleSessionProviders =>
      _isLoadingSessions ||
      _attemptedSessionTools.isNotEmpty ||
      _failedSessionTools.isNotEmpty ||
      (_recentSessions?.isNotEmpty ?? false);

  List<AiSessionProviderEntry> _buildSessionProviderEntries() {
    final groupedSessions = _groupSessions(_recentSessions);
    final orderedTools = orderedDiscoveredSessionTools(
      groupedSessions,
      <String>{..._attemptedSessionTools, ..._failedSessionTools},
      preferredToolName: _preferredLaunchTool?.discoveredSessionToolName,
    );
    return buildAiSessionProviderEntries(
      orderedTools: orderedTools,
      groupedSessions: groupedSessions,
      attemptedTools: _attemptedSessionTools,
      failedTools: _failedSessionTools,
      isLoading: _isLoadingSessions,
    );
  }

  Map<String, List<ToolSessionInfo>> _groupSessions(
    List<ToolSessionInfo>? sessions,
  ) {
    final grouped = <String, List<ToolSessionInfo>>{};
    if (sessions == null) return grouped;
    for (final session in sessions) {
      grouped
          .putIfAbsent(session.toolName, () => <ToolSessionInfo>[])
          .add(session);
    }
    return grouped;
  }

  Widget _buildSessionProviderTile(
    ThemeData theme,
    AiSessionProviderEntry provider,
  ) => ListTile(
    dense: true,
    visualDensity: _tmuxNavigatorDenseVisualDensity,
    minVerticalPadding: 2,
    contentPadding: _tmuxNavigatorGroupTilePadding,
    horizontalTitleGap: 12,
    minLeadingWidth: 20,
    leading: _toolIcon(provider.toolName, theme),
    title: Text(
      provider.toolName,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: provider.hasFailure
            ? theme.colorScheme.error
            : provider.isSelectable
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
      ),
    ),
    subtitle: Text(
      provider.statusLabel,
      style: theme.textTheme.bodySmall?.copyWith(
        color: provider.hasFailure
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant,
      ),
    ),
    trailing: provider.isLoading
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          )
        : provider.isSelectable
        ? Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant)
        : null,
    onTap: provider.isSelectable
        ? () => unawaited(_showSessionPickerForTool(provider))
        : null,
  );

  Widget _toolIcon(String toolName, ThemeData theme) => Icon(
    aiSessionToolIconData(toolName),
    size: 20,
    color: theme.colorScheme.primary,
  );
}

/// Bottom sheet for picking an AI coding tool to launch in a new tmux window.
class TmuxToolPickerSheet extends StatelessWidget {
  /// Creates a new [TmuxToolPickerSheet].
  const TmuxToolPickerSheet({
    required this.isProUser,
    required this.onToolSelected,
    required this.onEmptyWindow,
    this.installedToolsFuture,
    this.preferredTool,
    super.key,
  });

  /// Whether the user has Pro access.
  final bool isProUser;

  /// Future that resolves to the set of agent CLIs detected on the remote
  /// host, or `null` if the caller could not initiate detection. While the
  /// future is pending the picker shows a loading indicator. Once it
  /// completes, only the detected tools are listed; if it resolves to an
  /// empty set (or fails), no CLI tools are shown but "Empty window"
  /// remains available.
  final Future<Set<AgentLaunchTool>>? installedToolsFuture;

  /// Host-configured preferred tool, if one exists.
  final AgentLaunchTool? preferredTool;

  /// Called when the user selects a tool.
  final void Function(AgentLaunchTool tool) onToolSelected;

  /// Called when the user selects an empty window.
  final VoidCallback onEmptyWindow;

  /// All tools that can be shown in the picker, in display order.
  static const _allTools = [
    AgentLaunchTool.aider,
    AgentLaunchTool.claudeCode,
    AgentLaunchTool.copilotCli,
    AgentLaunchTool.codex,
    AgentLaunchTool.geminiCli,
    AgentLaunchTool.openCode,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxSheetHeight = math.min(
      screenHeight * _tmuxToolPickerMaxHeightFactor,
      _tmuxToolPickerMaxHeightCap,
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('New Window', style: theme.textTheme.titleMedium),
              ),
              FutureBuilder<Set<AgentLaunchTool>>(
                future: installedToolsFuture,
                builder: (context, snapshot) {
                  if (installedToolsFuture != null &&
                      snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator.adaptive(
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 12),
                          Text('Detecting installed CLIs…'),
                        ],
                      ),
                    );
                  }
                  final installed = snapshot.data;
                  final tools = _orderedAgentLaunchTools(
                    installed != null
                        ? _allTools.where(installed.contains)
                        : _allTools,
                    preferredTool: preferredTool,
                  );
                  if (tools.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(
                        'No supported CLIs found on PATH.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final tool in tools)
                        ListTile(
                          visualDensity: _tmuxNavigatorDenseVisualDensity,
                          minTileHeight: 42,
                          contentPadding: _tmuxNavigatorTilePadding,
                          horizontalTitleGap: 12,
                          minLeadingWidth: 20,
                          leading: TmuxToolPickerSheet._iconForTool(
                            tool,
                            theme,
                          ),
                          title: Text(tool.label),
                          trailing: !isProUser ? const PremiumBadge() : null,
                          enabled: isProUser,
                          onTap: () => onToolSelected(tool),
                        ),
                    ],
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                visualDensity: _tmuxNavigatorDenseVisualDensity,
                minTileHeight: 42,
                contentPadding: _tmuxNavigatorTilePadding,
                horizontalTitleGap: 12,
                minLeadingWidth: 20,
                leading: Icon(
                  Icons.terminal,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 18,
                ),
                title: const Text('Empty window'),
                onTap: onEmptyWindow,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _iconForTool(AgentLaunchTool tool, ThemeData theme) {
    final iconData = switch (tool) {
      AgentLaunchTool.aider => Icons.chat_bubble_outline,
      AgentLaunchTool.claudeCode => Icons.auto_awesome,
      AgentLaunchTool.copilotCli => Icons.flight,
      AgentLaunchTool.codex => Icons.code,
      AgentLaunchTool.geminiCli => Icons.diamond_outlined,
      AgentLaunchTool.openCode => Icons.terminal,
    };

    return Icon(iconData, color: theme.colorScheme.primary);
  }
}
