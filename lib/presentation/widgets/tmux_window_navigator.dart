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
import 'agent_tool_icon.dart';
import 'ai_session_picker.dart';
import 'premium_badge.dart';
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
  required bool startClisInYoloMode,
  String? scopeWorkingDirectory,
}) => showModalBottomSheet<TmuxNavigatorAction>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _TmuxNavigatorSheet(
    session: session,
    tmuxSessionName: tmuxSessionName,
    isProUser: isProUser,
    startClisInYoloMode: startClisInYoloMode,
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
    required this.startClisInYoloMode,
    required this.ref,
    this.scopeWorkingDirectory,
  });

  final SshSession session;
  final String tmuxSessionName;
  final bool isProUser;
  final bool startClisInYoloMode;
  final WidgetRef ref;
  final String? scopeWorkingDirectory;

  @override
  State<_TmuxNavigatorSheet> createState() => _TmuxNavigatorSheetState();
}

class _TmuxNavigatorSheetState extends State<_TmuxNavigatorSheet> {
  /// Maximum number of recent sessions to show per tool.
  static const _maxSessionsPerTool = 16;
  static const _prefetchSessionFetchLimit = 6;

  List<TmuxWindow>? _windows;
  AgentLaunchTool? _preferredLaunchTool;
  Future<Set<AgentLaunchTool>>? _installedToolsFuture;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
  bool _isLoadingWindows = true;
  String? _error;
  bool _loadingWindows = false;
  bool _pendingWindowReload = false;
  int _windowReloadGeneration = 0;
  int _windowEventGeneration = 0;
  Timer? _windowRetryTimer;
  int _windowRetryAttempts = 0;
  int _consecutiveEmptyWindowReloads = 0;

  TmuxService get _tmux => widget.ref.read(tmuxServiceProvider);

