import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/tmux_service.dart';
import '../widgets/premium_badge.dart';

const _tmuxNavigatorDenseVisualDensity = VisualDensity(vertical: -2);
const _tmuxNavigatorTilePadding = EdgeInsets.symmetric(horizontal: 16);
const _tmuxNavigatorGroupTilePadding = EdgeInsets.only(left: 16, right: 16);
const _tmuxNavigatorSessionTilePadding = EdgeInsets.only(left: 56, right: 12);
const _tmuxNavigatorMaxHeightFactor = 0.48;
const _tmuxNavigatorMaxHeightCap = 440.0;
const _tmuxToolPickerMaxHeightFactor = 0.36;
const _tmuxToolPickerMaxHeightCap = 320.0;

/// Shows the tmux window navigator bottom sheet.
///
/// Returns the action the user selected, or `null` if dismissed.
Future<TmuxNavigatorAction?> showTmuxNavigator({
  required BuildContext context,
  required WidgetRef ref,
  required SshSession session,
  required String tmuxSessionName,
  required bool isProUser,
}) => showModalBottomSheet<TmuxNavigatorAction>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _TmuxNavigatorSheet(
    session: session,
    tmuxSessionName: tmuxSessionName,
    isProUser: isProUser,
    ref: ref,
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
  });

  final SshSession session;
  final String tmuxSessionName;
  final bool isProUser;
  final WidgetRef ref;

  @override
  State<_TmuxNavigatorSheet> createState() => _TmuxNavigatorSheetState();
}

class _TmuxNavigatorSheetState extends State<_TmuxNavigatorSheet> {
  /// Maximum number of recent sessions to show per tool.
  static const _maxSessionsPerTool = 8;

  List<TmuxWindow>? _windows;
  List<ToolSessionInfo>? _recentSessions;
  Set<AgentLaunchTool>? _installedTools;
  final Set<String> _expandedSessionTools = <String>{};
  bool _isLoadingWindows = true;
  bool _isLoadingSessions = false;
  bool _showRecentSessions = false;
  String? _error;

  TmuxService get _tmux => widget.ref.read(tmuxServiceProvider);

  AgentSessionDiscoveryService get _discovery =>
      widget.ref.read(agentSessionDiscoveryServiceProvider);

  @override
  void initState() {
    super.initState();
    _loadWindows();
  }

