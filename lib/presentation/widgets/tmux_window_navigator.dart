import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/tmux_service.dart';
import '../widgets/premium_badge.dart';

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
  const TmuxResumeSessionAction(this.resumeCommand);

  /// The full resume command to run.
  final String resumeCommand;
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
  static const _maxSessionsPerTool = 3;

  /// Maximum total recent sessions to display.
  static const _maxVisibleSessions = 5;

  List<TmuxWindow>? _windows;
  List<ToolSessionInfo>? _recentSessions;
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
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoadingWindows = false;
      });
    }
  }

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

  void _createNewWindow({String? command, String? name}) {
    Navigator.pop(
      context,
      TmuxNewWindowAction(command: command, windowName: name),
    );
  }

  void _resumeSession(ToolSessionInfo info) {
    final command = _discovery.buildResumeCommand(info);
    Navigator.pop(context, TmuxResumeSessionAction(command));
  }

  void _showNewWindowPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => _ToolPickerSheet(
        isProUser: widget.isProUser,
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

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
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
              leading: Icon(
                Icons.add_circle_outline,
                color: theme.colorScheme.primary,
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

    return ListTile(
      dense: true,
      leading: Container(
        width: 28,
        height: 28,
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
      title: Text(window.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        window.statusLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      selected: isActive,
      onTap: isActive ? null : () => _switchToWindow(window.index),
    );
  }

  Widget _buildRecentSessionsSection(ThemeData theme) {
    final visibleCount = _recentSessions == null
        ? 0
        : _recentSessions!.length > _maxVisibleSessions
        ? _maxVisibleSessions
        : _recentSessions!.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          leading: Icon(
            _showRecentSessions ? Icons.expand_less : Icons.expand_more,
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
            ...(_recentSessions!
                .take(_maxVisibleSessions)
                .map(_buildSessionTile)),
        ],
      ],
    );
  }

  Widget _buildSessionTile(ToolSessionInfo info) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      leading: _toolIcon(info.toolName, theme),
      title: Text(
        info.summary ?? info.sessionId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        info.timeAgoLabel.isNotEmpty
            ? '${info.toolName} · ${info.timeAgoLabel}'
            : info.toolName,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: TextButton(
        onPressed: () => _resumeSession(info),
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

class _ToolPickerSheet extends StatelessWidget {
  const _ToolPickerSheet({
    required this.isProUser,
    required this.onToolSelected,
    required this.onEmptyWindow,
  });

  final bool isProUser;
  final void Function(AgentLaunchTool tool) onToolSelected;
  final VoidCallback onEmptyWindow;

  /// Tools shown in the picker (excludes Aider for the navigator).
  static const _navigatorTools = [
    AgentLaunchTool.claudeCode,
    AgentLaunchTool.copilotCli,
    AgentLaunchTool.codex,
    AgentLaunchTool.geminiCli,
    AgentLaunchTool.openCode,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('New Window', style: theme.textTheme.titleMedium),
            ),
            for (final tool in _navigatorTools)
              ListTile(
                leading: _ToolPickerSheet._iconForTool(tool, theme),
                title: Text(tool.label),
                trailing: !isProUser ? const PremiumBadge() : null,
                enabled: isProUser,
                onTap: () => onToolSelected(tool),
              ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.terminal,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: const Text('Empty window'),
              onTap: onEmptyWindow,
            ),
            const SizedBox(height: 8),
          ],
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
      AgentLaunchTool.aider => Icons.smart_toy_outlined,
    };

    return Icon(iconData, color: theme.colorScheme.primary);
  }
}