  AgentSessionDiscoveryService get _discovery =>
      widget.ref.read(agentSessionDiscoveryServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferredLaunchTool());
    _installedToolsFuture = _tmux.detectInstalledAgentTools(widget.session);
    _subscribeToWindowChanges();
    _loadWindows();
  }

  @override
  void didUpdateWidget(covariant _TmuxNavigatorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.hostId != widget.session.hostId) {
      _resetWindowReloadRecovery();
      unawaited(_loadPreferredLaunchTool());
    }
  }

  @override
  void dispose() {
    _resetWindowReloadRecovery();
    unawaited(_windowChangeSubscription?.cancel());
    super.dispose();
  }

  void _subscribeToWindowChanges() {
    final generation = ++_windowEventGeneration;
    _windowChangeSubscription = _tmux
        .watchWindowChanges(widget.session, widget.tmuxSessionName)
        .listen((event) => _handleWindowChangeEvent(event, generation));
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
    unawaited(_prefetchPreferredSessionProvider());
  }

  Future<void> _prefetchPreferredSessionProvider({
    List<TmuxWindow>? windows,
    int maxPerTool = _prefetchSessionFetchLimit,
  }) async {
    final toolName = _preferredLaunchTool?.discoveredSessionToolName;
    if (toolName == null || toolName.isEmpty) return;
    final activeWindow = (windows ?? _windows)
        ?.where((window) => window.isActive)
        .firstOrNull;
    final scopeWorkingDirectory =
        widget.scopeWorkingDirectory ??
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: activeWindow?.currentPath,
          sessionWorkingDirectory: widget.session.workingDirectory,
        );
    await _discovery.prefetchSessions(
      widget.session,
      workingDirectory: scopeWorkingDirectory,
      maxPerTool: maxPerTool,
      toolName: toolName,
    );
  }

  Future<void> _loadWindows() async {
    if (_loadingWindows) {
      _pendingWindowReload = true;
      return;
    }
    _loadingWindows = true;
    final reloadGeneration = ++_windowReloadGeneration;
    try {
      final reloadedWindows = await _tmux.listWindows(
        widget.session,
        widget.tmuxSessionName,
      );
      if (!mounted) return;
      if (reloadGeneration < _windowReloadGeneration) return;
      final isEmptyReload = reloadedWindows.isEmpty;
      if (isEmptyReload) {
        _consecutiveEmptyWindowReloads += 1;
      } else {
        _resetWindowReloadRecovery();
      }
      final windows = resolveTmuxReloadedWindows(
        shouldPreserveTmuxWindowSnapshotOnEmptyReload(
              _windows,
              consecutiveEmptyReloads: _consecutiveEmptyWindowReloads,
            )
            ? _windows
            : null,
        reloadedWindows,
      );
      if (windows == null) {
        _scheduleWindowRetry();
        setState(() {
          _windows = null;
          _error = null;
          _isLoadingWindows = true;
        });
        return;
      }
      if (isEmptyReload) {
        _scheduleWindowRetry();
      } else {
        _resetWindowReloadRecovery();
      }
      setState(() {
        _windows = windows;
        _error = null;
        _isLoadingWindows = false;
      });
      unawaited(_prefetchPreferredSessionProvider(windows: windows));
    } on Exception catch (e) {
      if (!mounted) return;
      _scheduleWindowRetry();
      setState(() {
        _error = _windows?.isEmpty ?? true ? e.toString() : null;
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

  void _handleWindowChangeEvent(TmuxWindowChangeEvent event, int generation) {
    if (!mounted) return;
    if (generation != _windowEventGeneration) return;
    if (event is TmuxWindowReloadEvent) {
      _loadWindows();
      return;
    }
    final currentWindows = _windows;
    if (currentWindows == null) {
      _loadWindows();
      return;
    }
    _windowReloadGeneration += 1;
    _resetWindowReloadRecovery();
    setState(() {
      _windows = applyTmuxWindowChangeEvent(currentWindows, event);
      _error = null;
      _isLoadingWindows = false;
    });
  }

  void _cancelWindowRetry() {
    _windowRetryTimer?.cancel();
    _windowRetryTimer = null;
  }

  void _resetWindowReloadRecovery() {
    _cancelWindowRetry();
    _windowRetryAttempts = 0;
    _consecutiveEmptyWindowReloads = 0;
  }

  void _scheduleWindowRetry() {
    if (!mounted || (_windowRetryTimer?.isActive ?? false)) {
      return;
    }
    final delay = resolveTmuxWindowReloadRetryDelay(_windowRetryAttempts);
    _windowRetryAttempts += 1;
    _windowRetryTimer = Timer(delay, () {
      _windowRetryTimer = null;
      if (mounted) {
        unawaited(_loadWindows());
      }
    });
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
    final selected = await showAiSessionPickerDialog(
      context: context,
      toolName: provider.toolName,
      initialMaxSessions: _maxSessionsPerTool,
      sessionFetchStep: _maxSessionsPerTool,
      loadSessions: (maxSessions) {
        final activeWindow = _windows?.where((w) => w.isActive).firstOrNull;
        final scopeWorkingDirectory =
            widget.scopeWorkingDirectory ??
            resolveAgentSessionScopeWorkingDirectory(
              activeWorkingDirectory: activeWindow?.currentPath,
              sessionWorkingDirectory: widget.session.workingDirectory,
            );
        return _discovery.discoverSessionsStream(
          widget.session,
          workingDirectory: scopeWorkingDirectory,
          maxPerTool: maxSessions,
          toolName: provider.toolName,
        );
      },
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
          _createNewWindow(
            command: buildAgentToolCommand(
              tool,
              startInYoloMode: widget.startClisInYoloMode,
            ),
            name: tool.commandName,
          );
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

            // Scrollable popup content
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
                  // Recent AI Sessions
                  if (widget.isProUser) ...[
                    const Divider(height: 1),
                    _buildRecentSessionsSection(theme),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowTile(TmuxWindow window) {
    final theme = Theme.of(context);
    final isActive = window.isActive;
    final secondaryTitle = window.secondaryTitle;
    final iconColor = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

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
      title: Row(
        children: [
          AgentToolIcon(
            tool: window.foregroundAgentTool,
            size: 16,
            color: iconColor,
            fallbackIcon: Icons.terminal,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              window.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isActive
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    )
                  : null,
            ),
          ),
        ],
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

  Widget _buildRecentSessionsSection(ThemeData theme) => Column(
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
          Icons.smart_toy_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Row(
          children: [Text('Recent AI Sessions'), Spacer(), PremiumBadge()],
        ),
      ),
      AiSessionProviderList(
        key: ValueKey<Object>(
          Object.hashAll(<Object?>[
            widget.session.connectionId,
            widget.tmuxSessionName,
            widget.scopeWorkingDirectory,
            _windows
                ?.where((window) => window.isActive)
                .firstOrNull
                ?.currentPath,
          ]),
        ),
        orderedTools: orderedDiscoveredSessionTools(
          const <String, List<ToolSessionInfo>>{},
          const <String>{},
          preferredToolName: _preferredLaunchTool?.discoveredSessionToolName,
        ),
        loadSessionsForTool: (toolName, maxSessions) {
          final activeWindow = _windows?.where((w) => w.isActive).firstOrNull;
          final scopeWorkingDirectory =
              widget.scopeWorkingDirectory ??
              resolveAgentSessionScopeWorkingDirectory(
                activeWorkingDirectory: activeWindow?.currentPath,
                sessionWorkingDirectory: widget.session.workingDirectory,
              );
          return _discovery.discoverSessionsStream(
            widget.session,
            workingDirectory: scopeWorkingDirectory,
            maxPerTool: maxSessions,
            toolName: toolName,
          );
        },
        itemBuilder: (context, provider) =>
            _buildSessionProviderTile(theme, provider),
      ),
    ],
  );

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
    leading: AgentToolIcon(
      toolName: provider.toolName,
      color: theme.colorScheme.primary,
    ),
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
    trailing: provider.isLoading && !provider.hasSessions
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (provider.isLoading) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
                const SizedBox(width: 4),
              ],
              if (provider.isSelectable)
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
    onTap: provider.isSelectable
        ? () => unawaited(_showSessionPickerForTool(provider))
        : null,
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

  static Widget _iconForTool(AgentLaunchTool tool, ThemeData theme) =>
      AgentToolIcon(tool: tool, color: theme.colorScheme.primary);
}