  Future<void> _loadWindows() async {
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
      // Detect installed CLIs in parallel (non-blocking).
      unawaited(_detectInstalledTools());
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoadingWindows = false;
      });
    }
  }

  Future<void> _detectInstalledTools() async {
    try {
      // Source shell profiles so CLIs in Homebrew/nvm/etc. paths are found.
      final output = await widget.session.execute(
        '. ~/.profile 2>/dev/null; '
        '. ~/.bash_profile 2>/dev/null; '
        '. ~/.zprofile 2>/dev/null; '
        'command -v claude copilot codex gemini opencode 2>/dev/null'
        ' || true',
      );
      final stdout = await output.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      await output.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      if (!mounted) return;

      final paths = stdout.trim().split('\n').where((l) => l.isNotEmpty);
      final installed = <AgentLaunchTool>{};
      for (final path in paths) {
        final bin = path.split('/').last;
        final tool = _toolForBinary(bin);
        if (tool != null) installed.add(tool);
      }
      setState(() => _installedTools = installed);
    } on Object {
      // Ignore — show all tools if detection fails.
    }
  }

  static AgentLaunchTool? _toolForBinary(String bin) => switch (bin) {
    'claude' => AgentLaunchTool.claudeCode,
    'copilot' => AgentLaunchTool.copilotCli,
    'codex' => AgentLaunchTool.codex,
    'gemini' => AgentLaunchTool.geminiCli,
    'opencode' => AgentLaunchTool.openCode,
    _ => null,
  };

  Future<void> _loadRecentSessions() async {
    if (_isLoadingSessions || _recentSessions != null) return;
    setState(() => _isLoadingSessions = true);

    try {
      // Get working directory from the active window if available.
      final activeWindow = _windows?.where((w) => w.isActive).firstOrNull;
      final sessions = await _discovery.discoverSessions(
        widget.session,
        workingDirectory: activeWindow?.currentPath,
        maxPerTool: _maxSessionsPerTool,
      );
      if (!mounted) return;
      setState(() {
        _recentSessions = sessions;
        if (_expandedSessionTools.isEmpty && sessions.isNotEmpty) {
          _expandedSessionTools.add(sessions.first.toolName);
        }
        _isLoadingSessions = false;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _recentSessions = const [];
        _isLoadingSessions = false;
      });
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

  void _showNewWindowPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => TmuxToolPickerSheet(
        isProUser: widget.isProUser,
        installedTools: _installedTools,
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
          _windowStatusIcon(theme, window),
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

  /// Returns a status icon for the window's current state.
  Widget _windowStatusIcon(ThemeData theme, TmuxWindow window) {
    if (window.hasAlert) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          Icons.notifications_active,
          size: 16,
          color: theme.colorScheme.error,
        ),
      );
    }
    if (window.isIdle) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          Icons.hourglass_bottom,
          size: 14,
          color: theme.colorScheme.tertiary,
        ),
      );
    }
    if (!window.isActive) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          Icons.play_arrow,
          size: 16,
          color: theme.colorScheme.primary.withAlpha(160),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildRecentSessionsSection(ThemeData theme) {
    final visibleCount = _recentSessions?.length ?? 0;
    final groupedSessions = _groupSessions(_recentSessions);

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
          if (_isLoadingSessions)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
              ),
            )
          else if (_recentSessions != null && _recentSessions!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'No recent AI sessions found on this host.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (_recentSessions != null)
            ...groupedSessions.entries.map(
              (entry) => _buildSessionGroup(theme, entry.key, entry.value),
            ),
        ],
      ],
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

  Widget _buildSessionGroup(
    ThemeData theme,
    String toolName,
    List<ToolSessionInfo> sessions,
  ) {
    final isExpanded = _expandedSessionTools.contains(toolName);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          visualDensity: _tmuxNavigatorDenseVisualDensity,
          minVerticalPadding: 2,
          contentPadding: _tmuxNavigatorGroupTilePadding,
          horizontalTitleGap: 12,
          minLeadingWidth: 20,
          leading: _toolIcon(toolName, theme),
          title: Text(toolName),
          subtitle: Text(
            '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: Icon(
            isExpanded ? Icons.expand_less : Icons.expand_more,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedSessionTools.remove(toolName);
              } else {
                _expandedSessionTools.add(toolName);
              }
            });
          },
        ),
        if (isExpanded)
          ...sessions.map(
            (session) => _buildSessionTile(
              session,
              contentPadding: _tmuxNavigatorSessionTilePadding,
            ),
          ),
      ],
    );
  }

  Widget _buildSessionTile(
    ToolSessionInfo info, {
    EdgeInsetsGeometry? contentPadding,
  }) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      visualDensity: _tmuxNavigatorDenseVisualDensity,
      minVerticalPadding: 2,
      contentPadding: contentPadding,
      leading: _toolIcon(info.toolName, theme),
      horizontalTitleGap: 12,
      minLeadingWidth: 20,
      title: Text(
        info.summary ?? info.sessionId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        info.lastUpdatedLabel.isNotEmpty
            ? info.lastUpdatedLabel
            : info.toolName,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: TextButton(
        onPressed: () => _resumeSession(info),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: const Text('Resume'),
      ),
    );
  }

  Widget _toolIcon(String toolName, ThemeData theme) {
    final iconData = switch (toolName) {
      'Claude Code' => Icons.auto_awesome,
      'Codex' => Icons.code,
      'Copilot CLI' => Icons.flight,
      'Gemini CLI' => Icons.diamond_outlined,
      'OpenCode' => Icons.terminal,
      _ => Icons.smart_toy_outlined,
    };

    return Icon(iconData, size: 20, color: theme.colorScheme.primary);
  }
}

/// Bottom sheet for picking an AI coding tool to launch in a new tmux window.
class TmuxToolPickerSheet extends StatelessWidget {
  /// Creates a new [TmuxToolPickerSheet].
  const TmuxToolPickerSheet({
    required this.isProUser,
    required this.onToolSelected,
    required this.onEmptyWindow,
    this.installedTools,
    super.key,
  });

  /// Whether the user has Pro access.
  final bool isProUser;

  /// Tools detected as installed on the remote host, or `null` if not yet
  /// detected (shows all tools).
  final Set<AgentLaunchTool>? installedTools;

  /// Called when the user selects a tool.
  final void Function(AgentLaunchTool tool) onToolSelected;

  /// Called when the user selects an empty window.
  final VoidCallback onEmptyWindow;

  /// All tools that can be shown in the picker.
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
    // Show only installed tools, or all if detection hasn't completed.
    final tools = installedTools != null
        ? _allTools.where((t) => installedTools!.contains(t)).toList()
        : _allTools;

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
              for (final tool in tools)
                ListTile(
                  visualDensity: _tmuxNavigatorDenseVisualDensity,
                  minTileHeight: 42,
                  contentPadding: _tmuxNavigatorTilePadding,
                  horizontalTitleGap: 12,
                  minLeadingWidth: 20,
                  leading: TmuxToolPickerSheet._iconForTool(tool, theme),
                  title: Text(tool.label),
                  trailing: !isProUser ? const PremiumBadge() : null,
                  enabled: isProUser,
                  onTap: () => onToolSelected(tool),
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
      AgentLaunchTool.claudeCode => Icons.auto_awesome,
      AgentLaunchTool.copilotCli => Icons.flight,
      AgentLaunchTool.codex => Icons.code,
      AgentLaunchTool.geminiCli => Icons.diamond_outlined,
      AgentLaunchTool.openCode => Icons.terminal,
    };

    return Icon(iconData, color: theme.colorScheme.primary);
  }
}
