import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../app/routes.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/remote_clipboard_sync_service.dart';
import '../../domain/services/remote_file_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_hyperlink_tracker.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../../domain/services/tmux_service.dart';
import '../widgets/ai_session_picker.dart';
import '../widgets/keyboard_toolbar.dart';
import '../widgets/monkey_terminal_view.dart';
import '../widgets/premium_access.dart';
import '../widgets/terminal_pinch_zoom_gesture_handler.dart';
import '../widgets/terminal_text_input_handler.dart';
import '../widgets/terminal_text_style.dart';
import '../widgets/terminal_theme_picker.dart';
import '../widgets/tmux_window_navigator.dart';
import '../widgets/tmux_window_status_badge.dart';

bool _isPromptReturnWhitespaceCodeUnit(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

bool _isPromptReturnAsciiLetterOrDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

/// Resolves how much vertical space the tmux bar can safely expand into.
@visibleForTesting
double resolveTmuxBarMaxContentHeight(
  double availableHeight, {
  double handleHeight = 22,
  double reservedPadding = 8,
  double fallbackAvailableHeight = 0,
}) {
  const maxHeightFactor = 0.68;
  const maxHeightCap = 400.0;
  final minimumExpandableHeight = handleHeight + reservedPadding;
  final effectiveAvailableHeight = availableHeight > minimumExpandableHeight
      ? availableHeight
      : fallbackAvailableHeight;
  final rawHeight = max(
    0,
    effectiveAvailableHeight - handleHeight - reservedPadding,
  ).toDouble();
  return min(
    rawHeight,
    min(effectiveAvailableHeight * maxHeightFactor, maxHeightCap),
  );
}

const _tmuxBarRevealDuration = Duration(milliseconds: 300);
const _tmuxDetectionRetrySchedule = <Duration>[
  Duration.zero,
  Duration(milliseconds: 150),
  Duration(milliseconds: 350),
  Duration(milliseconds: 700),
  Duration(milliseconds: 1400),
];

/// Resolves the retry schedule used for tmux detection after connect.
@visibleForTesting
List<Duration> resolveTmuxDetectionRetrySchedule({bool skipDelay = false}) =>
    skipDelay ? const <Duration>[Duration.zero] : _tmuxDetectionRetrySchedule;

/// Resolves the tmux session name we can infer before remote verification.
@visibleForTesting
String? resolvePreferredTmuxSessionName({
  String? structuredSessionName,
  String? autoConnectCommand,
}) => structuredSessionName ?? parseTmuxSessionName(autoConnectCommand);

/// Resolves the working directory to use when creating a new tmux window.
@visibleForTesting
String? resolveTmuxWindowWorkingDirectory({
  String? explicitWorkingDirectory,
  String? currentPaneWorkingDirectory,
  String? observedWorkingDirectory,
  String? launchWorkingDirectory,
  String? hostWorkingDirectory,
}) {
  for (final candidate in <String?>[
    explicitWorkingDirectory,
    currentPaneWorkingDirectory,
    observedWorkingDirectory,
    launchWorkingDirectory,
    hostWorkingDirectory,
  ]) {
    final trimmed = candidate?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

/// Returns whether a tmux window action should reattach the visible terminal.
@visibleForTesting
bool shouldReattachTmuxAfterWindowAction({
  required bool hasForegroundClient,
  required TerminalShellStatus? shellStatus,
}) {
  if (hasForegroundClient) {
    return false;
  }
  return shellStatus != TerminalShellStatus.runningCommand;
}

/// Returns whether shell-command review warnings should be shown for text
/// inserted into the active terminal context.
///
/// These warnings are most useful when input is likely targeting a shell
/// prompt. When a full-screen app owns the alternate buffer, or shell
/// integration reports that a command is still running, the input is more
/// likely to be consumed by that program than by the shell itself.
@visibleForTesting
bool shouldReviewTerminalCommandInsertion({
  required TerminalShellStatus? shellStatus,
  required bool isUsingAltBuffer,
}) {
  if (isUsingAltBuffer) {
    return false;
  }
  return shellStatus != TerminalShellStatus.runningCommand;
}

/// Resolves the safe-area insets the tmux bar should stay within.
@visibleForTesting
EdgeInsets resolveTmuxBarSafeInsets(MediaQueryData mediaQuery) {
  final horizontalInsets = resolveTerminalRenderPadding(mediaQuery);
  return EdgeInsets.only(
    left: horizontalInsets.left,
    right: horizontalInsets.right,
    bottom: mediaQuery.padding.bottom,
  );
}

/// Resolves the tmux bar's vertical offset from the animated bottom padding.
@visibleForTesting
double resolveTmuxBarRevealBottomOffset(
  double terminalBottomPadding, {
  double handleHeight = 22,
}) => terminalBottomPadding - handleHeight;

/// Resolves the tmux bar's reveal opacity from the animated bottom padding.
@visibleForTesting
double resolveTmuxBarRevealOpacity(
  double terminalBottomPadding, {
  double handleHeight = 22,
}) {
  if (handleHeight <= 0) {
    return terminalBottomPadding > 0 ? 1 : 0;
  }

  return (terminalBottomPadding / handleHeight).clamp(0.0, 1.0);
}

/// Resolves the active tmux window title to show in the collapsed bar handle.
@visibleForTesting
String? resolveTmuxBarActiveWindowTitle(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  final title = activeWindow?.displayTitle.trim();
  if (title == null || title.isEmpty) {
    return null;
  }
  return title;
}

/// Resolves the compact label shown in the tmux bar handle.
@visibleForTesting
String resolveTmuxBarHandleLabel(
  String tmuxSessionName, {
  String? activeWindowTitle,
}) {
  final sessionName = tmuxSessionName.trim();
  final title = activeWindowTitle?.trim();
  if (title == null || title.isEmpty || title == sessionName) {
    return sessionName;
  }
  if (sessionName.isEmpty) {
    return title;
  }
  return '$sessionName · $title';
}

final _oscEscapeSequencePattern = RegExp(
  '\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)',
  dotAll: true,
);
final _csiEscapeSequencePattern = RegExp('\x1B\\[[0-?]*[ -/]*[@-~]');
final _singleCharEscapeSequencePattern = RegExp('\x1B[@-_]');

String _stripTerminalPromptEscapeSequences(String text) => text
    .replaceAll(_oscEscapeSequencePattern, '')
    .replaceAll(_csiEscapeSequencePattern, '')
    .replaceAll(_singleCharEscapeSequencePattern, '');

const _minTerminalFontSize = 8.0;
const _maxTerminalFontSize = 32.0;
const _terminalFollowOutputTolerance = 1.0;
const _maxVerifiedTerminalPathCacheEntries = 128;
const _terminalPathTouchHorizontalPadding = 10.0;
const _terminalPathTouchVerticalPadding = 8.0;
const _selectionActionsBottomPadding = 12.0;
const _maxTerminalFilePathVerificationCandidates = 12;
const _terminalFilePathVerificationExtensions = <String>[
  'properties',
  'gradle',
  'sqlite',
  'jpeg',
  'plist',
  'swift',
  'tar',
  'yaml',
  'dart',
  'html',
  'json',
  'lock',
  'scss',
  'toml',
  'tsx',
  'webp',
  'bash',
  'conf',
  'cpp',
  'css',
  'csv',
  'gif',
  'ini',
  'jpg',
  'log',
  'png',
  'sql',
  'svg',
  'txt',
  'xml',
  'yml',
  'zsh',
  'cc',
  'db',
  'go',
  'gz',
  'js',
  'kt',
  'md',
  'mm',
  'py',
  'rb',
  'rs',
  'sh',
  'ts',
  'c',
  'h',
  'm',
];

/// Expandable tmux bar overlaid at the bottom of the terminal.
///
/// Collapsed: a slim handle bar sitting over bottom padding in the terminal.
/// Expanded: slides up over the terminal content.
/// The handle height matches the terminal's bottom padding so it never
/// covers actual terminal content when collapsed.
class _TmuxExpandableBar extends StatefulWidget {
  const _TmuxExpandableBar({
    required this.session,
    required this.tmuxSessionName,
    required this.availableHeight,
    required this.isProUser,
    required this.startClisInYoloMode,
    required this.ref,
    required this.onAction,
    this.scopeWorkingDirectory,
  });

  /// The active SSH session.
  final SshSession session;

  /// The tmux session name.
  final String tmuxSessionName;

  /// The available terminal height the bar can expand into.
  final double availableHeight;

  /// Whether the user has Pro access.
  final bool isProUser;

  /// Whether supported coding CLIs should launch in YOLO mode for this host.
  final bool startClisInYoloMode;

  /// Riverpod ref.
  final WidgetRef ref;

  /// Callback for navigator actions.
  final Future<void> Function(TmuxNavigatorAction) onAction;

  /// Best-known project working directory for AI session scoping.
  final String? scopeWorkingDirectory;

  /// Height of the collapsed handle bar. The terminal adds this as
  /// bottom padding so the handle sits over empty space.
  static const handleHeight = 22.0;

  @override
  State<_TmuxExpandableBar> createState() => _TmuxExpandableBarState();
}

class _TmuxExpandableBarState extends State<_TmuxExpandableBar>
    with SingleTickerProviderStateMixin {
  static const _denseTileVisualDensity = VisualDensity(vertical: -2);
  static const _denseTilePadding = EdgeInsets.symmetric(horizontal: 12);
  static const _groupTilePadding = EdgeInsets.only(left: 52, right: 12);
  static const _prefetchSessionFetchLimit = 6;

  List<TmuxWindow>? _windows;
  AgentLaunchTool? _preferredLaunchTool;
  final Set<int> _seenAlertWindows = <int>{};
  bool _expanded = false;
  bool _isLoading = true;
  bool _showSessions = false;
  bool _hasInitializedSessionProviders = false;
  double _dragOffset = 0;
  StreamSubscription<void>? _windowChangeSubscription;
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;
  bool _loadingWindows = false;
  bool _pendingWindowReload = false;

  TmuxService get _tmux => widget.ref.read(tmuxServiceProvider);

  AgentSessionDiscoveryService get _discovery =>
      widget.ref.read(agentSessionDiscoveryServiceProvider);

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _bounceAnimation =
        TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0, end: -6), weight: 1),
          TweenSequenceItem(tween: Tween(begin: -6, end: 0), weight: 1),
          TweenSequenceItem(tween: Tween(begin: 0, end: -3), weight: 1),
          TweenSequenceItem(tween: Tween(begin: -3, end: 0), weight: 1),
        ]).animate(
          CurvedAnimation(parent: _bounceController, curve: Curves.easeInOut),
        );
    unawaited(_loadPreferredLaunchTool());
    _loadWindows();
    _subscribeToWindowChanges();
  }

  @override
  void didUpdateWidget(covariant _TmuxExpandableBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.connectionId == widget.session.connectionId &&
        oldWidget.tmuxSessionName == widget.tmuxSessionName) {
      return;
    }
    unawaited(_windowChangeSubscription?.cancel());
    _subscribeToWindowChanges();
    unawaited(_loadPreferredLaunchTool());
    _loadWindows();
  }

  @override
  void dispose() {
    unawaited(_windowChangeSubscription?.cancel());
    for (final windowIndex in _seenAlertWindows) {
      _clearAlertNotification(windowIndex);
    }
    _bounceController.dispose();
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
    if (widget.isProUser) {
      unawaited(_prefetchPreferredSessionProvider());
    }
  }

  void _subscribeToWindowChanges() {
    _windowChangeSubscription = _tmux
        .watchWindowChanges(widget.session, widget.tmuxSessionName)
        .listen((_) {
          if (!mounted) return;
          _loadWindows();
        });
  }

  String? _resolveRecentSessionScopeWorkingDirectory([
    List<TmuxWindow>? windows,
  ]) {
    final activeWindow = (windows ?? _windows)
        ?.where((window) => window.isActive)
        .firstOrNull;
    return widget.scopeWorkingDirectory ??
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: activeWindow?.currentPath,
          sessionWorkingDirectory: widget.session.workingDirectory,
        );
  }

  Future<void> _prefetchPreferredSessionProvider({
    List<TmuxWindow>? windows,
    int maxPerTool = _prefetchSessionFetchLimit,
  }) async {
    final toolName = _preferredLaunchTool?.discoveredSessionToolName;
    if (toolName == null || toolName.isEmpty) return;
    await _discovery.prefetchSessions(
      widget.session,
      workingDirectory: _resolveRecentSessionScopeWorkingDirectory(windows),
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
    try {
      final windows = await _tmux.listWindows(
        widget.session,
        widget.tmuxSessionName,
      );
      if (!mounted) return;

      // Detect new alerts that weren't in the previous window list.
      final newAlerts = windows.where(
        (w) =>
            w.hasAlert && !w.isActive && !_seenAlertWindows.contains(w.index),
      );
      if (newAlerts.isNotEmpty) {
        unawaited(_bounceController.forward(from: 0));
        for (final w in newAlerts) {
          _seenAlertWindows.add(w.index);
          _sendAlertNotification(w);
        }
      }

      final activeAlerts = _seenAlertWindows
          .where(
            (idx) =>
                windows.any((w) => w.index == idx && w.hasAlert && w.isActive),
          )
          .toList(growable: false);
      for (final windowIndex in activeAlerts) {
        _clearAlertNotification(windowIndex);
      }

      final clearedAlerts = _seenAlertWindows
          .where((idx) => !windows.any((w) => w.index == idx && w.hasAlert))
          .toList(growable: false);
      for (final windowIndex in clearedAlerts) {
        _seenAlertWindows.remove(windowIndex);
        _clearAlertNotification(windowIndex);
      }

      setState(() {
        _windows = windows;
        _isLoading = false;
      });
      if (widget.isProUser) {
        unawaited(_prefetchPreferredSessionProvider(windows: windows));
      }
    } on Object {
      if (!mounted) return;
      if (_isLoading) setState(() => _isLoading = false);
    } finally {
      _loadingWindows = false;
      if (_pendingWindowReload) {
        _pendingWindowReload = false;
        unawaited(_loadWindows());
      }
    }
  }

  void _resumeSession(ToolSessionInfo info) {
    final discovery = widget.ref.read(agentSessionDiscoveryServiceProvider);
    final command = discovery.buildResumeCommand(info);
    setState(() => _expanded = false);
    widget.onAction(
      TmuxResumeSessionAction(command, workingDirectory: info.workingDirectory),
    );
  }

  Future<void> _showSessionPickerForTool(
    AiSessionProviderEntry provider,
  ) async {
    final selected = await showAiSessionPickerDialog(
      context: context,
      toolName: provider.toolName,
      loadSessions: (maxSessions) => _discovery.discoverSessionsStream(
        widget.session,
        workingDirectory: _resolveRecentSessionScopeWorkingDirectory(),
        maxPerTool: maxSessions,
        toolName: provider.toolName,
      ),
    );
    if (!mounted || selected == null) return;
    _resumeSession(selected);
  }

  int _tmuxAlertNotificationId(int windowIndex) =>
      Object.hash(widget.tmuxSessionName, windowIndex) & 0x7fffffff;

  void _sendAlertNotification(TmuxWindow window) {
    unawaited(HapticFeedback.mediumImpact());
    final title = 'tmux alert · ${widget.tmuxSessionName}';
    final name = window.displayTitle.trim();
    final body = name.isEmpty ? 'Window ${window.index} needs attention' : name;
    unawaited(
      widget.ref
          .read(localNotificationServiceProvider)
          .showTmuxAlert(
            notificationId: _tmuxAlertNotificationId(window.index),
            title: title,
            body: body,
          ),
    );
  }

  void _clearAlertNotification(int windowIndex) {
    unawaited(
      widget.ref
          .read(localNotificationServiceProvider)
          .clearTmuxAlert(_tmuxAlertNotificationId(windowIndex)),
    );
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += _expanded ? details.delta.dy : -details.delta.dy;
      _dragOffset = _dragOffset.clamp(0.0, 300.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldExpand = !_expanded && (velocity < -200 || _dragOffset > 60);
    final shouldCollapse = _expanded && (velocity > 200 || _dragOffset > 60);
    setState(() {
      if (shouldExpand) {
        _expanded = true;
      } else if (shouldCollapse) {
        _expanded = false;
      }
      _dragOffset = 0;
    });
    if (shouldExpand) _loadWindows();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final availableHeight = widget.availableHeight.isFinite
        ? widget.availableHeight
        : MediaQuery.sizeOf(context).height * 0.5;
    final mediaQuery = MediaQuery.of(context);
    final visibleViewportHeight = max(
      0,
      mediaQuery.size.height -
          mediaQuery.viewPadding.vertical -
          mediaQuery.viewInsets.bottom,
    );
    final maxContentHeight = resolveTmuxBarMaxContentHeight(
      availableHeight,
      fallbackAvailableHeight: visibleViewportHeight * 0.5,
    );
    final dragDistance = _dragOffset.clamp(0.0, maxContentHeight);
    final contentHeight = _expanded
        ? (maxContentHeight - dragDistance).clamp(0.0, maxContentHeight)
        : dragDistance;

    return AnimatedBuilder(
      animation: _bounceAnimation,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _bounceAnimation.value),
        child: child,
      ),
      child: GestureDetector(
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHandleBar(theme),
              AnimatedContainer(
                duration: _dragOffset > 0
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                height: contentHeight,
                child: contentHeight > 0
                    ? ClipRect(child: _buildWindowList(theme))
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHandleBar(ThemeData theme) {
    final handleLabel = resolveTmuxBarHandleLabel(
      widget.tmuxSessionName,
      activeWindowTitle: resolveTmuxBarActiveWindowTitle(_windows),
    );
    return GestureDetector(
      key: const ValueKey('tmux-handle-bar'),
      onTap: () {
        final wasExpanded = _expanded;
        setState(() => _expanded = !_expanded);
        // Refresh window list when expanding to get current active state.
        if (!wasExpanded) {
          _loadWindows();
          if (widget.isProUser) {
            unawaited(_prefetchPreferredSessionProvider());
          }
        }
      },
      child: SizedBox(
        height: _TmuxExpandableBar.handleHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 28,
                    height: 3,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(80),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Row(
                  children: [
                    Icon(
                      Icons.window_outlined,
                      size: 12,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        handleLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 300),
                      turns: _expanded ? 0.5 : 0,
                      child: Icon(
                        Icons.keyboard_arrow_up,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWindowList(ThemeData theme) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_windows == null || _windows!.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          for (final window in _windows!) _buildWindowTile(theme, window),
          const Divider(height: 1),
          ListTile(
            dense: true,
            visualDensity: _denseTileVisualDensity,
            minTileHeight: 42,
            contentPadding: _denseTilePadding,
            horizontalTitleGap: 12,
            minLeadingWidth: 20,
            leading: Icon(
              Icons.add_circle_outline,
              color: theme.colorScheme.primary,
              size: 18,
            ),
            title: const Text('New Window'),
            onTap: () {
              setState(() => _expanded = false);
              final installedToolsFuture = _tmux.detectInstalledAgentTools(
                widget.session,
              );
              showModalBottomSheet<AgentLaunchTool?>(
                context: context,
                builder: (ctx) => TmuxToolPickerSheet(
                  isProUser: widget.isProUser,
                  installedToolsFuture: installedToolsFuture,
                  preferredTool: _preferredLaunchTool,
                  onToolSelected: (tool) => Navigator.pop(ctx, tool),
                  onEmptyWindow: () {
                    Navigator.pop(ctx);
                    widget.onAction(const TmuxNewWindowAction());
                  },
                ),
              ).then((tool) {
                if (!mounted || tool == null) {
                  return;
                }
                widget.onAction(
                  TmuxNewWindowAction(
                    command: buildAgentToolCommand(
                      tool,
                      startInYoloMode: widget.startClisInYoloMode,
                    ),
                    windowName: tool.commandName,
                  ),
                );
              });
            },
          ),
          if (widget.isProUser) ...[
            const Divider(height: 1),
            _buildSessionsSection(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionsSection(ThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ListTile(
        dense: true,
        visualDensity: _denseTileVisualDensity,
        minTileHeight: 42,
        contentPadding: _denseTilePadding,
        horizontalTitleGap: 12,
        minLeadingWidth: 18,
        leading: Icon(
          Icons.smart_toy_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Text('AI Sessions'),
        trailing: Icon(
          _showSessions ? Icons.expand_less : Icons.expand_more,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onTap: () {
          final showSessions = !_showSessions;
          setState(() {
            _showSessions = showSessions;
            if (showSessions) {
              _hasInitializedSessionProviders = true;
            }
          });
          if (showSessions) {
            unawaited(_prefetchPreferredSessionProvider());
          }
        },
      ),
      if (_hasInitializedSessionProviders)
        Offstage(
          offstage: !_showSessions,
          child: AiSessionProviderList(
            key: ValueKey<Object>(
              Object.hashAll(<Object?>[
                widget.session.connectionId,
                widget.tmuxSessionName,
                _resolveRecentSessionScopeWorkingDirectory(),
              ]),
            ),
            orderedTools: orderedDiscoveredSessionTools(
              const <String, List<ToolSessionInfo>>{},
              const <String>{},
              preferredToolName:
                  _preferredLaunchTool?.discoveredSessionToolName,
            ),
            loadSessionsForTool: (toolName, maxSessions) =>
                _discovery.discoverSessionsStream(
                  widget.session,
                  workingDirectory:
                      _resolveRecentSessionScopeWorkingDirectory(),
                  maxPerTool: maxSessions,
                  toolName: toolName,
                ),
            itemBuilder: (context, provider) =>
                _buildSessionProviderTile(theme, provider),
          ),
        ),
    ],
  );

  Widget _buildSessionProviderTile(
    ThemeData theme,
    AiSessionProviderEntry provider,
  ) {
    final titleColor = provider.hasFailure
        ? theme.colorScheme.error
        : provider.isSelectable
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    final iconColor = provider.hasFailure
        ? theme.colorScheme.error
        : provider.isSelectable
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return ListTile(
      dense: true,
      visualDensity: _denseTileVisualDensity,
      minVerticalPadding: 2,
      contentPadding: _groupTilePadding,
      horizontalTitleGap: 12,
      minLeadingWidth: 18,
      leading: Icon(
        aiSessionToolIconData(provider.toolName),
        size: 16,
        color: iconColor,
      ),
      title: Text(
        provider.toolName,
        style: theme.textTheme.bodyMedium?.copyWith(color: titleColor),
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

  Widget _buildWindowTile(ThemeData theme, TmuxWindow window) {
    final isActive = window.isActive;
    final secondaryTitle = window.secondaryTitle;

    return ListTile(
      dense: true,
      visualDensity: _denseTileVisualDensity,
      minVerticalPadding: 2,
      contentPadding: const EdgeInsets.only(left: 12, right: 4),
      horizontalTitleGap: 10,
      minLeadingWidth: 24,
      tileColor: isActive
          ? theme.colorScheme.primaryContainer.withAlpha(80)
          : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Text(
          '${window.index}',
          style: theme.textTheme.labelSmall?.copyWith(
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
            onPressed: () {
              widget.onAction(TmuxCloseWindowAction(window.index));
              setState(() {
                _windows = _windows
                    ?.where((w) => w.index != window.index)
                    .toList();
              });
            },
          ),
        ],
      ),
      onTap: isActive
          ? () => setState(() => _expanded = false)
          : () {
              widget.onAction(TmuxSwitchWindowAction(window.index));
              setState(() => _expanded = false);
            },
    );
  }
}

class _ExtraKeysToggleKeycap extends StatelessWidget {
  const _ExtraKeysToggleKeycap({required this.isActive, super.key});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor =
        IconTheme.of(context).color ?? theme.colorScheme.onSurface;

    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          width: 22,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive ? iconColor.withAlpha(56) : Colors.transparent,
            border: Border.all(
              color: isActive ? iconColor : iconColor.withAlpha(190),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Fn',
            style: theme.textTheme.labelSmall?.copyWith(
              color: iconColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

final _terminalFilePathVerificationExtensionSet =
    _terminalFilePathVerificationExtensions.toSet();
final _trailingTerminalPaddingPattern = RegExp(r' +$');
const _clipboardContentChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/clipboard_content',
);
final _terminalLinkPattern = RegExp(
  r'''(?:(?:https?:\/\/)|(?:mailto:)|(?:tel:)|(?:www\.))[^\s<>"']+''',
  caseSensitive: false,
);
final _terminalFilePathPattern = RegExp(
  r'''(?:~(?:/[^\s<>"'$#&|;]+)?|/(?:[^\s<>"'$#&|;]+)|\.\.?/(?:[^\s<>"'$#&|;]+)|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)''',
);
final _terminalFilePathLineSuffixPattern = RegExp(
  r'''(?:~(?:/[^\s<>"'$#&|;]+)?/?|/(?:[^\s<>"'$#&|;]+)?|\.\.?/(?:[^\s<>"'$#&|;]+)?|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+/?)$''',
);
final _terminalFilePathStackTraceSuffixPattern = RegExp(
  r'(?:L\d+(?::\d+)?|:\d+(?::\d+)?)$',
);
final _terminalFilePathShellOperatorSuffixPattern = RegExp(
  r'(?:&&|\|\||[&;|])+$',
);
final _terminalWrappedCountSuffixPattern = RegExp(r'\d+$');
final _terminalStandalonePathMetadataPattern = RegExp(
  r'^(?:L\d+(?::\d+)?|:\d+(?::\d+)?)(?:\s|\(|$)',
);
const _terminalSftpPathPrefix = 'monkeyssh-sftp-path:';
const _terminalPathVerificationTimeout = Duration(seconds: 5);
const _terminalInputIndicatorDuration = Duration(milliseconds: 700);

typedef _TerminalPathMatch = ({
  String path,
  int start,
  int end,
  int hitTestEnd,
  int normalizedStart,
  int normalizedEnd,
});
typedef _NormalizedTerminalPathSnapshot = ({
  String text,
  List<int> originalToNormalizedOffsets,
  List<int> normalizedToOriginalStarts,
  List<int> normalizedToOriginalEnds,
});
typedef _TerminalPathTapSnapshot = ({
  String text,
  int startRow,
  List<int> rowStarts,
  List<List<int>> columnOffsets,
});
typedef _TerminalPathSnapshotAnalysis = ({
  List<_TerminalPathMatch> detectedPaths,
  _NormalizedTerminalPathSnapshot normalizedSnapshot,
});
typedef _VerifiedTerminalPath = ({String terminalPath, String resolvedPath});

enum _AutoConnectReviewDecision { skip, runOnce, trustAndRun }

/// Padding around the terminal viewport.
///
/// Keep the terminal flush with the viewport edges so status lines from tools
/// like tmux can use the full available width and height.
const terminalViewportPadding = EdgeInsets.zero;

/// Clamps a terminal font size into the supported zoom range.
@visibleForTesting
double clampTerminalFontSize(num size) =>
    size.clamp(_minTerminalFontSize, _maxTerminalFontSize).toDouble();

/// Scales a terminal font size while keeping it within the supported range.
@visibleForTesting
double scaleTerminalFontSize(double baseSize, double scale) =>
    clampTerminalFontSize(baseSize * scale);

/// Applies an incremental pinch delta to the currently displayed font size.
@visibleForTesting
double applyTerminalScaleDelta(
  double currentFontSize,
  double previousScale,
  double nextScale,
) {
  final safePreviousScale = previousScale <= 0 ? 1.0 : previousScale;
  return scaleTerminalFontSize(currentFontSize, nextScale / safePreviousScale);
}

/// Resolves the currently displayed terminal font size.
@visibleForTesting
double resolveTerminalFontSize({
  required double globalFontSize,
  double? sessionFontSize,
  double? pinchFontSize,
}) => pinchFontSize ?? sessionFontSize ?? globalFontSize;

/// Trims terminal cell padding from the end of a rendered line.
@visibleForTesting
String trimTerminalLinePadding(String line) =>
    line.replaceFirst(_trailingTerminalPaddingPattern, '');

/// Trims per-line terminal padding from copied or overlaid terminal text.
@visibleForTesting
String trimTerminalSelectionText(String text) =>
    text.split('\n').map(trimTerminalLinePadding).join('\n');

/// Keeps floating selection actions above the bottom safe area.
@visibleForTesting
double selectionActionsBottomOffset(MediaQueryData mediaQuery) =>
    _selectionActionsBottomPadding + mediaQuery.padding.bottom;

/// Keeps the Pro upsell snackbar tucked just above the visible bottom chrome.
///
/// Flutter's floating [SnackBar] already anchors itself above the keyboard
/// inset and the bottom safe area (see `Scaffold`'s snack bar layout, which
/// uses `min(contentBottom, size.height - viewPadding.bottom)`). The only
/// bottom chrome the scaffold does not know about is the in-body keyboard
/// toolbar that sits inside the body `Column`, so the margin only needs to
/// clear that toolbar with a small visual gap.
@visibleForTesting
double upgradeSnackBarBottomMargin(
  MediaQueryData mediaQuery, {
  bool showKeyboardToolbar = false,
  double keyboardToolbarHeight = 84,
  double baseSpacing = 16,
}) => (showKeyboardToolbar ? keyboardToolbarHeight : 0) + baseSpacing;

/// Resolves the transient indicator label for a terminal double-tap Tab gesture.
@visibleForTesting
String resolveTerminalTabGestureIndicatorLabel({required bool shiftActive}) =>
    shiftActive ? 'Shift+Tab' : 'Tab';

/// Resolves a readable display name for a picked upload file.
@visibleForTesting
String resolvePickedTerminalUploadFileName(PlatformFile file, {int index = 0}) {
  final name = file.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  final filePath = file.path;
  if (filePath != null && filePath.isNotEmpty) {
    return path.basename(filePath);
  }
  return 'selected-file-${index + 1}';
}

/// Resolves a readable stream for a picked upload file when available.
@visibleForTesting
Stream<List<int>>? resolvePickedTerminalUploadReadStream(PlatformFile file) =>
    file.readStream ?? (file.path == null ? null : File(file.path!).openRead());

/// Resolves the picker request used for terminal uploads.
@visibleForTesting
({
  String dialogTitle,
  FileType pickerType,
  String itemLabelSingular,
  String itemLabelPlural,
  bool allowMultiple,
  String failureContext,
})
resolveTerminalUploadPickerRequest({required bool images}) => (
  dialogTitle: images ? 'Select images to upload' : 'Select files to upload',
  pickerType: images ? FileType.image : FileType.any,
  itemLabelSingular: images ? 'image' : 'file',
  itemLabelPlural: images ? 'images' : 'files',
  allowMultiple: true,
  failureContext: images ? 'Image picker upload' : 'File picker upload',
);

/// Trims punctuation that terminals commonly render immediately after a link.
@visibleForTesting
String trimTerminalLinkCandidate(String text) {
  var result = text;
  while (result.isNotEmpty) {
    if (result.endsWith(')')) {
      final openCount = '('.allMatches(result).length;
      final closeCount = ')'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    } else if (result.endsWith(']')) {
      final openCount = '['.allMatches(result).length;
      final closeCount = ']'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    } else if (result.endsWith('}')) {
      final openCount = '{'.allMatches(result).length;
      final closeCount = '}'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    }

    final lastCharacter = result[result.length - 1];
    if ('.!,?:;'.contains(lastCharacter)) {
      result = result.substring(0, result.length - 1);
      continue;
    }

    break;
  }
  return result;
}

/// Normalizes terminal-rendered link text before URI parsing.
@visibleForTesting
String normalizeTerminalLinkCandidate(String text) {
  final candidate = trimTerminalLinkCandidate(text.trim());
  if (candidate.toLowerCase().startsWith('www.')) {
    return 'https://$candidate';
  }
  return candidate;
}

/// Trims terminal-rendered file paths before SFTP navigation.
@visibleForTesting
String trimTerminalFilePathCandidate(String text) {
  var candidate = trimTerminalLinkCandidate(text.trim());
  candidate = candidate.replaceFirst(
    _terminalFilePathStackTraceSuffixPattern,
    '',
  );
  candidate = candidate.replaceFirst(
    _terminalFilePathShellOperatorSuffixPattern,
    '',
  );
  candidate = _trimWrappedTerminalFilePathCountSuffix(candidate);
  return trimTerminalLinkCandidate(candidate);
}

String _trimWrappedTerminalFilePathCountSuffix(String text) {
  final match = _terminalWrappedCountSuffixPattern.firstMatch(text);
  if (match == null || match.start == 0) {
    return text;
  }

  final prefix = text.substring(0, match.start);
  if (!prefix.endsWith(')')) {
    return text;
  }

  final openParenCount = '('.allMatches(prefix).length;
  final closeParenCount = ')'.allMatches(prefix).length;
  if (closeParenCount <= openParenCount) {
    return text;
  }

  final trimmedPrefix = trimTerminalLinkCandidate(prefix);
  if (trimmedPrefix == prefix) {
    return text;
  }

  if (isSupportedTerminalFilePath(trimmedPrefix)) {
    return trimmedPrefix;
  }

  return text;
}

/// Whether a character can safely appear before a supported terminal path.
@visibleForTesting
bool isTerminalFilePathBoundary(String? character) =>
    character == null ||
    character.trim().isEmpty ||
    '([{"\'`=:,'.contains(character);

/// Whether a terminal path can be opened in the remote SFTP browser.
@visibleForTesting
bool isSupportedTerminalFilePath(String path) {
  if (path.isEmpty || path == '.' || path == '..' || path.startsWith('//')) {
    return false;
  }
  return isExplicitTerminalFilePath(path) ||
      isRelativeTerminalFilePathCandidate(path);
}

/// Whether a detected terminal path must be verified before becoming tappable.
@visibleForTesting
bool requiresTerminalFilePathVerification(String path) {
  if (isRelativeTerminalFilePathCandidate(path)) {
    return true;
  }

  if (hasAmbiguousTerminalFilePathParsing(path)) {
    return true;
  }

  if (!path.startsWith('/')) {
    return false;
  }

  final rootSegment = path.substring(1);
  return rootSegment.isNotEmpty &&
      !rootSegment.contains('/') &&
      !rootSegment.contains('.');
}

/// Whether a detected terminal path should currently behave like a link.
@visibleForTesting
bool shouldActivateTerminalFilePath(
  String path, {
  required bool hasVerifiedPath,
}) {
  if (requiresTerminalFilePathVerification(path)) {
    return hasVerifiedPath;
  }

  return isExplicitTerminalFilePath(path);
}

/// Whether a supported terminal path has multiple plausible parse boundaries.
@visibleForTesting
bool hasAmbiguousTerminalFilePathParsing(String path) {
  final lastSlashIndex = path.lastIndexOf('/');
  final basename = lastSlashIndex >= 0
      ? path.substring(lastSlashIndex + 1)
      : path;
  final lowercaseBasename = basename.toLowerCase();
  if (!lowercaseBasename.contains('.')) {
    return false;
  }

  final lastDotIndex = lowercaseBasename.lastIndexOf('.');
  if (lastDotIndex > 0 && lastDotIndex < lowercaseBasename.length - 1) {
    final extension = lowercaseBasename.substring(lastDotIndex + 1);
    if (_terminalFilePathVerificationExtensionSet.contains(extension)) {
      final marker = '.$extension';
      if (lowercaseBasename.indexOf(marker) == lastDotIndex &&
          lowercaseBasename.lastIndexOf(marker) == lastDotIndex) {
        return false;
      }
    }
  }

  return resolveTerminalFilePathVerificationCandidates(path).length > 1;
}

bool _isTerminalFilePathVerificationSuffixCharacter(String character) {
  if (character.isEmpty) {
    return false;
  }

  final codeUnit = character.codeUnitAt(0);
  return (codeUnit >= 48 && codeUnit <= 57) ||
      (codeUnit >= 65 && codeUnit <= 90) ||
      (codeUnit >= 97 && codeUnit <= 122) ||
      codeUnit == 45 ||
      codeUnit == 95;
}

bool _startsWithKnownTerminalFilePathExtensionAndMore(String suffix) {
  if (!suffix.startsWith('.')) {
    return false;
  }

  final lowercaseSuffix = suffix.toLowerCase();
  for (final extension in _terminalFilePathVerificationExtensions) {
    final extensionMarker = '.$extension';
    if (lowercaseSuffix.startsWith(extensionMarker) &&
        suffix.length > extensionMarker.length) {
      return true;
    }
  }
  return false;
}

bool _hasExcessClosingTerminalFilePathBrackets(String value) {
  var openParens = 0;
  var closeParens = 0;
  var openBrackets = 0;
  var closeBrackets = 0;
  var openBraces = 0;
  var closeBraces = 0;

  for (var index = 0; index < value.length; index++) {
    switch (value[index]) {
      case '(':
        openParens++;
        break;
      case ')':
        closeParens++;
        break;
      case '[':
        openBrackets++;
        break;
      case ']':
        closeBrackets++;
        break;
      case '{':
        openBraces++;
        break;
      case '}':
        closeBraces++;
        break;
      default:
        break;
    }
  }

  return closeParens > openParens ||
      closeBrackets > openBrackets ||
      closeBraces > openBraces;
}

/// Alternative terminal-path parses to check when a candidate looks ambiguous.
@visibleForTesting
List<String> resolveTerminalFilePathVerificationCandidates(String path) {
  final candidates = <String>[];
  final seen = <String>{};
  final seedCandidates = <String>[];

  void addCandidate(String candidate) {
    if (candidates.length >= _maxTerminalFilePathVerificationCandidates) {
      return;
    }
    final normalizedCandidate = trimTerminalFilePathCandidate(candidate);
    if (normalizedCandidate.isEmpty ||
        !isSupportedTerminalFilePath(normalizedCandidate) ||
        !seen.add(normalizedCandidate)) {
      return;
    }
    candidates.add(normalizedCandidate);
  }

  void addSeedCandidate(String candidate) {
    final beforeCount = candidates.length;
    addCandidate(candidate);
    if (candidates.length > beforeCount) {
      seedCandidates.add(candidates.last);
    }
  }

  addSeedCandidate(path);

  var trailingBracketCandidate = trimTerminalFilePathCandidate(path);
  if (_hasExcessClosingTerminalFilePathBrackets(trailingBracketCandidate)) {
    while (trailingBracketCandidate.isNotEmpty &&
        ')]}'.contains(
          trailingBracketCandidate[trailingBracketCandidate.length - 1],
        )) {
      trailingBracketCandidate = trailingBracketCandidate.substring(
        0,
        trailingBracketCandidate.length - 1,
      );
      addSeedCandidate(trailingBracketCandidate);
    }
  }

  for (final seed in seedCandidates) {
    final lastSlashIndex = seed.lastIndexOf('/');
    final basename = lastSlashIndex >= 0
        ? seed.substring(lastSlashIndex + 1)
        : seed;
    final basenamePrefix = lastSlashIndex >= 0
        ? seed.substring(0, lastSlashIndex + 1)
        : '';
    final lowercaseBasename = basename.toLowerCase();
    for (final extension in _terminalFilePathVerificationExtensions) {
      final extensionMarker = '.$extension';
      var markerIndex = lowercaseBasename.indexOf(extensionMarker);
      while (markerIndex >= 0) {
        final candidateEnd = markerIndex + extensionMarker.length;
        if (candidateEnd < basename.length) {
          final remainder = basename.substring(candidateEnd);
          if (_isTerminalFilePathVerificationSuffixCharacter(
                basename[candidateEnd],
              ) ||
              _startsWithKnownTerminalFilePathExtensionAndMore(remainder)) {
            addCandidate(
              '$basenamePrefix${basename.substring(0, candidateEnd)}',
            );
          }
        }
        markerIndex = lowercaseBasename.indexOf(
          extensionMarker,
          markerIndex + 1,
        );
      }
    }
  }

  if (candidates.length > 2) {
    final primaryCandidate = candidates.first;
    final alternativeCandidates = candidates.sublist(1)
      ..sort((left, right) => right.length.compareTo(left.length));
    return [primaryCandidate, ...alternativeCandidates];
  }

  return candidates;
}

/// Candidate terminal cells to probe for a touch-friendly path hit test.
@visibleForTesting
List<CellOffset> resolveForgivingTerminalTapOffsets(CellOffset offset) {
  final offsets = <CellOffset>[];
  final seen = <String>{};

  void addOffset(int dx, int dy) {
    final candidate = CellOffset(offset.x + dx, offset.y + dy);
    final key = '${candidate.x}:${candidate.y}';
    if (seen.add(key)) {
      offsets.add(candidate);
    }
  }

  addOffset(0, 0);
  for (var dx = 1; dx <= 4; dx++) {
    addOffset(-dx, 0);
    addOffset(dx, 0);
  }
  for (final dy in const [-1, 1]) {
    addOffset(0, dy);
    for (var dx = 1; dx <= 2; dx++) {
      addOffset(-dx, dy);
      addOffset(dx, dy);
    }
  }

  return offsets;
}

/// Visible terminal rows for the current scroll offset and rendered viewport.
@visibleForTesting
({int topRow, int bottomRow})? resolveVisibleTerminalRowRange({
  required double scrollOffset,
  required double lineHeight,
  required double viewportHeight,
  required int bufferHeight,
}) {
  if (lineHeight <= 0 || viewportHeight <= 0 || bufferHeight <= 0) {
    return null;
  }

  final maxRow = bufferHeight - 1;
  final topRow = (scrollOffset / lineHeight).floor().clamp(0, maxRow);
  final visibleRows = (viewportHeight / lineHeight).ceil().clamp(
    1,
    bufferHeight,
  );
  final bottomRow = (topRow + visibleRows - 1).clamp(0, maxRow);
  return (topRow: topRow, bottomRow: bottomRow);
}

/// Builds a visible underline rect that hugs the bottom of a terminal row.
@visibleForTesting
Rect? resolveTerminalPathUnderlineRect({
  required Offset lineTopLeft,
  required Offset lineEndOffset,
  required double lineHeight,
  required double viewportHeight,
  double? rowHeight,
  double? textHeight,
}) {
  final width = lineEndOffset.dx - lineTopLeft.dx;
  if (width <= 0 || lineHeight <= 0 || viewportHeight <= 0) {
    return null;
  }

  final effectiveRowHeight = (rowHeight ?? lineHeight) < lineHeight
      ? lineHeight
      : (rowHeight ?? lineHeight);
  final effectiveTextHeight = textHeight ?? effectiveRowHeight;
  final thickness = (effectiveTextHeight * 0.08).clamp(0.75, 2.5);
  final rowBottom = lineTopLeft.dy + effectiveRowHeight;
  final preferredTop = lineTopLeft.dy + effectiveTextHeight + 0.25;
  final maxTopWithinRow = rowBottom - thickness - 0.5;
  final top = min(
    preferredTop,
    maxTopWithinRow,
  ).clamp(0.0, viewportHeight - thickness);
  return Rect.fromLTWH(lineTopLeft.dx, top, width, thickness);
}

/// Builds a forgiving touch target around a terminal path segment.
@visibleForTesting
Rect? resolveTerminalPathTouchTargetRect({
  required Offset lineTopLeft,
  required Offset lineEndOffset,
  required double lineHeight,
  required double viewportHeight,
  double horizontalPadding = _terminalPathTouchHorizontalPadding,
  double verticalPadding = _terminalPathTouchVerticalPadding,
}) {
  final width = lineEndOffset.dx - lineTopLeft.dx;
  if (width <= 0 || lineHeight <= 0 || viewportHeight <= 0) {
    return null;
  }

  final left = (lineTopLeft.dx - horizontalPadding).clamp(0.0, double.infinity);
  final top = (lineTopLeft.dy - verticalPadding).clamp(0.0, viewportHeight);
  final right = lineEndOffset.dx + horizontalPadding;
  final bottom = (lineTopLeft.dy + lineHeight + verticalPadding).clamp(
    top,
    viewportHeight,
  );
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Resolves which visible terminal path touch target, if any, a tap landed on.
@visibleForTesting
String? resolveTerminalPathTouchTargetTap(
  Offset localPosition,
  List<({String path, Rect touchRect})> targets,
) {
  for (final target in targets.reversed) {
    if (target.touchRect.contains(localPosition)) {
      return target.path;
    }
  }
  return null;
}

/// Whether a terminal path is anchored to `/` or `~`.
@visibleForTesting
bool isExplicitTerminalFilePath(String path) =>
    path.startsWith('/') || path == '~' || path.startsWith('~/');

/// Whether a relative terminal path looks file-like enough to probe safely.
@visibleForTesting
bool isRelativeTerminalFilePathCandidate(String path) {
  if (isExplicitTerminalFilePath(path) ||
      path.isEmpty ||
      path == '.' ||
      path == '..' ||
      path.startsWith('//') ||
      !path.contains('/')) {
    return false;
  }

  if (path.startsWith('./') || path.startsWith('../')) {
    return true;
  }

  final basename = path.split('/').last;
  return basename.contains('.');
}

bool _isTerminalFilePathBodyCharacter(String character) =>
    character.isNotEmpty &&
    !RegExp(r'''[\s<>"'$#]''').hasMatch(character) &&
    !_isTerminalPathContinuationDecorationCharacter(character);

bool _isTerminalPathContinuationDecorationCharacter(String character) =>
    character == ' ' ||
    character == '\t' ||
    '│┃║╎┆┊|├┤┬┴┼└┘┌┐╭╮╯╰─━═'.contains(character);

String _trimTerminalPathContinuationPrefix(String text) {
  var index = 0;
  while (index < text.length &&
      _isTerminalPathContinuationDecorationCharacter(text[index])) {
    index++;
  }
  return text.substring(index);
}

bool _startsFreshTerminalFilePathLine(String text) =>
    text == '~' ||
    text.startsWith('~/') ||
    text.startsWith('/') ||
    text.startsWith('./') ||
    text.startsWith('../');

String? _leadingTerminalFilePathCandidate(String text) {
  final match = _terminalFilePathPattern.matchAsPrefix(text);
  if (match == null) {
    return null;
  }

  final candidate = trimTerminalFilePathCandidate(match.group(0)!);
  return isSupportedTerminalFilePath(candidate) ? candidate : null;
}

bool _hasMeaningfulTextBeforeTrailingTerminalPath(
  String text,
  Match trailingPathMatch,
) => _trimTerminalPathContinuationPrefix(
  text.substring(0, trailingPathMatch.start),
).trim().isNotEmpty;

bool _endsWithTerminalPathContinuationBoundary(String path) =>
    path == '~' || path.endsWith('/');

bool _hasLeadingTerminalPathFragment(String text) =>
    text.isNotEmpty && _isTerminalFilePathBodyCharacter(text[0]);

bool _looksLikeTerminalPathContinuationAcrossRenderedLines({
  required String previousText,
  required String nextText,
}) {
  final trimmedPreviousText = trimTerminalLinePadding(previousText);
  final trimmedNextText = trimTerminalLinePadding(nextText);
  if (trimmedPreviousText.isEmpty || trimmedNextText.isEmpty) {
    return false;
  }
  if (_terminalStandalonePathMetadataPattern.hasMatch(trimmedNextText)) {
    return false;
  }

  final previousPathMatch = _terminalFilePathLineSuffixPattern.firstMatch(
    trimmedPreviousText,
  );
  if (previousPathMatch == null) {
    return false;
  }

  final previousPath = trimTerminalFilePathCandidate(
    previousPathMatch.group(0)!,
  );
  final previousHasLeadingContext =
      _hasMeaningfulTextBeforeTrailingTerminalPath(
        trimmedPreviousText,
        previousPathMatch,
      );
  final previousEndsWithBoundary = _endsWithTerminalPathContinuationBoundary(
    previousPath,
  );
  final nextLeadingPath = _leadingTerminalFilePathCandidate(trimmedNextText);

  if (_startsFreshTerminalFilePathLine(trimmedNextText)) {
    return previousHasLeadingContext || previousEndsWithBoundary;
  }

  if (nextLeadingPath != null && !isExplicitTerminalFilePath(nextLeadingPath)) {
    if (!previousHasLeadingContext &&
        !previousEndsWithBoundary &&
        !isExplicitTerminalFilePath(previousPath)) {
      return false;
    }
    return true;
  }

  return _hasLeadingTerminalPathFragment(trimmedNextText);
}

/// Whether adjacent rendered lines should be treated as one file-path span.
@visibleForTesting
bool isTerminalPathContinuationAcrossLines({
  required String previousLineText,
  required String nextLineText,
}) => _looksLikeTerminalPathContinuationAcrossRenderedLines(
  previousText: previousLineText,
  nextText: _trimTerminalPathContinuationPrefix(nextLineText),
);

_NormalizedTerminalPathSnapshot _normalizeTerminalFilePathDetectionText(
  String text,
) {
  final normalizedCharacters = <String>[];
  final originalToNormalizedOffsets = List<int>.filled(text.length + 1, 0);
  final normalizedToOriginalStarts = <int>[];
  final normalizedToOriginalEnds = <int>[];
  var index = 0;
  var lineStart = 0;

  while (index < text.length) {
    final character = text[index];
    if (character == '\r' || character == '\n') {
      var lineBreakEnd = index + 1;
      if (character == '\r' &&
          lineBreakEnd < text.length &&
          text[lineBreakEnd] == '\n') {
        lineBreakEnd++;
      }

      var continuationEnd = lineBreakEnd;
      while (continuationEnd < text.length &&
          _isTerminalPathContinuationDecorationCharacter(
            text[continuationEnd],
          )) {
        continuationEnd++;
      }

      var nextLineEnd = continuationEnd;
      while (nextLineEnd < text.length &&
          text[nextLineEnd] != '\r' &&
          text[nextLineEnd] != '\n') {
        nextLineEnd++;
      }

      final isPathContinuation =
          continuationEnd < text.length &&
          _looksLikeTerminalPathContinuationAcrossRenderedLines(
            previousText: text.substring(lineStart, index),
            nextText: text.substring(continuationEnd, nextLineEnd),
          );
      if (isPathContinuation) {
        for (
          var skippedIndex = index;
          skippedIndex < continuationEnd;
          skippedIndex++
        ) {
          originalToNormalizedOffsets[skippedIndex] =
              normalizedCharacters.length;
        }
        lineStart = lineBreakEnd;
        index = continuationEnd;
        continue;
      }

      final normalizedIndex = normalizedCharacters.length;
      for (var sourceIndex = index; sourceIndex < lineBreakEnd; sourceIndex++) {
        originalToNormalizedOffsets[sourceIndex] = normalizedIndex;
      }
      normalizedCharacters.add('\n');
      normalizedToOriginalStarts.add(index);
      normalizedToOriginalEnds.add(lineBreakEnd);
      lineStart = lineBreakEnd;
      index = lineBreakEnd;
      continue;
    }

    final normalizedIndex = normalizedCharacters.length;
    originalToNormalizedOffsets[index] = normalizedIndex;
    normalizedCharacters.add(character);
    normalizedToOriginalStarts.add(index);
    normalizedToOriginalEnds.add(index + 1);
    index++;
  }

  originalToNormalizedOffsets[text.length] = normalizedCharacters.length;
  return (
    text: normalizedCharacters.join(),
    originalToNormalizedOffsets: originalToNormalizedOffsets,
    normalizedToOriginalStarts: normalizedToOriginalStarts,
    normalizedToOriginalEnds: normalizedToOriginalEnds,
  );
}

List<_TerminalPathMatch> _detectTerminalFilePathMatches(String text) {
  final normalizedText = _normalizeTerminalFilePathDetectionText(text);
  final detectedPaths = <_TerminalPathMatch>[];

  for (final match in _terminalFilePathPattern.allMatches(
    normalizedText.text,
  )) {
    final previousCharacter = match.start == 0
        ? null
        : normalizedText.text.substring(match.start - 1, match.start);
    if (!isTerminalFilePathBoundary(previousCharacter)) {
      continue;
    }

    final candidate = trimTerminalFilePathCandidate(match.group(0)!);
    if (!isSupportedTerminalFilePath(candidate)) {
      continue;
    }

    final visualEnd = match.start + candidate.length;
    final originalStart =
        normalizedText.normalizedToOriginalStarts[match.start];
    final originalEnd = normalizedText.normalizedToOriginalEnds[visualEnd - 1];
    final originalHitTestEnd =
        normalizedText.normalizedToOriginalEnds[match.end - 1];
    detectedPaths.add((
      path: candidate,
      start: originalStart,
      end: originalEnd,
      hitTestEnd: originalHitTestEnd,
      normalizedStart: match.start,
      normalizedEnd: visualEnd,
    ));
  }

  return detectedPaths;
}

/// Resolves the visible row segment for the first matching path on a row.
@visibleForTesting
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRowForPath({
  required String snapshotText,
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required String path,
}) {
  final normalizedSnapshot = _normalizeTerminalFilePathDetectionText(
    snapshotText,
  );
  for (final match in _detectTerminalFilePathMatches(snapshotText)) {
    if (match.path != path) {
      continue;
    }
    final segment = resolveTerminalFilePathSegmentOnRow(
      rowText: rowText,
      rowStartOffset: rowStartOffset,
      rowColumnOffsets: rowColumnOffsets,
      originalToNormalizedOffsets:
          normalizedSnapshot.originalToNormalizedOffsets,
      normalizedPathStart: match.normalizedStart,
      normalizedPathEnd: match.normalizedEnd,
    );
    if (segment != null) {
      return segment;
    }
  }
  return null;
}

/// Resolves the visible path-only segment for a specific rendered row.
@visibleForTesting
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRow({
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required List<int> originalToNormalizedOffsets,
  required int normalizedPathStart,
  required int normalizedPathEnd,
}) {
  if (rowText.isEmpty || rowColumnOffsets.length < 2) {
    return null;
  }

  int? startColumn;
  int? endColumn;
  for (var column = 0; column < rowColumnOffsets.length - 1; column++) {
    final textStart = rowColumnOffsets[column];
    if (textStart < 0 || textStart >= rowText.length) {
      if (startColumn != null) {
        break;
      }
      continue;
    }
    final textEnd = rowColumnOffsets[column + 1].clamp(
      textStart + 1,
      rowText.length,
    );
    final character = rowText.substring(textStart, textEnd);
    if (!_isTerminalFilePathBodyCharacter(character)) {
      if (startColumn != null) {
        break;
      }
      continue;
    }

    final normalizedOffset =
        originalToNormalizedOffsets[rowStartOffset + textStart];
    if (normalizedOffset < normalizedPathStart ||
        normalizedOffset >= normalizedPathEnd) {
      if (startColumn != null) {
        break;
      }
      continue;
    }
    startColumn ??= column;
    endColumn = column;
  }

  if (startColumn == null || endColumn == null) {
    return null;
  }

  final segmentStart = rowColumnOffsets[startColumn];
  final segmentEnd = rowColumnOffsets[endColumn + 1].clamp(
    segmentStart + 1,
    rowText.length,
  );
  return (
    text: rowText.substring(segmentStart, segmentEnd),
    startColumn: startColumn,
    endColumn: endColumn,
  );
}

/// Resolves all tappable terminal file paths within the given text.
@visibleForTesting
List<({String path, int start, int end})> detectTerminalFilePaths(
  String text,
) => [
  for (final path in _detectTerminalFilePathMatches(text))
    (path: path.path, start: path.start, end: path.end),
];

/// Resolves a tappable terminal file path at the given text offset, if present.
@visibleForTesting
({String path, int start, int end})? detectTerminalFilePathAtTextOffset(
  String text,
  int offset,
) {
  final clampedOffset = offset.clamp(0, text.length);
  for (final detectedPath in _detectTerminalFilePathMatches(text)) {
    if (clampedOffset >= detectedPath.start &&
        clampedOffset < detectedPath.hitTestEnd) {
      return (
        path: detectedPath.path,
        start: detectedPath.start,
        end: detectedPath.end,
      );
    }
  }

  return null;
}

/// Resolves a tappable terminal link at the given text offset, if present.
@visibleForTesting
({Uri uri, int start, int end})? detectTerminalLinkAtTextOffset(
  String text,
  int offset,
) {
  for (final match in _terminalLinkPattern.allMatches(text)) {
    final candidate = trimTerminalLinkCandidate(match.group(0)!);
    if (candidate.isEmpty) {
      continue;
    }

    final normalizedCandidate = normalizeTerminalLinkCandidate(candidate);
    final uri = Uri.tryParse(normalizedCandidate);
    if (uri == null || !isLaunchableTerminalUri(uri)) {
      continue;
    }

    final end = match.start + candidate.length;
    if (offset >= match.start && offset < end) {
      return (uri: uri, start: match.start, end: end);
    }
  }

  return null;
}

/// Whether a parsed terminal URI is safe to open externally.
@visibleForTesting
bool isLaunchableTerminalUri(Uri uri) =>
    uri.hasScheme &&
    <String>{
      'http',
      'https',
      'mailto',
      'tel',
    }.contains(uri.scheme.toLowerCase());

/// Extracts the currently selected text from the native selection overlay.
@visibleForTesting
String selectedNativeOverlayText(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed) {
    return '';
  }

  return selection.textInside(value.text);
}

/// Applies pasted or rendered text at the terminal cursor within a wrapped line.
@visibleForTesting
String applyTerminalCursorInsertion({
  required String currentText,
  required int cursorOffset,
  required String insertedText,
}) => currentText.replaceRange(cursorOffset, cursorOffset, insertedText);

/// Applies terminal-style backspaces before inserting newly committed text.
@visibleForTesting
String applyTerminalInputDelta({
  required String currentText,
  required int cursorOffset,
  required int deletedCount,
  required String appendedText,
}) {
  final deleteStart = cursorOffset > deletedCount
      ? cursorOffset - deletedCount
      : 0;
  return currentText.replaceRange(deleteStart, cursorOffset, appendedText);
}

@visibleForTesting
/// Resolves how much of a terminal row snapshot should remain after trimming.
int resolveTerminalLineSnapshotTextLength({
  required String text,
  required int preserveOffset,
  required bool preserveTrailingPadding,
}) {
  if (preserveTrailingPadding) {
    return text.length;
  }

  final trimmedLength = trimTerminalLinePadding(text).length;
  var clampedPreserveOffset = preserveOffset;
  if (clampedPreserveOffset < 0) {
    clampedPreserveOffset = 0;
  } else if (clampedPreserveOffset > text.length) {
    clampedPreserveOffset = text.length;
  }
  return trimmedLength >= clampedPreserveOffset
      ? trimmedLength
      : clampedPreserveOffset;
}

/// Whether to let xterm synthesize Up/Down keys for alt-buffer scroll.
///
/// We prefer explicit mouse-wheel reporting from terminal applications like
/// tmux, but still need the synthetic fallback whenever the active alt-buffer
/// app has not enabled wheel reporting yet.
@visibleForTesting
bool shouldUseSyntheticAltBufferScrollFallback({
  required bool isUsingAltBuffer,
  required bool preferExplicitMouseReporting,
  required bool terminalReportsMouseWheel,
}) {
  if (!isUsingAltBuffer) {
    return false;
  }

  if (!preferExplicitMouseReporting) {
    return true;
  }

  return !terminalReportsMouseWheel;
}

/// Whether mobile touch drags should be routed into terminal scroll input.
///
/// Full-screen apps like tmux or Copilot CLI need direct wheel or synthetic
/// arrow events instead of letting the Flutter viewport absorb the gesture.
@visibleForTesting
bool shouldRouteTouchScrollToTerminal({
  required bool isMobile,
  required bool isUsingAltBuffer,
  required bool terminalReportsMouseWheel,
}) => isMobile && (isUsingAltBuffer || terminalReportsMouseWheel);

/// Whether the native selection overlay should be visible for terminal content.
@visibleForTesting
bool shouldShowNativeSelectionOverlay({
  required bool isNativeSelectionMode,
  required bool routesTouchScrollToTerminal,
  required bool revealOverlayInTouchScrollMode,
}) =>
    isNativeSelectionMode &&
    (!routesTouchScrollToTerminal || revealOverlayInTouchScrollMode);

/// Whether the native overlay currently holds an expanded text selection.
@visibleForTesting
bool hasActiveNativeOverlaySelection(TextSelection selection) =>
    selection.isValid && !selection.isCollapsed;

/// Whether terminal tap links should be resolved for the current overlay state.
@visibleForTesting
bool shouldResolveTerminalTapLinks({
  required bool showsNativeSelectionOverlay,
}) => !showsNativeSelectionOverlay;

typedef _NativeSelectionSnapshotMetrics = ({
  List<int> lineStarts,
  List<List<int>> columnOffsets,
  int lineCount,
  int viewWidth,
  int textLength,
});

typedef _NativeSelectionSnapshotData = ({
  String text,
  List<int> lineStarts,
  List<List<int>> columnOffsets,
  int lineCount,
  int viewWidth,
  int textLength,
});

typedef _PendingTouchSelectionSnapshot = ({
  CellOffset originCellOffset,
  String text,
  TextSelection selection,
  List<int> lineStarts,
  List<List<int>> columnOffsets,
  int lineCount,
  int viewWidth,
  int textLength,
  bool revealOverlayInTouchScrollMode,
});

/// How a native selection change should update the mobile overlay state.
@visibleForTesting
enum NativeSelectionOverlayChange {
  /// Leaves the current overlay and selection mode state unchanged.
  none,

  /// Hides only the temporary overlay used during tmux touch-selection flows.
  hideTemporaryOverlay,

  /// Leaves native selection mode entirely so terminal input becomes editable.
  exitSelectionMode,
}

/// Resolves how collapsed mobile selections should unwind overlay state.
@visibleForTesting
NativeSelectionOverlayChange resolveNativeSelectionOverlayChange({
  required bool isMobilePlatform,
  required bool isNativeSelectionMode,
  required bool revealOverlayInTouchScrollMode,
  required TextSelection selection,
}) {
  if (!isNativeSelectionMode || !selection.isCollapsed) {
    return NativeSelectionOverlayChange.none;
  }

  if (revealOverlayInTouchScrollMode) {
    return NativeSelectionOverlayChange.hideTemporaryOverlay;
  }

  if (isMobilePlatform) {
    return NativeSelectionOverlayChange.exitSelectionMode;
  }

  return NativeSelectionOverlayChange.none;
}

String? _describeMouseMode(
  MouseMode mouseMode,
  MouseReportMode mouseReportMode,
) => switch (mouseMode) {
  MouseMode.none => null,
  MouseMode.clickOnly => 'Mouse clicks',
  MouseMode.upDownScroll => 'Mouse scroll (${mouseReportMode.name})',
  MouseMode.upDownScrollDrag => 'Mouse drag (${mouseReportMode.name})',
  MouseMode.upDownScrollMove => 'Mouse motion (${mouseReportMode.name})',
};

/// Whether live terminal output should keep following the current viewport.
@visibleForTesting
bool shouldFollowTerminalOutput({
  required bool hasScrollClients,
  required double currentOffset,
  required double maxScrollExtent,
  double tolerance = _terminalFollowOutputTolerance,
}) {
  if (!hasScrollClients) {
    return true;
  }

  return currentOffset >= maxScrollExtent - tolerance;
}

/// Whether terminal scroll policy state changed enough to require a rebuild.
@visibleForTesting
bool didTerminalScrollPolicyChange({
  required bool previousIsUsingAltBuffer,
  required bool nextIsUsingAltBuffer,
  required bool previousReportsMouseWheel,
  required bool nextReportsMouseWheel,
}) =>
    previousIsUsingAltBuffer != nextIsUsingAltBuffer ||
    previousReportsMouseWheel != nextReportsMouseWheel;

/// Terminal screen for SSH sessions.
class TerminalScreen extends ConsumerStatefulWidget {
  /// Creates a new [TerminalScreen].
  const TerminalScreen({required this.hostId, this.connectionId, super.key});

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  static const _localClipboardSyncInterval = Duration(milliseconds: 750);
  static const _remoteClipboardSyncInterval = Duration(seconds: 1);
  static const _promptOutputImeResetDebounce = Duration(milliseconds: 75);
  final _terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

  late Terminal _terminal;
  late final TerminalController _terminalController;
  late final ScrollController _terminalScrollController;
  late final ScrollController _nativeSelectionScrollController;
  late final TextEditingController _nativeSelectionController;
  late final FocusNode _nativeSelectionFocusNode;
  late FocusNode _terminalFocusNode;
  final _terminalTextInputController = TerminalTextInputHandlerController();
  final _toolbarController = KeyboardToolbarController();
  SSHSession? _shell;
  StreamSubscription<void>? _doneSubscription;
  StreamSubscription<String>? _shellStdoutSubscription;
  bool _isConnecting = true;
  String? _error;
  bool _showKeyboardToolbar = true;
  bool _isUsingAltBuffer = false;
  bool _terminalReportsMouseWheel = false;
  bool _hasTerminalSelection = false;
  bool _isNativeSelectionMode = false;
  bool _revealsNativeSelectionOverlayInTouchScrollMode = false;
  bool _isSyncingNativeScroll = false;
  bool _hadNativeOverlaySelection = false;
  _PendingTouchSelectionSnapshot? _pendingTouchSelectionRange;
  _PendingTouchSelectionSnapshot? _pendingNativeOverlayLongPressSelection;
  _NativeSelectionSnapshotMetrics? _nativeSelectionSnapshotMetrics;
  _NativeSelectionSnapshotData? _nativeSelectionSnapshotCache;
  Timer? _nativeOverlayCollapseTimer;
  Timer? _nativeOverlayLongPressTimer;
  int? _nativeOverlayPointerId;
  Offset? _nativeOverlayPointerDownPosition;
  int? _connectionId;
  double? _pinchFontSize;
  double? _lastPinchScale;
  double? _sessionFontSizeOverride;
  bool _isPinchZooming = false;
  bool _shouldFollowLiveOutput = true;
  bool _isTerminalScrollToBottomQueued = false;
  TerminalHyperlinkTracker? _terminalHyperlinkTracker;
  SshSession? _observedSession;
  bool _showsTerminalMetadata = false;
  bool _isTmuxActive = false;
  String? _tmuxSessionName;
  bool _showTmuxBar = true;
  String? _tmuxLaunchWorkingDirectory;
  String? _tmuxWorkingDirectory;
  int _tmuxDetectionGeneration = 0;
  final Map<String, _VerifiedTerminalPath> _verifiedTerminalPathCache =
      <String, _VerifiedTerminalPath>{};
  final ListQueue<String> _verifiedTerminalPathCacheOrder = ListQueue<String>();
  final Set<String> _verifyingTerminalPathCacheKeys = <String>{};
  String? _terminalPathCacheScope;
  String? _pendingTerminalPathTap;
  Rect? _hoveredTerminalPathUnderline;
  List<({String path, Rect underlineRect, Rect touchRect})>
  _visibleTerminalPathUnderlines =
      const <({String path, Rect underlineRect, Rect touchRect})>[];
  bool _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = true;
  bool? _lastShowsTerminalPathUnderlines;
  CellOffset? _lastHoveredTerminalPathOffset;
  String? _lastHoveredTerminalPath;
  bool _isTerminalPathUnderlineRefreshQueued = false;
  SshSession? _terminalPathVerificationSession;
  Future<SftpClient?>? _terminalPathVerificationSftpFuture;
  SftpClient? _terminalPathVerificationSftp;
  String? _terminalPathVerificationHomeDirectory;
  late final ProviderSubscription<bool> _sharedClipboardSubscription;
  Timer? _localClipboardSyncTimer;
  Timer? _remoteClipboardSyncTimer;
  Timer? _terminalInputIndicatorTimer;
  Timer? _promptOutputImeResetTimer;
  bool _isPollingRemoteClipboard = false;
  bool _isPushingLocalClipboard = false;
  bool _remoteClipboardUnsupported = false;
  String? _lastObservedLocalClipboardText;
  String? _lastObservedRemoteClipboardText;
  String? _lastAppliedLocalClipboardText;
  String? _lastAppliedRemoteClipboardText;
  String? _terminalInputIndicatorLabel;

  // Theme state
  Host? _host;
  bool _startClisInYoloMode = false;
  TerminalThemeData? _currentTheme;
  TerminalThemeData? _sessionThemeOverride;

  // Cache the notifier for use in dispose
  ActiveSessionsNotifier? _sessionsNotifier;

  // Track whether the app is in the background so we can auto-reconnect
  // when it resumes if the OS killed the socket.
  bool _wasBackgrounded = false;
  bool _connectionLostWhileBackgrounded = false;

  bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isAndroidPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _hasExpandedNativeOverlaySelection =>
      _isNativeSelectionMode &&
      hasActiveNativeOverlaySelection(_nativeSelectionController.selection);

  bool get _routesTouchScrollToTerminal => shouldRouteTouchScrollToTerminal(
    isMobile: _isMobilePlatform,
    isUsingAltBuffer: _isUsingAltBuffer,
    terminalReportsMouseWheel: _terminalReportsMouseWheel,
  );

  bool get _showsNativeSelectionOverlay => shouldShowNativeSelectionOverlay(
    isNativeSelectionMode: _isNativeSelectionMode,
    routesTouchScrollToTerminal: _routesTouchScrollToTerminal,
    revealOverlayInTouchScrollMode:
        _revealsNativeSelectionOverlayInTouchScrollMode,
  );

  String? get _windowTitle => _observedSession?.windowTitle;

  String? get _iconName => _observedSession?.iconName;

  Uri? get _workingDirectory => _observedSession?.workingDirectory;

  String? get _liveWorkingDirectoryPath =>
      resolveTerminalWorkingDirectoryPath(_workingDirectory);

  String? get _workingDirectoryLabel =>
      formatTerminalWorkingDirectoryLabel(_workingDirectory);

  String? get _workingDirectoryPath =>
      _liveWorkingDirectoryPath ?? _tmuxWorkingDirectory;

  TerminalShellStatus? get _shellStatus => _observedSession?.shellStatus;

  int? get _lastExitCode => _observedSession?.lastExitCode;

  bool get _shouldReviewTerminalCommandInsertion =>
      shouldReviewTerminalCommandInsertion(
        shellStatus: _shellStatus,
        isUsingAltBuffer: _isUsingAltBuffer,
      );

  String _terminalCommandAfterInsertion(String insertedText) {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return insertedText;
    }
    return applyTerminalCursorInsertion(
      currentText: snapshot.text,
      cursorOffset: snapshot.cursorOffset,
      insertedText: insertedText,
    );
  }

  String _terminalCommandAfterInputDelta(
    ({int deletedCount, String appendedText}) delta,
    String fallbackText,
  ) {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return fallbackText;
    }

    return applyTerminalInputDelta(
      currentText: snapshot.text,
      cursorOffset: snapshot.cursorOffset,
      deletedCount: delta.deletedCount,
      appendedText: delta.appendedText,
    );
  }

  bool _sameTerminalCommandReview(
    TerminalCommandReview previous,
    TerminalCommandReview next,
  ) =>
      previous.command == next.command &&
      previous.bracketedPasteModeEnabled == next.bracketedPasteModeEnabled &&
      listEquals(previous.reasons, next.reasons);

  Future<bool> _confirmTerminalInsertionIfNeeded({
    required String insertedText,
    required TerminalCommandReview Function(String commandText) buildReview,
    required String title,
    required String Function(TerminalCommandReview review) messageBuilder,
    required String confirmLabel,
  }) async {
    while (mounted) {
      final review = buildReview(_terminalCommandAfterInsertion(insertedText));
      if (!review.requiresReview) {
        return true;
      }

      final shouldInsert = await _confirmCommandInsertion(
        title: title,
        message: messageBuilder(review),
        confirmLabel: confirmLabel,
        review: review,
      );
      if (!mounted || !shouldInsert) {
        return false;
      }

      final latestReview = buildReview(
        _terminalCommandAfterInsertion(insertedText),
      );
      if (_sameTerminalCommandReview(review, latestReview)) {
        return true;
      }
    }

    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sharedClipboardSubscription = ref.listenManual<bool>(
      sharedClipboardNotifierProvider,
      (previous, next) =>
          unawaited(_applySharedClipboardSetting(enabled: next)),
    );
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminalScrollController = ScrollController()
      ..addListener(_handleTerminalScroll);
    _nativeSelectionScrollController = ScrollController()
      ..addListener(_syncTerminalScrollFromNative);
    _nativeSelectionController = TextEditingController()
      ..addListener(_onNativeOverlayControllerChanged);
    _nativeSelectionFocusNode = FocusNode();
    _isUsingAltBuffer = _terminal.isUsingAltBuffer;
    _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    _terminal.addListener(_onTerminalStateChanged);
    _terminalController.addListener(_onSelectionChanged);
    _terminalFocusNode = FocusNode();
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_loadHostAndConnect);
  }

  void _onTerminalStateChanged() {
    _nativeSelectionSnapshotCache = null;
    if (_isNativeSelectionMode && !_hasExpandedNativeOverlaySelection) {
      _refreshNativeOverlayText(preserveSelection: true);
    }

    _queueVisibleTerminalPathUnderlineRefresh();

    if (_shouldFollowLiveOutput && !_hasExpandedNativeOverlaySelection) {
      _queueTerminalScrollToBottom();
    }

    final isUsingAltBuffer = _terminal.isUsingAltBuffer;
    final terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    if (!mounted ||
        !didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: _isUsingAltBuffer,
          nextIsUsingAltBuffer: isUsingAltBuffer,
          previousReportsMouseWheel: _terminalReportsMouseWheel,
          nextReportsMouseWheel: terminalReportsMouseWheel,
        )) {
      return;
    }

    setState(() {
      _isUsingAltBuffer = isUsingAltBuffer;
      _terminalReportsMouseWheel = terminalReportsMouseWheel;
    });
  }

  void _observeSessionMetadata(SshSession session) {
    if (identical(_observedSession, session)) {
      return;
    }

    if (!identical(_terminalPathVerificationSession, session)) {
      _disposeTerminalPathVerificationSftp();
    }
    _observedSession?.removeMetadataListener(_handleSessionMetadataChanged);
    _observedSession = session
      ..removeMetadataListener(_handleSessionMetadataChanged)
      ..addMetadataListener(_handleSessionMetadataChanged);
  }

  void _handleSessionMetadataChanged() {
    if (!mounted) {
      return;
    }
    _syncVerifiedTerminalPathCacheScope();
    setState(() {});
  }

  Future<void> _applySharedClipboardSetting({
    required bool enabled,
    SshSession? session,
    bool waitForInitialSync = true,
  }) async {
    final targetSession =
        session ??
        _observedSession ??
        (_connectionId == null
            ? null
            : _sessionsNotifier?.getSession(_connectionId!));
    if (targetSession == null) {
      return;
    }

    targetSession.clipboardSharingEnabled = enabled;
    if (!enabled) {
      _stopSharedClipboardSync();
      return;
    }

    if (waitForInitialSync) {
      await _startSharedClipboardSync(targetSession);
      return;
    }

    unawaited(_startSharedClipboardSync(targetSession));
  }

  Future<void> _startSharedClipboardSync(SshSession session) async {
    _stopSharedClipboardSync();
    _remoteClipboardUnsupported = false;
    _lastObservedLocalClipboardText = await _readSystemClipboardText();
    _lastObservedRemoteClipboardText = await _readRemoteClipboardText(session);

    if (!mounted ||
        !session.clipboardSharingEnabled ||
        _remoteClipboardUnsupported) {
      return;
    }

    _localClipboardSyncTimer = Timer.periodic(
      _localClipboardSyncInterval,
      (_) => unawaited(_syncLocalClipboardToRemote(session)),
    );
    if (!_remoteClipboardUnsupported) {
      _remoteClipboardSyncTimer = Timer.periodic(
        _remoteClipboardSyncInterval,
        (_) => unawaited(_syncRemoteClipboardToLocal(session)),
      );
    }
  }

  void _stopSharedClipboardSync() {
    _localClipboardSyncTimer?.cancel();
    _localClipboardSyncTimer = null;
    _remoteClipboardSyncTimer?.cancel();
    _remoteClipboardSyncTimer = null;
    _isPollingRemoteClipboard = false;
    _isPushingLocalClipboard = false;
  }

  Future<String?> _readSystemClipboardText() async {
    try {
      if (_isAndroidPlatform) {
        return Pasteboard.text;
      }
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _syncLocalClipboardToRemote(SshSession session) async {
    if (!mounted ||
        !session.clipboardSharingEnabled ||
        !identical(_observedSession, session) ||
        _remoteClipboardUnsupported ||
        _isPushingLocalClipboard) {
      return;
    }

    final localText = await _readSystemClipboardText();
    if (localText == null ||
        localText == _lastObservedLocalClipboardText ||
        localText == _lastObservedRemoteClipboardText ||
        localText == _lastAppliedLocalClipboardText ||
        !RemoteClipboardSyncService.canSyncText(localText)) {
      _lastObservedLocalClipboardText = localText;
      return;
    }

    _isPushingLocalClipboard = true;
    try {
      final output = await _runRemoteCommand(
        session,
        RemoteClipboardSyncService.buildWriteCommand(localText),
      );
      if (RemoteClipboardSyncService.outputIndicatesUnsupported(output)) {
        _remoteClipboardUnsupported = true;
        _remoteClipboardSyncTimer?.cancel();
        _remoteClipboardSyncTimer = null;
        return;
      }
      _lastObservedLocalClipboardText = localText;
      _lastObservedRemoteClipboardText = localText;
      _lastAppliedRemoteClipboardText = localText;
    } finally {
      _isPushingLocalClipboard = false;
    }
  }

  Future<void> _syncRemoteClipboardToLocal(SshSession session) async {
    if (!mounted ||
        !session.clipboardSharingEnabled ||
        !identical(_observedSession, session) ||
        _remoteClipboardUnsupported ||
        _isPollingRemoteClipboard) {
      return;
    }

    _isPollingRemoteClipboard = true;
    try {
      final remoteText = await _readRemoteClipboardText(session);
      if (remoteText == null ||
          remoteText == _lastObservedRemoteClipboardText ||
          remoteText == _lastObservedLocalClipboardText ||
          remoteText == _lastAppliedRemoteClipboardText) {
        if (remoteText != null) {
          _lastObservedRemoteClipboardText = remoteText;
        }
        return;
      }

      await Clipboard.setData(ClipboardData(text: remoteText));
      _lastObservedRemoteClipboardText = remoteText;
      _lastObservedLocalClipboardText = remoteText;
      _lastAppliedLocalClipboardText = remoteText;
    } on PlatformException {
      return;
    } finally {
      _isPollingRemoteClipboard = false;
    }
  }

  Future<String?> _readRemoteClipboardText(SshSession session) async {
    final output = await _runRemoteCommand(
      session,
      RemoteClipboardSyncService.buildReadCommand(),
    );
    final parsed = RemoteClipboardSyncService.parseReadOutput(output);
    if (!parsed.supported) {
      _remoteClipboardUnsupported = true;
      return null;
    }
    return parsed.text;
  }

  Future<String> _runRemoteCommand(SshSession session, String command) async {
    final exec = await session.execute(command);
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutFuture = exec.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .forEach(stdout.write);
    final stderrFuture = exec.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .forEach(stderr.write);
    await Future.wait<void>([stdoutFuture, stderrFuture, exec.done]);
    return stdout.toString().isNotEmpty ? stdout.toString() : stderr.toString();
  }

  void _handleTerminalScroll() {
    _shouldFollowLiveOutput = shouldFollowTerminalOutput(
      hasScrollClients: _terminalScrollController.hasClients,
      currentOffset: _terminalScrollController.hasClients
          ? _terminalScrollController.offset
          : 0,
      maxScrollExtent: _terminalScrollController.hasClients
          ? _terminalScrollController.position.maxScrollExtent
          : 0,
    );
    _syncNativeScrollFromTerminal();
    _refreshVisibleTerminalPathUnderlines();
  }

  void _followLiveOutput() {
    _shouldFollowLiveOutput = true;
    _queueTerminalScrollToBottom();
  }

  void _handleTerminalDoubleTapDown(
    TapDownDetails tapDetails,
    CellOffset cellOffset,
  ) {
    _clearPendingTouchSelectionRange();
    final shiftActive = _toolbarController.isShiftActive;
    _terminalTextInputController.suppressNextTouchKeyboardRequest();
    _terminal.textInput(resolveTerminalTabInput(shiftActive: shiftActive));
    _followLiveOutput();
    _toolbarController.consumeOneShot();
    _showTerminalInputIndicator(
      resolveTerminalTabGestureIndicatorLabel(shiftActive: shiftActive),
    );
  }

  void _handleTerminalTapUp(TapUpDetails tapDetails, CellOffset cellOffset) {
    _clearPendingTouchSelectionRange();
  }

  void _handleTerminalTapDown(
    TapDownDetails tapDetails,
    CellOffset cellOffset,
  ) {
    _cachePendingTouchSelectionSnapshot(tapDetails, cellOffset);
  }

  void _handleTerminalLinkTapDown(
    TapDownDetails tapDetails,
    CellOffset cellOffset,
  ) {
    _terminalTextInputController.suppressNextTouchKeyboardRequest();
    _cachePendingTouchSelectionSnapshot(tapDetails, cellOffset);
  }

  void _cachePendingTouchSelectionSnapshot(
    TapDownDetails tapDetails,
    CellOffset cellOffset,
  ) {
    if (!_isMobilePlatform || _showsNativeSelectionOverlay) {
      _clearPendingTouchSelectionRange();
      return;
    }

    final kind = tapDetails.kind;
    if (kind != null && !_isNativeOverlayTouchPointer(kind)) {
      _clearPendingTouchSelectionRange();
      return;
    }

    final snapshot = _buildPendingTouchSelectionSnapshot(
      cellOffset,
      revealOverlayInTouchScrollMode: _routesTouchScrollToTerminal,
    );
    _clearPendingTouchSelectionRange();
    if (snapshot == null) {
      return;
    }
    _pendingTouchSelectionRange = snapshot;
  }

  void _handleTerminalLongPressStart(
    LongPressStartDetails details,
    CellOffset cellOffset,
  ) {
    _terminalTextInputController.suppressNextTouchKeyboardRequest();
    final pendingSnapshot = _pendingTouchSelectionRange;
    _pendingTouchSelectionRange = null;
    if (pendingSnapshot != null) {
      _enterNativeSelectionModeWithSnapshot(pendingSnapshot);
      return;
    }
    _selectNativeOverlayWordAtCellOffset(
      cellOffset,
      revealOverlayInTouchScrollMode: _routesTouchScrollToTerminal,
    );
  }

  void _showTerminalInputIndicator(String label) {
    _terminalInputIndicatorTimer?.cancel();
    setState(() => _terminalInputIndicatorLabel = label);
    _terminalInputIndicatorTimer = Timer(_terminalInputIndicatorDuration, () {
      if (!mounted) {
        return;
      }
      setState(() => _terminalInputIndicatorLabel = null);
    });
  }

  void _queueTerminalScrollToBottom() {
    if (_isTerminalScrollToBottomQueued) {
      return;
    }

    _isTerminalScrollToBottomQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalScrollToBottomQueued = false;
      if (!mounted ||
          !_shouldFollowLiveOutput ||
          !_terminalScrollController.hasClients) {
        return;
      }

      final position = _terminalScrollController.position;
      if (shouldFollowTerminalOutput(
        hasScrollClients: true,
        currentOffset: _terminalScrollController.offset,
        maxScrollExtent: position.maxScrollExtent,
      )) {
        return;
      }

      _terminalScrollController.jumpTo(position.maxScrollExtent);
    });
  }

  void _onSelectionChanged() {
    if (!mounted) {
      return;
    }

    final selection = _terminalController.selection;
    final hasSelection = selection != null;
    if (_isMobilePlatform && hasSelection) {
      _enterNativeSelectionMode(
        initialRange: selection,
        revealOverlayInTouchScrollMode: _routesTouchScrollToTerminal,
      );
      return;
    }

    if (_hasTerminalSelection == hasSelection) {
      return;
    }

    setState(() {
      _hasTerminalSelection = hasSelection;
    });
  }

  void _syncNativeScrollFromTerminal({bool force = false}) {
    if (!_showsNativeSelectionOverlay ||
        (!force && _hasExpandedNativeOverlaySelection) ||
        _isSyncingNativeScroll ||
        !_terminalScrollController.hasClients ||
        !_nativeSelectionScrollController.hasClients) {
      return;
    }

    _isSyncingNativeScroll = true;
    final targetOffset = _terminalScrollController.offset.clamp(
      0.0,
      _nativeSelectionScrollController.position.maxScrollExtent,
    );
    _nativeSelectionScrollController.jumpTo(targetOffset);
    _isSyncingNativeScroll = false;
  }

  void _syncTerminalScrollFromNative() {
    if (!_showsNativeSelectionOverlay ||
        _isSyncingNativeScroll ||
        !_nativeSelectionScrollController.hasClients ||
        !_terminalScrollController.hasClients) {
      return;
    }

    _isSyncingNativeScroll = true;
    final targetOffset = _nativeSelectionScrollController.offset.clamp(
      0.0,
      _terminalScrollController.position.maxScrollExtent,
    );
    _terminalScrollController.jumpTo(targetOffset);
    _isSyncingNativeScroll = false;
  }

  Future<void> _loadHostAndConnect() async {
    // Load host data first for theme
    final hostRepo = ref.read(hostRepositoryProvider);
    _host = await hostRepo.getById(widget.hostId);
    final cliLaunchPreferences = await ref
        .read(hostCliLaunchPreferencesServiceProvider)
        .getPreferencesForHost(widget.hostId);
    _startClisInYoloMode = cliLaunchPreferences.startInYoloMode;
    await _loadTheme();
    await _connect(preferredConnectionId: widget.connectionId);
  }

  Future<void> _loadTheme() async {
    if (!mounted) return;

    final brightness = MediaQuery.of(context).platformBrightness;
    final themeService = ref.read(terminalThemeServiceProvider);
    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final theme = await themeService.getThemeForHost(
      _host,
      brightness,
      allowHostOverride: monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      ),
    );

    if (mounted) {
      setState(() => _currentTheme = theme);
    }
  }

  Future<bool> _restoreSessionThemeOverride(SshSession session) async {
    final brightness = Theme.of(context).brightness;
    final themeId = brightness == Brightness.dark
        ? session.terminalThemeDarkId
        : session.terminalThemeLightId;

    if (themeId == null) {
      if (mounted) {
        setState(() => _sessionThemeOverride = null);
      }
      return false;
    }

    final themeService = ref.read(terminalThemeServiceProvider);
    final resolvedTheme = await themeService.getThemeById(themeId);
    if (!mounted) {
      return false;
    }
    setState(() => _sessionThemeOverride = resolvedTheme);
    return resolvedTheme != null;
  }

  Future<void> _connect({
    int? preferredConnectionId,
    bool forceNew = false,
  }) async {
    if (!mounted) return;

    // Clean up any previous connection state before reconnecting.
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    await _shellStdoutSubscription?.cancel();
    _shellStdoutSubscription = null;
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = null;
    _shell = null;

    setState(() {
      _isConnecting = true;
      _error = null;
    });

    _sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    var shouldForceNew = forceNew;
    if (preferredConnectionId != null) {
      _connectionId = preferredConnectionId;
      final existingSession = _sessionsNotifier!.getSession(
        preferredConnectionId,
      );
      if (existingSession != null) {
        await _sessionsNotifier!.syncBackgroundStatus();
        await _openShell(existingSession);
        return;
      }
      shouldForceNew = true;
    }

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;

    final result = await _sessionsNotifier!.connect(
      widget.hostId,
      forceNew: shouldForceNew,
      useHostThemeOverrides: monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      ),
    );

    if (!mounted) return;

    if (!result.success || result.connectionId == null) {
      setState(() {
        _isConnecting = false;
        _error = result.error ?? 'Connection failed';
      });
      return;
    }

    _connectionId = result.connectionId;
    final session = _sessionsNotifier!.getSession(_connectionId!);
    if (session == null) {
      setState(() {
        _isConnecting = false;
        _error = 'Session not found';
      });
      return;
    }

    await _openShell(session);
  }

  Future<void> _openShell(SshSession session) async {
    if (!mounted) {
      return;
    }

    try {
      // Reuse the session's persistent terminal if it exists (preserves
      // scrollback and screen buffer across screen navigations).
      final existingTerminal = session.terminal;
      if (existingTerminal != null) {
        final sharedClipboardEnabled = await ref.read(
          sharedClipboardProvider.future,
        );
        session.clipboardSharingEnabled = sharedClipboardEnabled;
        _terminal.removeListener(_onTerminalStateChanged);
        _terminal = existingTerminal;
        _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
        _observeSessionMetadata(session);
        _isUsingAltBuffer = _terminal.isUsingAltBuffer;
        _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
        _terminal.addListener(_onTerminalStateChanged);
        _shell = await session.getShell();
        _wireTerminalCallbacks(session);
        await _applySharedClipboardSetting(
          enabled: sharedClipboardEnabled,
          session: session,
          waitForInitialSync: false,
        );
        await _restoreSessionThemeOverride(session);
        setState(() {
          _sessionFontSizeOverride = session.terminalFontSize;
          _isConnecting = false;
        });
        _restoreTerminalFocus();

        // Detect tmux on existing sessions too (may not have been detected
        // yet if the terminal was opened before tmux started).
        if (!_isTmuxActive) {
          unawaited(_detectTmux(session, skipDelay: true));
        }
        return;
      }

      // First time opening shell for this session — create terminal in session.
      final sessionTerminal = session.getOrCreateTerminal();
      final sharedClipboardEnabled = await ref.read(
        sharedClipboardProvider.future,
      );
      session.clipboardSharingEnabled = sharedClipboardEnabled;
      _terminal.removeListener(_onTerminalStateChanged);
      _terminal = sessionTerminal;
      _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
      _observeSessionMetadata(session);
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      _terminal.addListener(_onTerminalStateChanged);

      _shell = await session.getShell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      _wireTerminalCallbacks(session);
      await _applySharedClipboardSetting(
        enabled: sharedClipboardEnabled,
        session: session,
        waitForInitialSync: false,
      );

      if (!mounted) return;

      await _restoreSessionThemeOverride(session);
      setState(() {
        _sessionFontSizeOverride = session.terminalFontSize;
        _isConnecting = false;
      });
      _restoreTerminalFocus();
      _primeTmuxStateFromHost();

      // Start port forwards
      await _startPortForwards(session);
      await _runAutoConnectCommand();

      // Detect tmux after the auto-connect command has had time to start.
      // A small delay ensures tmux has initialized if the auto-connect
      // command launches a tmux session.
      unawaited(_detectTmux(session));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _error = 'Failed to start shell: $e';
      });
    }
  }

  /// Wire terminal onOutput/onResize callbacks for this screen instance.
  void _wireTerminalCallbacks(SshSession session) {
    // Listen for shell close events.
    _doneSubscription = session.shellDoneStream.listen((_) {
      if (mounted) {
        _handleShellClosed();
      }
    });
    _shellStdoutSubscription = session.shellStdoutStream.listen(
      _schedulePromptOutputImeResetCheck,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Terminal stdout stream error: $error');
        debugPrint('$stackTrace');
      },
    );

    _terminal.onOutput = (data) {
      // On iOS/Android soft keyboards, Return sends a lone '\n' via
      // textInput(), but SSH expects '\r'. The proper
      // keyInput(TerminalKey.enter) path already produces '\r', so we
      // only normalize single-'\n' to avoid rewriting legitimate LF
      // characters in pasted or multi-char input.
      var output = data == '\n' ? '\r' : data;

      // Apply toolbar modifier state to system keyboard input.
      // When the user toggles Ctrl on the toolbar then types on the system
      // keyboard, we convert the character to the corresponding control code.
      output = _toolbarController.applySystemKeyboardModifiers(output);

      _shell?.write(utf8.encode(output));
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _shell?.resizeTerminal(width, height);
    };
  }

  void _schedulePromptOutputImeResetCheck(String data) {
    if (!_isMobilePlatform || !_shellOutputLooksLikePromptReturn(data)) {
      return;
    }
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = Timer(_promptOutputImeResetDebounce, () {
      _promptOutputImeResetTimer = null;
      if (!mounted) {
        return;
      }
      _terminalTextInputController.handleExternalTerminalOutput();
    });
  }

  bool _shellOutputLooksLikePromptReturn(String data) {
    final sanitizedData = _stripTerminalPromptEscapeSequences(data);
    if (sanitizedData.isEmpty) {
      return false;
    }

    var index = sanitizedData.length - 1;
    while (index >= 0) {
      final codeUnit = sanitizedData.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return false;
      }
      if (!_isPromptReturnWhitespaceCodeUnit(codeUnit)) {
        break;
      }
      index--;
    }

    if (index < 0) {
      return false;
    }

    var visibleCodeUnitCount = 0;
    while (index >= 0) {
      final codeUnit = sanitizedData.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        break;
      }
      if (!_isPromptReturnWhitespaceCodeUnit(codeUnit)) {
        visibleCodeUnitCount++;
        if (visibleCodeUnitCount > 4) {
          return false;
        }
        if (_isPromptReturnAsciiLetterOrDigit(codeUnit)) {
          return false;
        }
      }
      index--;
    }

    return visibleCodeUnitCount > 0;
  }

  /// Starts auto-start port forwards for this host.
  Future<void> _startPortForwards(SshSession session) async {
    final portForwardRepo = ref.read(portForwardRepositoryProvider);
    final forwards = await portForwardRepo.getByHostId(widget.hostId);

    final autoStartForwards = forwards.where((f) => f.autoStart).toList();
    if (autoStartForwards.isEmpty) return;

    var startedCount = 0;
    final failedNames = <String>[];
    for (final forward in autoStartForwards) {
      if (forward.forwardType == 'local') {
        final success = await session.startLocalForward(
          portForwardId: forward.id,
          localHost: forward.localHost,
          localPort: forward.localPort,
          remoteHost: forward.remoteHost,
          remotePort: forward.remotePort,
        );
        if (success) {
          startedCount++;
        } else {
          failedNames.add(forward.name);
        }
      } else if (forward.forwardType == 'remote') {
        final success = await session.startRemoteForward(
          portForwardId: forward.id,
          remoteHost: forward.remoteHost,
          remotePort: forward.remotePort,
          localHost: forward.localHost,
          localPort: forward.localPort,
        );
        if (success) {
          startedCount++;
        } else {
          failedNames.add(forward.name);
        }
      }
    }

    if (mounted) {
      if (failedNames.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Started $startedCount forward(s), '
              'failed: ${failedNames.join(', ')}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      } else if (startedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Started $startedCount port forward(s)'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _runAutoConnectCommand() async {
    final host = _host;
    final shell = _shell;
    if (host == null || shell == null) {
      return;
    }

    // Structured tmux attach is a first-class connection mode, not a generic
    // automation command. Run it even when Pro-only auto-connect automation is
    // unavailable so tmux-native navigation remains accessible.
    final tmuxSession = host.tmuxSessionName;
    if (tmuxSession != null && tmuxSession.isNotEmpty) {
      final tmuxCommand = buildTmuxCommand(
        sessionName: tmuxSession,
        workingDirectory: host.tmuxWorkingDirectory,
        extraFlags: host.tmuxExtraFlags,
      );
      final review = assessAutoConnectCommandExecution(
        tmuxCommand,
        importedNeedsReview: host.autoConnectRequiresConfirmation,
      );
      if (review.requiresReview) {
        final decision = await _reviewImportedAutoConnectCommand(review);
        if (!mounted || decision == _AutoConnectReviewDecision.skip) {
          return;
        }
        if (decision == _AutoConnectReviewDecision.trustAndRun) {
          final updatedHost = host.copyWith(
            autoConnectRequiresConfirmation: false,
          );
          await ref.read(hostRepositoryProvider).update(updatedHost);
          _host = updatedHost;
        }
      }
      shell.write(utf8.encode(formatAutoConnectCommandForShell(tmuxCommand)));
      return;
    }

    final hasAccess = await ref
        .read(monetizationServiceProvider)
        .canUseFeature(MonetizationFeature.autoConnectAutomation);
    if (!hasAccess) {
      if (mounted) {
        final bottomMargin = upgradeSnackBarBottomMargin(
          MediaQuery.of(context),
          showKeyboardToolbar: _showKeyboardToolbar,
          keyboardToolbarHeight: resolveKeyboardToolbarHeight(
            MediaQuery.of(context),
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
            content: const Text(
              'MonkeySSH Pro unlocks auto-connect commands and snippets.',
            ),
            action: SnackBarAction(
              label: 'Upgrade',
              onPressed: () => context.pushNamed(
                Routes.upgrade,
                queryParameters: <String, String>{
                  'feature': MonetizationFeature.autoConnectAutomation.name,
                },
              ),
            ),
          ),
        );
      }
      return;
    }

    final mode = resolveAutoConnectCommandMode(
      command: host.autoConnectCommand,
      snippetId: host.autoConnectSnippetId,
    );
    if (mode == AutoConnectCommandMode.none) {
      return;
    }

    String? snippetCommand;
    int? resolvedSnippetId;
    final snippetId = host.autoConnectSnippetId;
    if (snippetId != null) {
      final snippetRepo = ref.read(snippetRepositoryProvider);
      final snippet = await snippetRepo.getById(snippetId);
      if (snippet == null) {
        debugPrint(
          'Auto-connect snippet $snippetId is unavailable; using cached command.',
        );
      } else {
        snippetCommand = snippet.command;
        resolvedSnippetId = snippet.id;
      }
    }

    final command = resolveAutoConnectCommandText(
      mode: mode,
      storedCommand: host.autoConnectCommand,
      snippetCommand: snippetCommand,
    );
    if (command == null) {
      return;
    }

    final review = assessAutoConnectCommandExecution(
      command,
      importedNeedsReview: host.autoConnectRequiresConfirmation,
    );
    if (review.requiresReview) {
      final decision = await _reviewImportedAutoConnectCommand(review);
      if (!mounted || decision == _AutoConnectReviewDecision.skip) {
        return;
      }
      if (decision == _AutoConnectReviewDecision.trustAndRun) {
        final updatedHost = host.copyWith(
          autoConnectRequiresConfirmation: false,
        );
        await ref.read(hostRepositoryProvider).update(updatedHost);
        _host = updatedHost;
      }
    }

    shell.write(utf8.encode(formatAutoConnectCommandForShell(command)));
    if (resolvedSnippetId != null) {
      unawaited(
        ref.read(snippetRepositoryProvider).incrementUsage(resolvedSnippetId),
      );
    }
  }

  void _primeTmuxStateFromHost() {
    final host = _host;
    final preferredSessionName = resolvePreferredTmuxSessionName(
      structuredSessionName: host?.tmuxSessionName,
      autoConnectCommand: host?.autoConnectCommand,
    );
    if (!mounted || preferredSessionName == null) {
      return;
    }

    final preferredWorkingDirectory = host?.tmuxWorkingDirectory;
    setState(() {
      _isTmuxActive = true;
      _tmuxSessionName = preferredSessionName;
      _tmuxLaunchWorkingDirectory = preferredWorkingDirectory;
      _tmuxWorkingDirectory = preferredWorkingDirectory;
    });
  }

  /// Detects whether the connected session is inside tmux.
  ///
  /// Starts with any structured tmux configuration immediately, then retries
  /// discovery until the shell-side attach command has settled.
  Future<void> _detectTmux(SshSession session, {bool skipDelay = false}) async {
    // Capture the connection ID at the start so we can verify it hasn't
    // changed after async gaps (user may have switched connections).
    final capturedConnectionId = _connectionId;
    final detectionGeneration = ++_tmuxDetectionGeneration;
    final host = _host;
    final preferredSessionName = resolvePreferredTmuxSessionName(
      structuredSessionName: host?.tmuxSessionName,
      autoConnectCommand: host?.autoConnectCommand,
    );
    final preferredWorkingDirectory = host?.tmuxWorkingDirectory;

    if (mounted) {
      setState(() {
        _isTmuxActive = preferredSessionName != null;
        _tmuxSessionName = preferredSessionName;
        _tmuxLaunchWorkingDirectory = preferredWorkingDirectory;
        _tmuxWorkingDirectory = preferredWorkingDirectory;
      });
    }

    try {
      final tmux = ref.read(tmuxServiceProvider);
      final retrySchedule = resolveTmuxDetectionRetrySchedule(
        skipDelay: skipDelay,
      );

      for (final delay in retrySchedule) {
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
          if (!mounted ||
              _connectionId != capturedConnectionId ||
              detectionGeneration != _tmuxDetectionGeneration) {
            return;
          }
        }

        final active = preferredSessionName != null
            ? await tmux.hasSession(session, preferredSessionName)
            : await tmux.isTmuxActive(session);
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return;
        }
        if (!active) {
          continue;
        }

        var sessionName = preferredSessionName;
        sessionName ??= await tmux.currentSessionName(session);
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return;
        }
        if (sessionName == null) {
          continue;
        }

        // Get the active window's working directory for SFTP/path resolution.
        var tmuxLaunchCwd = preferredWorkingDirectory;
        var tmuxCwd = preferredWorkingDirectory;
        try {
          final windows = await tmux.listWindows(session, sessionName);
          final activeWindow = windows.where((w) => w.isActive).firstOrNull;
          tmuxLaunchCwd ??= activeWindow?.currentPath;
          tmuxCwd ??= activeWindow?.currentPath;
        } on Object {
          // Non-critical — path resolution will fall back to OSC 7.
        }

        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return;
        }

        setState(() {
          _isTmuxActive = true;
          _tmuxSessionName = sessionName;
          _tmuxLaunchWorkingDirectory = tmuxLaunchCwd;
          _tmuxWorkingDirectory = tmuxCwd;
        });
        return;
      }

      if (!mounted ||
          _connectionId != capturedConnectionId ||
          detectionGeneration != _tmuxDetectionGeneration) {
        return;
      }

      setState(() {
        _isTmuxActive = false;
        _tmuxSessionName = null;
        _tmuxLaunchWorkingDirectory = null;
        _tmuxWorkingDirectory = null;
      });
    } on Object {
      // Silently ignore — tmux detection is best-effort.
    }
  }

  /// Wraps the terminal view in a Stack with the tmux bar overlaid.
  ///
  /// When tmux is active, the terminal gets bottom padding equal to the
  /// handle bar height so the collapsed handle sits over empty space.
  /// When expanded, the bar slides up over the terminal content.
  /// When tmux is not active, the terminal fills the entire space.
  Widget _buildTerminalWithTmuxBar(
    TerminalThemeData terminalTheme,
    bool isMobile,
    ThemeData theme,
    SshConnectionState connectionState,
  ) {
    final showTmux =
        _isTmuxActive &&
        _showTmuxBar &&
        connectionState == SshConnectionState.connected;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tmuxBarSafeInsets = resolveTmuxBarSafeInsets(
          MediaQuery.of(context),
        );
        final targetBottomPadding = showTmux
            ? _TmuxExpandableBar.handleHeight + tmuxBarSafeInsets.bottom
            : 0.0;
        final availableHeight = max(
          0,
          constraints.maxHeight - tmuxBarSafeInsets.bottom,
        ).toDouble();

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetBottomPadding),
          duration: _tmuxBarRevealDuration,
          curve: Curves.easeOutCubic,
          child: _buildTmuxExpandableBar(theme, availableHeight),
          builder: (context, animatedBottomPadding, child) {
            final barOpacity = resolveTmuxBarRevealOpacity(
              animatedBottomPadding,
            );

            return Stack(
              children: [
                // Reserve actual layout space for the collapsed handle so the
                // terminal viewport ends exactly at the handle boundary.
                Positioned.fill(
                  child: ColoredBox(
                    color: terminalTheme.background,
                    child: Column(
                      children: [
                        Expanded(
                          child: _buildTerminalView(terminalTheme, isMobile),
                        ),
                        SizedBox(height: animatedBottomPadding),
                      ],
                    ),
                  ),
                ),
                if (showTmux || animatedBottomPadding > 0)
                  Positioned(
                    left: tmuxBarSafeInsets.left,
                    right: tmuxBarSafeInsets.right,
                    bottom: resolveTmuxBarRevealBottomOffset(
                      animatedBottomPadding,
                    ),
                    child: IgnorePointer(
                      ignoring: barOpacity == 0,
                      child: Opacity(
                        opacity: barOpacity,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// Builds the tmux expandable bar overlaid at the bottom of the terminal.
  Widget _buildTmuxExpandableBar(ThemeData theme, double availableHeight) {
    final connectionId = _connectionId;
    if (connectionId == null || _tmuxSessionName == null) {
      return const SizedBox.shrink();
    }

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return const SizedBox.shrink();

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isProUser = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );

    return _TmuxExpandableBar(
      session: session,
      tmuxSessionName: _tmuxSessionName!,
      availableHeight: availableHeight,
      isProUser: isProUser,
      startClisInYoloMode: _startClisInYoloMode,
      ref: ref,
      onAction: _handleTmuxAction,
      scopeWorkingDirectory: resolveTmuxAiSessionScopeWorkingDirectory(
        liveTerminalWorkingDirectory: _liveWorkingDirectoryPath,
        tmuxWorkingDirectory: _tmuxWorkingDirectory,
        sessionWorkingDirectory: session.workingDirectory,
      ),
    );
  }

  /// Handles an action from the draggable tmux panel.
  Future<void> _handleTmuxAction(TmuxNavigatorAction action) async {
    final connectionId = _connectionId;
    if (connectionId == null) return;
    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return;

    switch (action) {
      case TmuxSwitchWindowAction(:final windowIndex):
        await _switchTmuxWindow(session, windowIndex);
      case TmuxNewWindowAction(:final command, :final windowName):
        await _createTmuxWindow(session, command: command, name: windowName);
      case TmuxResumeSessionAction(
        :final resumeCommand,
        :final workingDirectory,
      ):
        await _createTmuxWindow(
          session,
          command: resumeCommand,
          workingDirectory: workingDirectory,
        );
      case TmuxCloseWindowAction(:final windowIndex):
        _closeTmuxWindow(session, windowIndex);
    }
  }

  /// Opens the tmux window navigator bottom sheet and handles the
  /// selected action.
  Future<void> _openTmuxNavigator() async {
    final connectionId = _connectionId;
    if (connectionId == null || _tmuxSessionName == null) return;

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return;

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isProUser = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );

    final action = await showTmuxNavigator(
      context: context,
      ref: ref,
      session: session,
      tmuxSessionName: _tmuxSessionName!,
      isProUser: isProUser,
      startClisInYoloMode: _startClisInYoloMode,
      scopeWorkingDirectory: resolveTmuxAiSessionScopeWorkingDirectory(
        liveTerminalWorkingDirectory: _liveWorkingDirectoryPath,
        tmuxWorkingDirectory: _tmuxWorkingDirectory,
        sessionWorkingDirectory: session.workingDirectory,
      ),
    );

    if (!mounted || action == null) return;

    switch (action) {
      case TmuxSwitchWindowAction(:final windowIndex):
        await _switchTmuxWindow(session, windowIndex);
      case TmuxNewWindowAction(:final command, :final windowName):
        await _createTmuxWindow(session, command: command, name: windowName);
      case TmuxResumeSessionAction(
        :final resumeCommand,
        :final workingDirectory,
      ):
        await _createTmuxWindow(
          session,
          command: resumeCommand,
          workingDirectory: workingDirectory,
        );
      case TmuxCloseWindowAction(:final windowIndex):
        _closeTmuxWindow(session, windowIndex);
    }
  }

  /// Switches to a different tmux window via exec channel.
  ///
  /// Uses an exec channel (not the interactive shell) because
  /// `tmux select-window` is a server operation — the tmux server
  /// notifies all attached clients of the change. Writing to the PTY
  /// would inject the command as input to whatever program is running.
  Future<void> _switchTmuxWindow(SshSession session, int windowIndex) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    ref
        .read(tmuxServiceProvider)
        .selectWindow(session, sessionName, windowIndex);

    // Clear stale working directory — it will be refreshed from
    // OSC 7 or the next tmux query.
    _tmuxWorkingDirectory = null;
    await _reattachTmuxIfNeeded(session, sessionName);
  }

  /// Creates a new tmux window via exec channel, then reattaches the visible
  /// terminal if tmux is no longer in the foreground there.
  ///
  /// Prefers the tmux session's current pane directory so "new window" starts
  /// where the user is actually working, while still preserving explicit
  /// working-directory overrides (e.g. resuming an AI session).
  Future<void> _createTmuxWindow(
    SshSession session, {
    String? command,
    String? name,
    String? workingDirectory,
  }) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    final tmux = ref.read(tmuxServiceProvider);
    String? currentPaneWorkingDirectory;
    if (!(workingDirectory?.trim().isNotEmpty ?? false)) {
      currentPaneWorkingDirectory = await tmux.currentPanePath(
        session,
        sessionName,
      );
    }
    if (!mounted) return;
    final resolvedWorkingDirectory = resolveTmuxWindowWorkingDirectory(
      explicitWorkingDirectory: workingDirectory,
      currentPaneWorkingDirectory: currentPaneWorkingDirectory,
      observedWorkingDirectory: _tmuxWorkingDirectory ?? _workingDirectoryPath,
      launchWorkingDirectory: _tmuxLaunchWorkingDirectory,
      hostWorkingDirectory: _host?.tmuxWorkingDirectory,
    );
    await tmux.createWindow(
      session,
      sessionName,
      command: command,
      name: name,
      workingDirectory: resolvedWorkingDirectory,
    );
    _tmuxWorkingDirectory = resolvedWorkingDirectory;
    await _reattachTmuxIfNeeded(session, sessionName);
  }

  /// Closes a tmux window via exec channel.
  void _closeTmuxWindow(SshSession session, int windowIndex) {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    ref.read(tmuxServiceProvider).killWindow(session, sessionName, windowIndex);
  }

  Future<void> _reattachTmuxIfNeeded(
    SshSession session,
    String sessionName,
  ) async {
    final tmux = ref.read(tmuxServiceProvider);
    final hasForegroundClient = await tmux.hasForegroundClient(
      session,
      sessionName,
    );
    if (!mounted || hasForegroundClient) {
      return;
    }

    if (!shouldReattachTmuxAfterWindowAction(
      hasForegroundClient: hasForegroundClient,
      shellStatus: _shellStatus,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'tmux updated $sessionName, but this terminal is outside tmux '
            'while a command is still running.',
          ),
        ),
      );
      return;
    }

    final shell = _shell;
    if (shell == null) {
      return;
    }

    final host = _host;
    final reattachCommand = buildTmuxCommand(
      sessionName: sessionName,
      workingDirectory: host?.tmuxWorkingDirectory,
      extraFlags: host?.tmuxExtraFlags,
    );
    shell.write(utf8.encode(formatAutoConnectCommandForShell(reattachCommand)));
  }

  void _handleTrackedConnectionStateChange(
    Map<int, SshConnectionState>? previous,
    Map<int, SshConnectionState> next,
  ) {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }

    final previousState =
        previous?[connectionId] ?? SshConnectionState.disconnected;
    final nextState = next[connectionId] ?? SshConnectionState.disconnected;
    if (previousState == nextState ||
        nextState != SshConnectionState.disconnected) {
      return;
    }

    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = true;
      return;
    }
    if (!mounted) {
      return;
    }

    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    _terminalFocusNode.unfocus();
    setState(() {
      _isConnecting = false;
      _error ??= 'Connection closed';
    });
  }

  void _handleShellClosed() {
    final connectionId = _connectionId;
    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    if (!mounted) {
      if (connectionId != null) {
        unawaited(
          _sessionsNotifier?.handleUnexpectedDisconnect(
            connectionId,
            message: 'Connection closed',
          ),
        );
      }
      return;
    }
    // If the app is in the background, don't show the error screen
    // immediately — defer it so we can auto-reconnect on resume.
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = true;
    } else {
      setState(() {
        _isConnecting = false;
        _error = 'Connection closed';
      });
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    }
    // Clean up the session state regardless of background/foreground.
    if (connectionId != null) {
      unawaited(
        _sessionsNotifier?.handleUnexpectedDisconnect(
          connectionId,
          message: 'Connection closed',
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    final connectionId = _connectionId;
    _connectionId = null;
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    _shell = null;
    if (connectionId != null) {
      ref.read(tmuxServiceProvider).clearCache(connectionId);
      await _sessionsNotifier?.disconnect(connectionId);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _reconnect() async {
    if (_isConnecting) {
      return;
    }
    if (mounted) {
      setState(() {
        _isConnecting = true;
        _error = null;
      });
    } else {
      _isConnecting = true;
      _error = null;
    }

    final previousConnectionId = _connectionId;
    _connectionId = null;
    _connectionLostWhileBackgrounded = false;
    try {
      await _doneSubscription?.cancel();
      _doneSubscription = null;
      _shell = null;
      if (previousConnectionId != null) {
        await _sessionsNotifier?.disconnect(previousConnectionId);
      }
      if (!mounted) {
        return;
      }
      await _connect(forceNew: true);
    } finally {
      if (!mounted) {
        _isConnecting = false;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sharedClipboardSubscription.close();
    _stopSharedClipboardSync();
    _terminalInputIndicatorTimer?.cancel();
    _promptOutputImeResetTimer?.cancel();
    _disposeTerminalPathVerificationSftp();
    _observedSession?.removeMetadataListener(_handleSessionMetadataChanged);
    _terminal.removeListener(_onTerminalStateChanged);
    _terminalController
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _terminalScrollController
      ..removeListener(_handleTerminalScroll)
      ..dispose();
    _nativeSelectionScrollController
      ..removeListener(_syncTerminalScrollFromNative)
      ..dispose();
    _nativeSelectionController
      ..removeListener(_onNativeOverlayControllerChanged)
      ..dispose();
    _nativeOverlayCollapseTimer?.cancel();
    _clearNativeOverlayLongPressState();
    _nativeSelectionFocusNode.dispose();
    _doneSubscription?.cancel();
    _shellStdoutSubscription?.cancel();
    _terminalFocusNode.dispose();
    _toolbarController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _wasBackgrounded = true;
      _stopSharedClipboardSync();
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      final session = _observedSession;
      if (session != null && session.clipboardSharingEnabled) {
        unawaited(_startSharedClipboardSync(session));
      }
      if (_connectionLostWhileBackgrounded && mounted) {
        _connectionLostWhileBackgrounded = false;
        _terminal.write('\r\n[reconnecting...]\r\n');
        _reconnect();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload theme when system brightness changes
    if (_currentTheme == null) {
      return;
    }

    final session = _connectionId == null
        ? null
        : _sessionsNotifier?.getSession(_connectionId!);
    if (session != null) {
      unawaited(
        _restoreSessionThemeOverride(session).then((restored) {
          if (!restored) {
            return _loadTheme();
          }
        }),
      );
      return;
    }

    if (_sessionThemeOverride == null) {
      _loadTheme();
    }
  }

  List<Widget> _buildTerminalStatusChips(ThemeData theme) {
    final chipLabels = <({IconData icon, String label, String tooltip})>[
      if (_workingDirectoryLabel case final workingDirectory?
          when workingDirectory.isNotEmpty)
        (
          icon: Icons.folder_outlined,
          label: workingDirectory,
          tooltip: 'Current working directory reported by the shell session.',
        ),
      if (describeTerminalShellStatus(_shellStatus, lastExitCode: _lastExitCode)
          case final shellStatusLabel? when shellStatusLabel.isNotEmpty)
        (
          icon: Icons.play_circle_outline,
          label: shellStatusLabel,
          tooltip:
              'Shell integration status for the current prompt or command.',
        ),
      if (_isUsingAltBuffer)
        (
          icon: Icons.aspect_ratio,
          label: 'Alt buffer',
          tooltip:
              'A full-screen terminal app is using the alternate screen buffer.',
        ),
      if (_describeMouseMode(_terminal.mouseMode, _terminal.mouseReportMode)
          case final mouseModeLabel? when mouseModeLabel.isNotEmpty)
        (
          icon: Icons.mouse_outlined,
          label: mouseModeLabel,
          tooltip:
              'Terminal apps like tmux are actively receiving mouse input events.',
        ),
      if (_terminal.reportFocusMode)
        (
          icon: Icons.center_focus_strong,
          label: 'Focus reports',
          tooltip:
              'The terminal is reporting focus gained and lost events to the shell.',
        ),
      if (_terminal.bracketedPasteMode)
        (
          icon: Icons.content_paste,
          label: 'Bracketed paste',
          tooltip:
              'Paste operations are wrapped so terminal apps can handle them safely.',
        ),
    ];

    return chipLabels
        .map(
          (chip) => _TerminalStatusChip(
            icon: chip.icon,
            label: chip.label,
            tooltip: chip.tooltip,
            colorScheme: theme.colorScheme,
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<int, SshConnectionState>>(
      activeSessionsProvider,
      _handleTrackedConnectionStateChange,
    );
    final theme = Theme.of(context);
    final connectionStates = ref.watch(activeSessionsProvider);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final systemKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final connectionState = _connectionId == null
        ? SshConnectionState.disconnected
        : connectionStates[_connectionId!] ?? SshConnectionState.disconnected;
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;

    // Use session override, or loaded theme, or fallback
    final terminalTheme =
        _sessionThemeOverride ??
        _currentTheme ??
        (isDark ? TerminalThemes.midnightPurple : TerminalThemes.cleanWhite);
    final titleSubtitleSegments = <String>[];
    if ((_iconName ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_iconName!);
    }
    if ((_windowTitle ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_windowTitle!);
    }
    final titleSubtitle = titleSubtitleSegments.join(' • ');
    final statusChips = _buildTerminalStatusChips(theme);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_host?.label ?? 'Terminal'),
            if (titleSubtitle.isNotEmpty)
              Text(
                titleSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        bottom: !_showsTerminalMetadata || statusChips.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: Container(
                  alignment: Alignment.centerLeft,
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: statusChips
                          .map(
                            (chip) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: chip,
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                ),
              ),
        actions: [
          if (_isTmuxActive &&
              !_showTmuxBar &&
              connectionState == SshConnectionState.connected)
            IconButton(
              icon: const Icon(Icons.window_outlined),
              onPressed: _connectionId == null ? null : _openTmuxNavigator,
              tooltip: 'tmux windows',
            ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            onPressed:
                _connectionId == null ||
                    connectionState != SshConnectionState.connected
                ? null
                : _openConnectionFileBrowser,
            tooltip: 'Browse files',
          ),
          if (isMobile)
            IconButton(
              icon: Icon(
                systemKeyboardVisible
                    ? Icons.keyboard_hide
                    : Icons.keyboard_alt_outlined,
              ),
              onPressed: () => _toggleSystemKeyboard(systemKeyboardVisible),
              tooltip: systemKeyboardVisible
                  ? 'Hide system keyboard'
                  : 'Show system keyboard',
            ),
          IconButton(
            icon: _ExtraKeysToggleKeycap(
              key: ValueKey<String>(
                _showKeyboardToolbar
                    ? 'extra-keys-toggle-active'
                    : 'extra-keys-toggle-inactive',
              ),
              isActive: _showKeyboardToolbar,
            ),
            onPressed: () =>
                setState(() => _showKeyboardToolbar = !_showKeyboardToolbar),
            tooltip: _showKeyboardToolbar
                ? 'Hide extra keys'
                : 'Show extra keys',
          ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'snippets',
                child: Row(
                  children: [
                    Icon(Icons.code_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Snippets'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'change_theme',
                child: Row(
                  children: [
                    Icon(Icons.palette_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Change Theme'),
                  ],
                ),
              ),
              if (statusChips.isNotEmpty)
                PopupMenuItem(
                  value: 'toggle_terminal_info',
                  child: Row(
                    children: [
                      Icon(
                        _showsTerminalMetadata
                            ? Icons.info_outlined
                            : Icons.info_outline_rounded,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _showsTerminalMetadata
                            ? 'Hide Terminal Info'
                            : 'Show Terminal Info',
                      ),
                    ],
                  ),
                ),
              if (_isTmuxActive)
                PopupMenuItem(
                  value: 'toggle_tmux_bar',
                  child: Row(
                    children: [
                      Icon(
                        _showTmuxBar
                            ? Icons.window_outlined
                            : Icons.window_rounded,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(_showTmuxBar ? 'Hide tmux Bar' : 'Show tmux Bar'),
                    ],
                  ),
                ),
              if (isMobile)
                CheckedPopupMenuItem(
                  value: 'toggle_tap_keyboard',
                  checked: ref.read(tapToShowKeyboardNotifierProvider),
                  child: const Text('Tap to Show Keyboard'),
                ),
              const PopupMenuDivider(),
              if (!isMobile)
                PopupMenuItem(
                  value: 'native_select',
                  child: Row(
                    children: [
                      Icon(
                        _isNativeSelectionMode
                            ? Icons.deselect_rounded
                            : Icons.select_all_rounded,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _isNativeSelectionMode
                            ? 'Exit Native Selection'
                            : 'Native Selection',
                      ),
                    ],
                  ),
                ),
              if (_workingDirectoryPath != null)
                const PopupMenuItem(
                  value: 'copy_working_directory',
                  child: Row(
                    children: [
                      Icon(Icons.folder_copy_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Copy Current Directory'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'copy',
                child: Row(
                  children: [
                    Icon(Icons.copy_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Copy'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'paste',
                child: Row(
                  children: [
                    Icon(Icons.paste_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Paste'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'paste_image',
                child: Row(
                  children: [
                    Icon(Icons.image_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Paste Images'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'paste_file',
                child: Row(
                  children: [
                    Icon(Icons.attach_file_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Paste Files'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'disconnect',
                child: Row(
                  children: [
                    Icon(Icons.link_off_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Disconnect'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (bodyContext) {
          final showsKeyboardToolbar =
              _showKeyboardToolbar &&
              !showsDisconnectedOverlay &&
              (!_isNativeSelectionMode || _isMobilePlatform);
          final terminalArea = _buildTerminalWithTmuxBar(
            terminalTheme,
            isMobile,
            theme,
            connectionState,
          );
          return Column(
            children: [
              Expanded(
                // The KeyboardToolbar below already absorbs the bottom
                // safe-area inset via its own SafeArea, so strip it here to
                // prevent the tmux bar from floating above the toolbar.
                child: showsKeyboardToolbar
                    ? MediaQuery.removePadding(
                        context: bodyContext,
                        removeBottom: true,
                        child: terminalArea,
                      )
                    : terminalArea,
              ),
              if (showsKeyboardToolbar)
                KeyboardToolbar(
                  controller: _toolbarController,
                  terminal: _terminal,
                  onKeyPressed: _handleKeyboardToolbarKeyPressed,
                  terminalFocusNode: _terminalFocusNode,
                ),
            ],
          );
        },
      ),
    );
  }

  /// Toggles the system keyboard visibility on mobile platforms.
  void _toggleSystemKeyboard(bool isVisible) {
    if (isVisible) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    } else {
      // Explicit user action — always show the keyboard regardless of the
      // tap-to-show setting.
      _restoreTerminalFocus(forceShowSystemKeyboard: true);
    }
  }

  /// Restores focus to the terminal after a UI interaction.
  ///
  /// When [showSystemKeyboard] is `true` the soft keyboard is shown only if
  /// the tap-to-show-keyboard setting permits it.  Use
  /// [forceShowSystemKeyboard] to bypass the setting (e.g. the explicit
  /// toolbar keyboard toggle).
  void _restoreTerminalFocus({
    bool showSystemKeyboard = false,
    bool forceShowSystemKeyboard = false,
  }) {
    if (!mounted) {
      return;
    }
    _dismissNativeSelectionOverlayForEditing();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _terminalFocusNode.requestFocus();
      final shouldShowKeyboard =
          forceShowSystemKeyboard ||
          (showSystemKeyboard && ref.read(tapToShowKeyboardNotifierProvider));
      if (shouldShowKeyboard && _isMobilePlatform) {
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
        );
      }
    });
  }

  void _handleKeyboardToolbarKeyPressed() {
    _followLiveOutput();
    _terminalTextInputController.clearImeBuffer();
  }

  void _handleTerminalScaleStart(double currentFontSize) {
    _pinchFontSize = currentFontSize;
    _lastPinchScale = 1;
    _isPinchZooming = false;
  }

  void _handleTerminalScaleUpdate(double scale, double currentFontSize) {
    final displayedFontSize = _pinchFontSize ?? currentFontSize;
    final previousScale = _lastPinchScale ?? 1;
    final nextFontSize = applyTerminalScaleDelta(
      displayedFontSize,
      previousScale,
      scale,
    );
    if (_isPinchZooming && _pinchFontSize == nextFontSize) {
      return;
    }

    setState(() {
      _isPinchZooming = true;
      _pinchFontSize = nextFontSize;
      _lastPinchScale = scale;
    });
  }

  void _handleTerminalScaleEnd() {
    final nextFontSize = _pinchFontSize;
    final connectionId = _connectionId;
    final shouldPersist =
        _isPinchZooming && nextFontSize != null && connectionId != null;
    setState(() {
      if (shouldPersist) {
        _sessionFontSizeOverride = nextFontSize;
      }
      _isPinchZooming = false;
      _lastPinchScale = null;
      _pinchFontSize = null;
    });

    if (!shouldPersist) {
      return;
    }

    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionFontSize(connectionId, nextFontSize);
  }

  Widget _buildTerminalTransientIndicator({
    required ThemeData theme,
    required String label,
  }) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );

  Future<void> _showThemePicker() async {
    final currentId = _sessionThemeOverride?.id ?? _currentTheme?.id;
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );

    if (theme != null && mounted) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final monetizationState =
          ref.read(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final hasHostThemeAccess = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );
      if (_connectionId != null) {
        ref
            .read(activeSessionsProvider.notifier)
            .updateSessionTheme(_connectionId!, theme.id, isDark: isDark);
      }
      setState(() => _sessionThemeOverride = theme);

      // Show option to save to host
      if (_host != null) {
        final scaffoldMessenger = ScaffoldMessenger.of(context);

        // Clear any existing snackbar first to prevent stacking
        scaffoldMessenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Expanded(child: Text('Theme: ${theme.name}')),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      scaffoldMessenger.hideCurrentSnackBar();
                      _saveThemeToHost(theme, isDark: isDark);
                    },
                    child: Text(
                      hasHostThemeAccess
                          ? 'Save to Host'
                          : 'Save to Host (Pro)',
                    ),
                  ),
                ],
              ),
              duration: const Duration(seconds: 6),
            ),
          );
      }
    }
  }

  Future<void> _saveThemeToHost(
    TerminalThemeData theme, {
    required bool isDark,
  }) async {
    if (_host == null) return;
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.hostSpecificThemes,
    );
    if (!hasAccess || !mounted) {
      return;
    }

    final hostRepo = ref.read(hostRepositoryProvider);
    final updatedHost = isDark
        ? _host!.copyWith(terminalThemeDarkId: drift.Value(theme.id))
        : _host!.copyWith(terminalThemeLightId: drift.Value(theme.id));

    await hostRepo.update(updatedHost);
    _host = updatedHost;

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Theme saved to ${_host!.label}')));
    }
  }

  Widget _buildConnectionIssueOverlay({
    required ThemeData theme,
    required Widget child,
    required String message,
    required bool showsDisconnectedOverlay,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      AbsorbPointer(child: child),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      showsDisconnectedOverlay
                          ? 'Disconnected'
                          : 'Connection Error',
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _isConnecting ? null : _reconnect,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reconnect'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildTerminalView(TerminalThemeData terminalTheme, bool isMobile) {
    final theme = Theme.of(context);
    final connectionStates = ref.watch(activeSessionsProvider);
    final connectionAttempt = ref
        .read(activeSessionsProvider.notifier)
        .getConnectionAttempt(widget.hostId);
    final connectionState = _connectionId == null
        ? SshConnectionState.disconnected
        : connectionStates[_connectionId!] ?? SshConnectionState.disconnected;
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;
    final overlayMessage = showsDisconnectedOverlay
        ? connectionAttempt?.latestMessage ?? _error ?? 'Connection closed'
        : _error;

    if (_isConnecting) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Connecting...'),
          ],
        ),
      );
    }

    if (overlayMessage != null && _connectionId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Connection Error',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                overlayMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isConnecting ? null : _reconnect,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Use a session override when pinch-zoom has customized this connection.
    final globalFontSize = ref.watch(fontSizeNotifierProvider);
    final storedFontSize = _sessionFontSizeOverride ?? globalFontSize;
    final fontSize = resolveTerminalFontSize(
      globalFontSize: globalFontSize,
      sessionFontSize: _sessionFontSizeOverride,
      pinchFontSize: _pinchFontSize,
    );

    // Get font family from host (if set) or global settings
    final hostFont = _host?.terminalFontFamily;
    final globalFont = ref.watch(fontFamilyNotifierProvider);
    final fontFamily = hostFont ?? globalFont;
    final terminalTextStyle = _getTerminalTextStyle(fontFamily, fontSize);
    final nativeSelectionTextStyle = _getNativeSelectionTextStyle(
      terminalTextStyle,
    );
    final routeTouchScrollToTerminal = _routesTouchScrollToTerminal;
    final terminalPathLinksEnabled = ref.watch(
      terminalPathLinksNotifierProvider,
    );
    final terminalPathLinkUnderlinesEnabled = ref.watch(
      terminalPathLinkUnderlinesNotifierProvider,
    );
    final tapToShowKeyboard = ref.watch(tapToShowKeyboardNotifierProvider);

    Widget terminalView = MonkeyTerminalView(
      key: _terminalViewKey,
      _terminal,
      controller: _terminalController,
      scrollController: _terminalScrollController,
      resolveLinkTap: _resolveTerminalLinkTap,
      onTapDown: isMobile ? _handleTerminalTapDown : null,
      onTapUp: isMobile ? _handleTerminalTapUp : null,
      onLinkTapDown: _handleTerminalLinkTapDown,
      onLinkTap: _handleTerminalLinkTap,
      onDoubleTapDown: isMobile ? _handleTerminalDoubleTapDown : null,
      onLongPressStart: isMobile ? _handleTerminalLongPressStart : null,
      suppressLongPressDragSelection: isMobile,
      focusNode: isMobile ? null : _terminalFocusNode,
      theme: terminalTheme.toXtermTheme(),
      textStyle: terminalTextStyle,
      padding: terminalViewportPadding,
      deleteDetection: !isMobile,
      autofocus: !isMobile,
      hardwareKeyboardOnly: isMobile,
      // Let alt-buffer apps keep raw wheel events when they explicitly enable
      // mouse reporting, but fall back to synthetic arrows when they do not.
      simulateScroll: shouldUseSyntheticAltBufferScrollFallback(
        isUsingAltBuffer: _isUsingAltBuffer,
        preferExplicitMouseReporting: true,
        terminalReportsMouseWheel: _terminalReportsMouseWheel,
      ),
      touchScrollToTerminal: routeTouchScrollToTerminal,
      onInsertText: isMobile ? null : _confirmDesktopInsertedText,
      onPasteText: isMobile ? null : _pasteClipboard,
    );

    final showsTerminalPathUnderlines =
        terminalPathLinksEnabled && terminalPathLinkUnderlinesEnabled;
    if (_lastShowsTerminalPathUnderlines != showsTerminalPathUnderlines) {
      _lastShowsTerminalPathUnderlines = showsTerminalPathUnderlines;
      _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild =
          showsTerminalPathUnderlines;
    }
    if (!showsTerminalPathUnderlines && _hoveredTerminalPathUnderline != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hoveredTerminalPathUnderline == null) {
          return;
        }
        setState(() => _hoveredTerminalPathUnderline = null);
      });
    }
    if (!showsTerminalPathUnderlines &&
        _isMobilePlatform &&
        _visibleTerminalPathUnderlines.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _visibleTerminalPathUnderlines.isEmpty) {
          return;
        }
        setState(
          () => _visibleTerminalPathUnderlines =
              const <({String path, Rect underlineRect, Rect touchRect})>[],
        );
      });
    }
    if (terminalPathLinksEnabled) {
      terminalView = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleTerminalPathPointerDown,
        child: terminalView,
      );
    }
    if (showsTerminalPathUnderlines) {
      if (_isMobilePlatform) {
        if (_shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild) {
          _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = false;
          _queueVisibleTerminalPathUnderlineRefresh();
        }
        terminalView = Stack(
          fit: StackFit.expand,
          children: [
            terminalView,
            for (final entry in _visibleTerminalPathUnderlines.asMap().entries)
              Positioned(
                left: entry.value.underlineRect.left,
                top: entry.value.underlineRect.top,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: terminalTheme.foreground.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: SizedBox(
                      key: ValueKey<String>(
                        'terminal-path-underline:${entry.key}:${entry.value.path}',
                      ),
                      width: entry.value.underlineRect.width,
                      height: entry.value.underlineRect.height,
                    ),
                  ),
                ),
              ),
          ],
        );
      } else {
        terminalView = MouseRegion(
          onHover: _handleTerminalPathHover,
          onExit: (_) => _clearHoveredTerminalPathUnderline(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              terminalView,
              if (_hoveredTerminalPathUnderline != null)
                Positioned(
                  left: _hoveredTerminalPathUnderline!.left,
                  top: _hoveredTerminalPathUnderline!.top,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: terminalTheme.foreground.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: SizedBox(
                        width: _hoveredTerminalPathUnderline!.width,
                        height: _hoveredTerminalPathUnderline!.height,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }
    }

    if (!isMobile) {
      return overlayMessage == null
          ? terminalView
          : _buildConnectionIssueOverlay(
              theme: theme,
              child: terminalView,
              message: overlayMessage,
              showsDisconnectedOverlay: showsDisconnectedOverlay,
            );
    }

    var mobileTerminalView = terminalView;

    // On mobile, wrap with our own text input handler that enables
    // IME suggestions so swipe typing correctly inserts spaces.
    if (_showsNativeSelectionOverlay) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          _nativeSelectionOverlay(nativeSelectionTextStyle, terminalTheme),
        ],
      );
    } else if (_hasTerminalSelection) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          Positioned(
            left: 12,
            right: 12,
            bottom: selectionActionsBottomOffset(MediaQuery.of(context)),
            child: _selectionActions,
          ),
        ],
      );
    }

    final terminalInputIndicatorLabel = _terminalInputIndicatorLabel;
    if (_isPinchZooming || terminalInputIndicatorLabel != null) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          if (terminalInputIndicatorLabel != null)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: _buildTerminalTransientIndicator(
                  theme: theme,
                  label: terminalInputIndicatorLabel,
                ),
              ),
            ),
          if (_isPinchZooming)
            Positioned(
              top: 12,
              right: 12,
              child: _buildTerminalTransientIndicator(
                theme: theme,
                label: '${fontSize.toStringAsFixed(0)} pt',
              ),
            ),
        ],
      );
    }

    Widget terminalViewWithInput = TerminalTextInputHandler(
      terminal: _terminal,
      focusNode: _terminalFocusNode,
      controller: _terminalTextInputController,
      deleteDetection: true,
      onUserInput: _followLiveOutput,
      onReviewInsertedText: _confirmKeyboardInsertion,
      buildReviewTextForInsertedText: _terminalCommandAfterInputDelta,
      resolveTextBeforeCursor: _terminalTextBeforeCursor,
      resolveTerminalKeyModifiers: () => (
        ctrl: _toolbarController.isCtrlActive,
        alt: _toolbarController.isAltActive,
        shift: _toolbarController.isShiftActive,
      ),
      consumeTerminalKeyModifiers: _toolbarController.consumeOneShot,
      hasActiveToolbarModifier: () =>
          _toolbarController.isCtrlActive || _toolbarController.isAltActive,
      readOnly: _showsNativeSelectionOverlay || overlayMessage != null,
      tapToShowKeyboard: tapToShowKeyboard,
      child: TerminalPinchZoomGestureHandler(
        onPinchStart: () => _handleTerminalScaleStart(storedFontSize),
        onPinchUpdate: (scale) =>
            _handleTerminalScaleUpdate(scale, storedFontSize),
        onPinchEnd: _handleTerminalScaleEnd,
        child: mobileTerminalView,
      ),
    );

    if (overlayMessage != null) {
      terminalViewWithInput = _buildConnectionIssueOverlay(
        theme: theme,
        child: terminalViewWithInput,
        message: overlayMessage,
        showsDisconnectedOverlay: showsDisconnectedOverlay,
      );
    }

    return terminalViewWithInput;
  }

  Widget _nativeSelectionOverlay(
    TextStyle textStyle,
    TerminalThemeData terminalTheme,
  ) => Positioned.fill(
    child: Padding(
      padding: terminalViewportPadding,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _nativeSelectionController,
        child: TextSelectionTheme(
          data: TextSelectionTheme.of(context).copyWith(
            selectionColor: terminalTheme.selection,
            selectionHandleColor: terminalTheme.cursor,
          ),
          child: Listener(
            onPointerDown: _handleNativeOverlayPointerDown,
            onPointerMove: _handleNativeOverlayPointerMove,
            onPointerUp: _handleNativeOverlayPointerUp,
            onPointerCancel: _handleNativeOverlayPointerCancel,
            child: TextField(
              controller: _nativeSelectionController,
              focusNode: _nativeSelectionFocusNode,
              readOnly: true,
              showCursor: false,
              cursorColor: Colors.transparent,
              enableInteractiveSelection: true,
              scrollController: _nativeSelectionScrollController,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: textStyle,
              strutStyle: StrutStyle.fromTextStyle(
                textStyle,
                forceStrutHeight: true,
              ),
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                filled: false,
                fillColor: Colors.transparent,
                hoverColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        builder: (context, value, child) => IgnorePointer(
          ignoring: !hasActiveNativeOverlaySelection(value.selection),
          child: child,
        ),
      ),
    ),
  );

  /// Resolves the terminal text style for the given font family and size.
  TerminalStyle _getTerminalTextStyle(String fontFamily, double fontSize) {
    final textStyle = resolveMonospaceTextStyle(
      fontFamily,
      platform: Theme.of(context).platform,
      fontSize: fontSize,
    );
    return TerminalStyle.fromTextStyle(textStyle);
  }

  TextStyle _getNativeSelectionTextStyle(TerminalStyle terminalTextStyle) =>
      terminalTextStyle
          .toTextStyle(color: Colors.transparent)
          .copyWith(
            letterSpacing: 0,
            fontFeatures: const [
              FontFeature.disable('liga'),
              FontFeature.disable('calt'),
            ],
          );

  Size? _measureTerminalPathUnderlineTextSize(String text) {
    if (text.isEmpty) {
      return null;
    }
    final globalFontSize = ref.read(fontSizeNotifierProvider);
    final fontSize = resolveTerminalFontSize(
      globalFontSize: globalFontSize,
      sessionFontSize: _sessionFontSizeOverride,
      pinchFontSize: _pinchFontSize,
    );
    final fontFamily =
        _host?.terminalFontFamily ??
        ref.read(fontFamilyNotifierProvider) ??
        'monospace';
    final textStyle = resolveMonospaceTextStyle(
      fontFamily,
      platform: Theme.of(context).platform,
      fontSize: fontSize,
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    if (painter.width <= 0 || painter.height <= 0) {
      return null;
    }
    return Size(painter.width, painter.height);
  }

  void _openConnectionFileBrowser() {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }

    // Pass the terminal's working directory (from OSC 7) as both the
    // initial path and the working directory for relative path resolution.
    final cwd = _workingDirectoryPath;
    context.pushNamed(
      Routes.sftp,
      pathParameters: {'hostId': widget.hostId.toString()},
      queryParameters: {
        'connectionId': connectionId.toString(),
        if (cwd != null) ...{'path': cwd, 'cwd': cwd},
      },
    );
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'snippets':
        await _showSnippetPicker();
        break;
      case 'change_theme':
        unawaited(_showThemePicker());
        break;
      case 'toggle_terminal_info':
        setState(() => _showsTerminalMetadata = !_showsTerminalMetadata);
        break;
      case 'toggle_tmux_bar':
        setState(() => _showTmuxBar = !_showTmuxBar);
        break;
      case 'toggle_tap_keyboard':
        final notifier = ref.read(tapToShowKeyboardNotifierProvider.notifier);
        await notifier.setEnabled(
          enabled: !ref.read(tapToShowKeyboardNotifierProvider),
        );
        break;
      case 'native_select':
        _toggleNativeSelectionMode();
        break;
      case 'copy_working_directory':
        await _copyWorkingDirectory();
        break;
      case 'copy':
        await _copySelection();
        break;
      case 'paste':
        await _pasteClipboard();
        break;
      case 'paste_image':
        await _pastePickedImage();
        break;
      case 'paste_file':
        await _pastePickedFiles();
        break;
      case 'disconnect':
        await _disconnect();
        break;
    }
  }

  void _toggleNativeSelectionMode() {
    if (_isMobilePlatform) {
      return;
    }
    if (_isNativeSelectionMode) {
      _exitNativeSelectionMode();
      return;
    }

    _enterNativeSelectionMode(initialRange: _terminalController.selection);
  }

  void _enterNativeSelectionMode({
    BufferRange? initialRange,
    bool revealOverlayInTouchScrollMode = false,
  }) {
    if (_isNativeSelectionMode && initialRange == null) {
      return;
    }

    _terminalFocusNode.unfocus();
    final snapshot = _buildNativeSelectionSnapshotData();
    final selection = initialRange == null
        ? const TextSelection.collapsed(offset: 0)
        : _bufferRangeToTextSelection(
            initialRange,
            viewWidth: _terminal.buffer.viewWidth,
            lineCount: _terminal.buffer.height,
            lineStarts: snapshot.lineStarts,
            columnOffsets: snapshot.columnOffsets,
            textLength: snapshot.textLength,
          );
    _enterNativeSelectionModeWithSnapshot((
      originCellOffset:
          initialRange?.normalized.begin ?? const CellOffset(0, 0),
      text: snapshot.text,
      selection: selection,
      lineStarts: snapshot.lineStarts,
      columnOffsets: snapshot.columnOffsets,
      lineCount: snapshot.lineCount,
      viewWidth: snapshot.viewWidth,
      textLength: snapshot.textLength,
      revealOverlayInTouchScrollMode: revealOverlayInTouchScrollMode,
    ));
  }

  void _enterNativeSelectionModeWithSnapshot(
    _PendingTouchSelectionSnapshot snapshot,
  ) {
    _nativeSelectionController.value = TextEditingValue(
      text: snapshot.text,
      selection: snapshot.selection,
    );
    _nativeSelectionSnapshotMetrics = (
      lineStarts: snapshot.lineStarts,
      columnOffsets: snapshot.columnOffsets,
      lineCount: snapshot.lineCount,
      viewWidth: snapshot.viewWidth,
      textLength: snapshot.textLength,
    );
    _hadNativeOverlaySelection = hasActiveNativeOverlaySelection(
      snapshot.selection,
    );
    _nativeOverlayCollapseTimer?.cancel();
    _clearNativeOverlayLongPressState();
    setState(() {
      _isNativeSelectionMode = true;
      _hasTerminalSelection = false;
      _revealsNativeSelectionOverlayInTouchScrollMode =
          _revealsNativeSelectionOverlayInTouchScrollMode ||
          snapshot.revealOverlayInTouchScrollMode;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isNativeSelectionMode) {
        return;
      }
      _syncNativeScrollFromTerminal(force: true);
      _nativeSelectionFocusNode.requestFocus();
      if (!_nativeSelectionController.selection.isCollapsed) {
        _nativeSelectionController.selection = snapshot.selection;
      }
    });
    if (_terminalController.selection != null) {
      _terminalController.clearSelection();
    }
  }

  void _exitNativeSelectionMode() {
    if (_isMobilePlatform) {
      return;
    }
    _nativeSelectionFocusNode.unfocus();
    setState(() {
      _isNativeSelectionMode = false;
      _hasTerminalSelection = false;
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    _hadNativeOverlaySelection = false;
    _clearPendingTouchSelectionRange();
    _nativeSelectionSnapshotMetrics = null;
    _nativeOverlayCollapseTimer?.cancel();
    _clearNativeOverlayLongPressState();
    _terminalFocusNode.requestFocus();
  }

  void _refreshNativeOverlayText({required bool preserveSelection}) {
    if (!_isNativeSelectionMode) {
      return;
    }
    final snapshot = _buildNativeSelectionSnapshotData();
    final previousSelection = _nativeSelectionController.selection;
    final maxOffset = snapshot.textLength;
    final nextSelection = preserveSelection
        ? TextSelection(
            baseOffset: previousSelection.baseOffset.clamp(0, maxOffset),
            extentOffset: previousSelection.extentOffset.clamp(0, maxOffset),
          )
        : const TextSelection.collapsed(offset: 0);
    _nativeSelectionController.value = TextEditingValue(
      text: snapshot.text,
      selection: nextSelection,
    );
    _nativeSelectionSnapshotMetrics = (
      lineStarts: snapshot.lineStarts,
      columnOffsets: snapshot.columnOffsets,
      lineCount: snapshot.lineCount,
      viewWidth: snapshot.viewWidth,
      textLength: snapshot.textLength,
    );
  }

  _NativeSelectionSnapshotData _buildNativeSelectionSnapshotData() {
    final cachedSnapshot = _nativeSelectionSnapshotCache;
    if (cachedSnapshot != null) {
      return cachedSnapshot;
    }

    final buffer = _terminal.buffer;
    final builder = StringBuffer();
    final lineStarts = <int>[];
    final lineColumnOffsets = <List<int>>[];

    for (var i = 0; i < buffer.height; i++) {
      lineStarts.add(builder.length);
      final lineSnapshot = _buildNativeSelectionLineSnapshot(
        buffer.lines[i],
        buffer.viewWidth,
      );
      builder.write(lineSnapshot.text);
      lineColumnOffsets.add(lineSnapshot.columnOffsets);
      if (i < buffer.height - 1) {
        builder.write('\n');
      }
    }

    final snapshot = (
      text: builder.toString(),
      lineStarts: lineStarts,
      columnOffsets: lineColumnOffsets,
      lineCount: buffer.height,
      viewWidth: buffer.viewWidth,
      textLength: builder.length,
    );
    _nativeSelectionSnapshotCache = snapshot;
    return snapshot;
  }

  ({String text, List<int> columnOffsets}) _buildTerminalLineSnapshot(
    BufferLine line,
    int viewWidth, {
    required bool preserveTrailingPadding,
    int preserveOffset = 0,
  }) {
    final builder = StringBuffer();
    final columnOffsets = List<int>.filled(viewWidth + 1, 0);
    var col = 0;

    while (col < viewWidth) {
      final startOffset = builder.length;
      columnOffsets[col] = startOffset;
      final codePoint = line.getCodePoint(col);
      final width = line.getWidth(col);

      if (codePoint == 0) {
        builder.writeCharCode(0x20);
        columnOffsets[col + 1] = builder.length;
        col++;
        continue;
      }

      builder.writeCharCode(codePoint);
      final step = (width <= 0 ? 1 : width).clamp(1, viewWidth - col);
      for (var i = col + 1; i < col + step; i++) {
        columnOffsets[i] = startOffset;
      }
      columnOffsets[col + step] = builder.length;
      col += step;
    }

    final rawText = builder.toString();
    final resolvedLength = resolveTerminalLineSnapshotTextLength(
      text: rawText,
      preserveOffset: preserveOffset,
      preserveTrailingPadding: preserveTrailingPadding,
    );
    if (resolvedLength == rawText.length) {
      return (text: rawText, columnOffsets: columnOffsets);
    }

    for (var i = 0; i < columnOffsets.length; i++) {
      if (columnOffsets[i] > resolvedLength) {
        columnOffsets[i] = resolvedLength;
      }
    }
    return (
      text: rawText.substring(0, resolvedLength),
      columnOffsets: columnOffsets,
    );
  }

  ({String text, List<int> columnOffsets}) _buildNativeSelectionLineSnapshot(
    BufferLine line,
    int viewWidth,
  ) => _buildTerminalLineSnapshot(
    line,
    viewWidth,
    preserveTrailingPadding: false,
  );

  TextSelection _bufferRangeToTextSelection(
    BufferRange range, {
    required int viewWidth,
    required int lineCount,
    required List<int> lineStarts,
    required List<List<int>> columnOffsets,
    required int textLength,
  }) {
    final normalized = range.normalized;

    int toOffset(CellOffset position) {
      final y = position.y.clamp(0, lineCount - 1);
      final x = position.x.clamp(0, viewWidth);
      final lineStart = lineStarts[y];
      final lineOffset = columnOffsets[y][x];
      return (lineStart + lineOffset).clamp(0, textLength);
    }

    final start = toOffset(normalized.begin);
    final end = toOffset(normalized.end);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  _PendingTouchSelectionSnapshot? _buildPendingTouchSelectionSnapshot(
    CellOffset cellOffset, {
    required bool revealOverlayInTouchScrollMode,
  }) {
    final wordRange = _terminal.buffer.getWordBoundary(cellOffset);
    if (wordRange == null) {
      return null;
    }

    final snapshot = _buildNativeSelectionSnapshotData();
    final selection = _bufferRangeToTextSelection(
      wordRange,
      viewWidth: snapshot.viewWidth,
      lineCount: snapshot.lineCount,
      lineStarts: snapshot.lineStarts,
      columnOffsets: snapshot.columnOffsets,
      textLength: snapshot.textLength,
    );
    return (
      originCellOffset: cellOffset,
      text: snapshot.text,
      selection: selection,
      lineStarts: snapshot.lineStarts,
      columnOffsets: snapshot.columnOffsets,
      lineCount: snapshot.lineCount,
      viewWidth: snapshot.viewWidth,
      textLength: snapshot.textLength,
      revealOverlayInTouchScrollMode: revealOverlayInTouchScrollMode,
    );
  }

  bool _selectNativeOverlayWordAtCellOffset(
    CellOffset cellOffset, {
    bool revealOverlayInTouchScrollMode = false,
  }) {
    final snapshot = _buildPendingTouchSelectionSnapshot(
      cellOffset,
      revealOverlayInTouchScrollMode: revealOverlayInTouchScrollMode,
    );
    if (snapshot == null) {
      return false;
    }

    _enterNativeSelectionModeWithSnapshot(snapshot);
    return true;
  }

  void _clearPendingTouchSelectionRange() {
    _pendingTouchSelectionRange = null;
  }

  CellOffset? _terminalCellOffsetForGlobalPosition(Offset globalPosition) {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null) {
      return null;
    }

    final renderTerminal = terminalViewState.renderTerminal;
    final localPosition = renderTerminal.globalToLocal(globalPosition);
    if (localPosition.dx < 0 ||
        localPosition.dy < 0 ||
        localPosition.dx > renderTerminal.size.width ||
        localPosition.dy > renderTerminal.size.height) {
      return null;
    }

    return renderTerminal.getCellOffset(localPosition);
  }

  bool _isNativeOverlayTouchPointer(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  ({CellOffset? cellOffset, bool pointsOutsideSnapshot})
  _nativeSelectionSnapshotHitForGlobalPosition(Offset globalPosition) {
    final metrics = _nativeSelectionSnapshotMetrics;
    final cellOffset = _terminalCellOffsetForGlobalPosition(globalPosition);
    if (metrics == null || cellOffset == null) {
      return (cellOffset: cellOffset, pointsOutsideSnapshot: false);
    }

    if (cellOffset.y >= metrics.lineCount ||
        cellOffset.x >= metrics.viewWidth) {
      return (cellOffset: cellOffset, pointsOutsideSnapshot: true);
    }

    return (cellOffset: cellOffset, pointsOutsideSnapshot: false);
  }

  bool _isNativeSelectionCellWithinActiveSelection(CellOffset cellOffset) {
    final metrics = _nativeSelectionSnapshotMetrics;
    final selection = _nativeSelectionController.selection;
    if (metrics == null || !hasActiveNativeOverlaySelection(selection)) {
      return false;
    }

    final lineStart = metrics.lineStarts[cellOffset.y];
    final cellStart =
        lineStart + metrics.columnOffsets[cellOffset.y][cellOffset.x];
    final cellEnd =
        lineStart + metrics.columnOffsets[cellOffset.y][cellOffset.x + 1];
    if (cellEnd <= cellStart) {
      return false;
    }

    final selectionStart = min(selection.baseOffset, selection.extentOffset);
    final selectionEnd = max(selection.baseOffset, selection.extentOffset);
    final protectedStart = max(0, selectionStart - 1);
    final protectedEnd = min(metrics.textLength, selectionEnd + 1);
    return cellStart < protectedEnd && cellEnd > protectedStart;
  }

  _PendingTouchSelectionSnapshot? _buildPendingNativeOverlayLongPressSelection(
    Offset globalPosition,
  ) {
    final selection = _nativeSelectionController.selection;
    if (!hasActiveNativeOverlaySelection(selection)) {
      return null;
    }

    final hit = _nativeSelectionSnapshotHitForGlobalPosition(globalPosition);
    final cellOffset = hit.cellOffset;
    if (cellOffset == null) {
      return null;
    }
    if (!hit.pointsOutsideSnapshot &&
        _isNativeSelectionCellWithinActiveSelection(cellOffset)) {
      return null;
    }
    return _buildPendingTouchSelectionSnapshot(
      cellOffset,
      revealOverlayInTouchScrollMode: _routesTouchScrollToTerminal,
    );
  }

  void _clearNativeOverlayLongPressState() {
    _nativeOverlayLongPressTimer?.cancel();
    _nativeOverlayLongPressTimer = null;
    _nativeOverlayPointerId = null;
    _nativeOverlayPointerDownPosition = null;
    _pendingNativeOverlayLongPressSelection = null;
  }

  void _handleNativeOverlayPointerDown(PointerDownEvent event) {
    if (!_isMobilePlatform ||
        !_showsNativeSelectionOverlay ||
        !_isNativeOverlayTouchPointer(event.kind) ||
        !hasActiveNativeOverlaySelection(
          _nativeSelectionController.selection,
        )) {
      return;
    }
    _clearNativeOverlayLongPressState();
    final pendingSnapshot = _buildPendingNativeOverlayLongPressSelection(
      event.position,
    );
    if (pendingSnapshot == null) {
      return;
    }
    _pendingNativeOverlayLongPressSelection = pendingSnapshot;
    _nativeOverlayPointerId = event.pointer;
    _nativeOverlayPointerDownPosition = event.position;
    _nativeOverlayLongPressTimer = Timer(kLongPressTimeout, () {
      final longPressSnapshot = _pendingNativeOverlayLongPressSelection;
      _clearNativeOverlayLongPressState();
      if (longPressSnapshot == null) {
        return;
      }
      _enterNativeSelectionModeWithSnapshot(longPressSnapshot);
    });
  }

  void _handleNativeOverlayPointerMove(PointerMoveEvent event) {
    if (event.pointer != _nativeOverlayPointerId) {
      return;
    }
    final downPosition = _nativeOverlayPointerDownPosition;
    if (downPosition == null) {
      return;
    }
    if ((event.position - downPosition).distance > kTouchSlop) {
      _clearNativeOverlayLongPressState();
    }
  }

  void _handleNativeOverlayPointerUp(PointerUpEvent event) {
    if (event.pointer == _nativeOverlayPointerId) {
      _clearNativeOverlayLongPressState();
    }
  }

  void _handleNativeOverlayPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _nativeOverlayPointerId) {
      _clearNativeOverlayLongPressState();
    }
  }

  void _onNativeOverlayControllerChanged() {
    if (!mounted || !_isNativeSelectionMode) {
      return;
    }
    final selection = _nativeSelectionController.selection;
    if (!selection.isValid) {
      return;
    }
    if (hasActiveNativeOverlaySelection(selection)) {
      _hadNativeOverlaySelection = true;
      _nativeOverlayCollapseTimer?.cancel();
      return;
    }
    if (!_hadNativeOverlaySelection) {
      return;
    }
    _nativeOverlayCollapseTimer?.cancel();
    _nativeOverlayCollapseTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || !_isNativeSelectionMode) {
        return;
      }
      if (!_nativeSelectionController.selection.isCollapsed) {
        return;
      }
      _hadNativeOverlaySelection = false;
      _handleNativeOverlaySelectionChanged(
        _nativeSelectionController.selection,
        null,
      );
    });
  }

  void _handleNativeOverlaySelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    if (!mounted) {
      return;
    }

    switch (resolveNativeSelectionOverlayChange(
      isMobilePlatform: _isMobilePlatform,
      isNativeSelectionMode: _isNativeSelectionMode,
      revealOverlayInTouchScrollMode:
          _revealsNativeSelectionOverlayInTouchScrollMode,
      selection: selection,
    )) {
      case NativeSelectionOverlayChange.none:
        return;
      case NativeSelectionOverlayChange.hideTemporaryOverlay:
        setState(() {
          _revealsNativeSelectionOverlayInTouchScrollMode = false;
        });
        return;
      case NativeSelectionOverlayChange.exitSelectionMode:
        _dismissNativeSelectionOverlayForEditing();
        return;
    }
  }

  void _dismissTemporaryNativeSelectionOverlay() {
    if (!_revealsNativeSelectionOverlayInTouchScrollMode) {
      return;
    }

    final textLength = _nativeSelectionController.text.length;
    final collapsedOffset = _nativeSelectionController.selection.extentOffset
        .clamp(0, textLength);
    _nativeOverlayCollapseTimer?.cancel();
    _nativeSelectionController.value = _nativeSelectionController.value
        .copyWith(selection: TextSelection.collapsed(offset: collapsedOffset));
    _terminalController.clearSelection();
    _nativeSelectionFocusNode.unfocus();
    _hadNativeOverlaySelection = false;
    _clearPendingTouchSelectionRange();
    _clearNativeOverlayLongPressState();
    if (!mounted) {
      return;
    }
    setState(() {
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
  }

  void _dismissNativeSelectionOverlayForEditing() {
    if (!mounted) {
      return;
    }

    if (!_isNativeSelectionMode) {
      return;
    }

    if (_revealsNativeSelectionOverlayInTouchScrollMode) {
      _dismissTemporaryNativeSelectionOverlay();
      return;
    }

    if (!_isMobilePlatform) {
      return;
    }

    _nativeSelectionFocusNode.unfocus();
    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    _hadNativeOverlaySelection = false;
    _clearPendingTouchSelectionRange();
    _nativeSelectionSnapshotMetrics = null;
    _nativeOverlayCollapseTimer?.cancel();
    _clearNativeOverlayLongPressState();
    setState(() {
      _isNativeSelectionMode = false;
      _hasTerminalSelection = false;
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
  }

  String? _resolveTerminalLinkTap(CellOffset offset) {
    if (!shouldResolveTerminalTapLinks(
      showsNativeSelectionOverlay: _showsNativeSelectionOverlay,
    )) {
      return null;
    }

    final trackedHyperlink = _terminalHyperlinkTracker?.resolveLinkAt(offset);
    if (trackedHyperlink != null) {
      _pendingTerminalPathTap = null;
      return trackedHyperlink;
    }

    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    final line = _terminal.buffer.lines[row];
    if (line.getCodePoint(column) != 0) {
      final wrappedSnapshot = _buildWrappedTerminalLinkSnapshot(row);
      if (wrappedSnapshot != null) {
        final rowIndex = row - wrappedSnapshot.startRow;
        final textOffset =
            wrappedSnapshot.rowStarts[rowIndex] +
            wrappedSnapshot.columnOffsets[rowIndex][column];
        final detectedLink = detectTerminalLinkAtTextOffset(
          wrappedSnapshot.text,
          textOffset,
        );
        if (detectedLink != null) {
          _pendingTerminalPathTap = null;
          return detectedLink.uri.toString();
        }
      }
    }

    if (!ref.read(terminalPathLinksNotifierProvider)) {
      _pendingTerminalPathTap = null;
      return null;
    }

    final detectedPath = _resolveTerminalFilePathAtOffset(
      offset,
      forgiving: _isMobilePlatform,
    );
    if (detectedPath == null) {
      final pendingPath = _pendingTerminalPathTap;
      _pendingTerminalPathTap = null;
      if (pendingPath == null || !_isInteractiveTerminalFilePath(pendingPath)) {
        return null;
      }
      return '$_terminalSftpPathPrefix$pendingPath';
    }

    _pendingTerminalPathTap = null;
    return '$_terminalSftpPathPrefix$detectedPath';
  }

  String? _resolveTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final detectedPath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: forgiving,
    );
    if (detectedPath == null) {
      return null;
    }

    if (_isInteractiveTerminalFilePath(detectedPath)) {
      return detectedPath;
    }

    _primeTerminalFilePathVerification(detectedPath);
    return null;
  }

  String? _detectTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final candidateOffsets = forgiving
        ? resolveForgivingTerminalTapOffsets(offset)
        : <CellOffset>[offset];
    for (final candidateOffset in candidateOffsets) {
      final detectedPath = _detectTerminalFilePathAtCell(candidateOffset);
      if (detectedPath != null) {
        return detectedPath;
      }
    }
    if (forgiving) {
      return _resolveSingleInteractiveTerminalFilePathOnRow(offset.y);
    }
    return null;
  }

  String? _resolveSingleInteractiveTerminalFilePathOnRow(int row) {
    final segments = _resolveInteractiveTerminalPathSegmentsOnRow(row);
    return segments.length == 1 ? segments.single.path : null;
  }

  String? _detectTerminalFilePathAtCell(CellOffset offset) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final pathSnapshot = _buildTerminalPathTapSnapshot(row);
    if (pathSnapshot == null) {
      return null;
    }

    return _detectTerminalFilePathInSnapshotAtCell(pathSnapshot, offset);
  }

  String? _detectTerminalFilePathInSnapshotAtCell(
    _TerminalPathTapSnapshot pathSnapshot,
    CellOffset offset,
  ) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    final line = _terminal.buffer.lines[row];
    if (line.getCodePoint(column) == 0) {
      return null;
    }

    final pathRowIndex = row - pathSnapshot.startRow;
    if (pathRowIndex < 0 || pathRowIndex >= pathSnapshot.columnOffsets.length) {
      return null;
    }

    final rowColumnOffsets = pathSnapshot.columnOffsets[pathRowIndex];
    if (column >= rowColumnOffsets.length) {
      return null;
    }

    final pathTextOffset =
        pathSnapshot.rowStarts[pathRowIndex] + rowColumnOffsets[column];
    final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      final activePath = _interactiveTerminalFilePathCandidate(
        detectedPath.path,
      );
      final activeEnd = activePath == null
          ? detectedPath.hitTestEnd
          : _resolveOriginalTerminalPathMatchEnd(
              normalizedSnapshot: snapshotAnalysis.normalizedSnapshot,
              normalizedStart: detectedPath.normalizedStart,
              normalizedLength: activePath.length,
            );
      if (activeEnd == null) {
        continue;
      }
      if (pathTextOffset >= detectedPath.start && pathTextOffset < activeEnd) {
        return detectedPath.path;
      }
    }
    return null;
  }

  _TerminalPathTapSnapshot? _buildWrappedTerminalLinkSnapshot(int row) {
    final buffer = _terminal.buffer;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = _buildNativeSelectionLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
      );
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
    }

    return (
      text: builder.toString(),
      startRow: startRow,
      rowStarts: rowStarts,
      columnOffsets: columnOffsets,
    );
  }

  _TerminalPathTapSnapshot? _buildTerminalPathTapSnapshot(int row) {
    final buffer = _terminal.buffer;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    String lineTextAt(int lineIndex) => _buildNativeSelectionLineSnapshot(
      buffer.lines[lineIndex],
      buffer.viewWidth,
    ).text;

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    while (startRow > 0 &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(startRow - 1),
          nextLineText: lineTextAt(startRow),
        )) {
      startRow--;
    }

    while (endRow + 1 < buffer.height &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(endRow),
          nextLineText: lineTextAt(endRow + 1),
        )) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = _buildNativeSelectionLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
      );
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
      if (lineIndex < endRow && !buffer.lines[lineIndex + 1].isWrapped) {
        builder.write('\n');
      }
    }

    return (
      text: builder.toString(),
      startRow: startRow,
      rowStarts: rowStarts,
      columnOffsets: columnOffsets,
    );
  }

  void _handleTerminalPathHover(PointerHoverEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null ||
        !ref.read(terminalPathLinksNotifierProvider) ||
        !ref.read(terminalPathLinkUnderlinesNotifierProvider)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final isSameHoveredCell =
        _lastHoveredTerminalPathOffset?.x == offset.x &&
        _lastHoveredTerminalPathOffset?.y == offset.y;
    final detectedPath = isSameHoveredCell
        ? _lastHoveredTerminalPath
        : _resolveTerminalFilePathAtOffset(offset);
    if (!isSameHoveredCell) {
      _lastHoveredTerminalPathOffset = offset;
      _lastHoveredTerminalPath = detectedPath;
    }
    if (detectedPath == null || !_shouldShowTerminalPathBadge(detectedPath)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final hoveredSegment = _resolveInteractiveTerminalPathSegmentAtOffset(
      offset,
      path: detectedPath,
    );
    if (hoveredSegment == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final underline = _buildTerminalPathUnderlineRect(
      terminalViewState,
      row: offset.y,
      startColumn: hoveredSegment.startColumn,
      endColumn: hoveredSegment.endColumn,
      text: hoveredSegment.text,
    );
    if (underline == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    if (_hoveredTerminalPathUnderline == underline) {
      return;
    }
    setState(() => _hoveredTerminalPathUnderline = underline);
  }

  void _handleTerminalPathPointerDown(PointerDownEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    final pathLinksEnabled = ref.read(terminalPathLinksNotifierProvider);
    _pendingTerminalPathTap = null;
    if (terminalViewState == null || !pathLinksEnabled) {
      if (_hoveredTerminalPathUnderline != null) {
        _clearHoveredTerminalPathUnderline();
      }
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final terminalViewObject = terminalViewState.context.findRenderObject();
    final terminalViewLocalPosition = terminalViewObject is RenderBox
        ? terminalViewObject.globalToLocal(event.position)
        : terminalLocalPosition;
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final candidatePath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: event.kind == PointerDeviceKind.touch,
    );
    final underlinePath = event.kind == PointerDeviceKind.touch
        ? resolveTerminalPathTouchTargetTap(terminalViewLocalPosition, [
            for (final underline in _visibleTerminalPathUnderlines)
              (path: underline.path, touchRect: underline.touchRect),
          ])
        : null;
    final tappedPath = candidatePath ?? underlinePath;
    if (tappedPath != null && event.kind == PointerDeviceKind.touch) {
      _terminalTextInputController.suppressNextTouchKeyboardRequest();
    }
    if (candidatePath != null &&
        !_isInteractiveTerminalFilePath(candidatePath)) {
      _primeTerminalFilePathVerification(candidatePath);
    }
    if (tappedPath != null && _isInteractiveTerminalFilePath(tappedPath)) {
      _pendingTerminalPathTap = tappedPath;
    }
  }

  void _clearHoveredTerminalPathUnderline() {
    _lastHoveredTerminalPathOffset = null;
    _lastHoveredTerminalPath = null;
    if (_hoveredTerminalPathUnderline == null || !mounted) {
      return;
    }
    setState(() => _hoveredTerminalPathUnderline = null);
  }

  bool _shouldShowTerminalPathBadge(String path) =>
      _isInteractiveTerminalFilePath(path);

  void _queueVisibleTerminalPathUnderlineRefresh() {
    if (!_isMobilePlatform ||
        _isTerminalPathUnderlineRefreshQueued ||
        !mounted) {
      return;
    }

    _isTerminalPathUnderlineRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalPathUnderlineRefreshQueued = false;
      if (!mounted) {
        return;
      }
      _refreshVisibleTerminalPathUnderlines();
    });
  }

  void _refreshVisibleTerminalPathUnderlines() {
    final terminalViewState = _terminalViewKey.currentState;
    final showsUnderlines =
        ref.read(terminalPathLinksNotifierProvider) &&
        ref.read(terminalPathLinkUnderlinesNotifierProvider);
    if (!_isMobilePlatform || !showsUnderlines || terminalViewState == null) {
      if (_visibleTerminalPathUnderlines.isNotEmpty) {
        setState(
          () => _visibleTerminalPathUnderlines =
              const <({String path, Rect underlineRect, Rect touchRect})>[],
        );
      }
      return;
    }

    final renderTerminal = terminalViewState.renderTerminal;
    final rowRange = resolveVisibleTerminalRowRange(
      scrollOffset: _terminalScrollController.hasClients
          ? _terminalScrollController.offset
          : 0,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: renderTerminal.size.height,
      bufferHeight: _terminal.buffer.height,
    );
    if (rowRange == null) {
      return;
    }

    final underlines = <({String path, Rect underlineRect, Rect touchRect})>[];
    var row = rowRange.topRow;
    while (row <= rowRange.bottomRow) {
      final pathSnapshot = _buildTerminalPathTapSnapshot(row);
      if (pathSnapshot == null) {
        row++;
        continue;
      }
      final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
      final snapshotEndRow =
          pathSnapshot.startRow + pathSnapshot.columnOffsets.length - 1;
      final visibleSnapshotBottom = min(rowRange.bottomRow, snapshotEndRow);
      for (
        var snapshotRow = max(row, pathSnapshot.startRow);
        snapshotRow <= visibleSnapshotBottom;
        snapshotRow++
      ) {
        final segments = _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
          snapshotRow,
          pathSnapshot: pathSnapshot,
          snapshotAnalysis: snapshotAnalysis,
        );
        for (final segment in segments) {
          if (!_shouldShowTerminalPathBadge(segment.path)) {
            continue;
          }
          final underlineRect = _buildTerminalPathUnderlineRect(
            terminalViewState,
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
            text: segment.text,
          );
          final touchRect = _buildTerminalPathTouchTargetRect(
            terminalViewState,
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          if (underlineRect != null && touchRect != null) {
            underlines.add((
              path: segment.path,
              underlineRect: underlineRect,
              touchRect: touchRect,
            ));
          }
        }
      }
      row = visibleSnapshotBottom + 1;
    }

    if (!listEquals(_visibleTerminalPathUnderlines, underlines)) {
      setState(() => _visibleTerminalPathUnderlines = underlines);
    }
  }

  Rect? _buildTerminalPathUnderlineRect(
    MonkeyTerminalViewState terminalViewState, {
    required int row,
    required int startColumn,
    required int endColumn,
    required String text,
  }) {
    final terminalViewObject = terminalViewState.context.findRenderObject();
    if (terminalViewObject is! RenderBox) {
      return null;
    }
    final renderTerminal = terminalViewState.renderTerminal;
    final lineTopLeft = renderTerminal.localToGlobal(
      renderTerminal.getOffset(CellOffset(startColumn, row)),
      ancestor: terminalViewObject,
    );
    final measuredTextSize = _measureTerminalPathUnderlineTextSize(text);
    final lineEndOffset = renderTerminal.localToGlobal(
      renderTerminal.getOffset(
        CellOffset((endColumn + 1).clamp(0, _terminal.buffer.viewWidth), row),
      ),
      ancestor: terminalViewObject,
    );
    return resolveTerminalPathUnderlineRect(
      lineTopLeft: lineTopLeft,
      lineEndOffset: lineEndOffset,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: terminalViewObject.size.height,
      rowHeight: renderTerminal.cellSize.height,
      textHeight: measuredTextSize?.height,
    );
  }

  Rect? _buildTerminalPathTouchTargetRect(
    MonkeyTerminalViewState terminalViewState, {
    required int row,
    required int startColumn,
    required int endColumn,
  }) {
    final terminalViewObject = terminalViewState.context.findRenderObject();
    if (terminalViewObject is! RenderBox) {
      return null;
    }
    final renderTerminal = terminalViewState.renderTerminal;
    final lineTopLeft = renderTerminal.localToGlobal(
      renderTerminal.getOffset(CellOffset(startColumn, row)),
      ancestor: terminalViewObject,
    );
    final lineEndOffset = renderTerminal.localToGlobal(
      renderTerminal.getOffset(
        CellOffset((endColumn + 1).clamp(0, _terminal.buffer.viewWidth), row),
      ),
      ancestor: terminalViewObject,
    );
    return resolveTerminalPathTouchTargetRect(
      lineTopLeft: lineTopLeft,
      lineEndOffset: lineEndOffset,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: terminalViewObject.size.height,
    );
  }

  ({String path, String text, int startColumn, int endColumn})?
  _resolveInteractiveTerminalPathSegmentAtOffset(
    CellOffset offset, {
    String? path,
  }) {
    for (final segment in _resolveInteractiveTerminalPathSegmentsOnRow(
      offset.y,
    )) {
      if (offset.x >= segment.startColumn &&
          offset.x <= segment.endColumn &&
          (path == null || segment.path == path)) {
        return segment;
      }
    }
    return null;
  }

  _TerminalPathSnapshotAnalysis _analyzeTerminalPathSnapshot(
    _TerminalPathTapSnapshot pathSnapshot,
  ) => (
    detectedPaths: _detectTerminalFilePathMatches(pathSnapshot.text),
    normalizedSnapshot: _normalizeTerminalFilePathDetectionText(
      pathSnapshot.text,
    ),
  );

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsOnRow(int row) {
    final clampedRow = row.clamp(0, _terminal.buffer.height - 1);
    final pathSnapshot = _buildTerminalPathTapSnapshot(clampedRow);
    if (pathSnapshot == null) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    return _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
      clampedRow,
      pathSnapshot: pathSnapshot,
      snapshotAnalysis: _analyzeTerminalPathSnapshot(pathSnapshot),
    );
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
    int row, {
    required _TerminalPathTapSnapshot pathSnapshot,
    required _TerminalPathSnapshotAnalysis snapshotAnalysis,
  }) {
    final rowIndex = row - pathSnapshot.startRow;
    if (rowIndex < 0 || rowIndex >= pathSnapshot.columnOffsets.length) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }
    if (snapshotAnalysis.detectedPaths.isEmpty) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    final rowStart = pathSnapshot.rowStarts[rowIndex];
    final rowColumnOffsets = pathSnapshot.columnOffsets[rowIndex];
    final rowEnd = rowStart + rowColumnOffsets.last;
    final rowText = pathSnapshot.text.substring(rowStart, rowEnd);
    final rowNormalizedStart = snapshotAnalysis
        .normalizedSnapshot
        .originalToNormalizedOffsets[rowStart];
    final rowNormalizedEnd =
        snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets[rowEnd];
    final relativeCandidatesToPrime = <String>{};
    final segments =
        <({String path, String text, int startColumn, int endColumn})>[];
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      if (detectedPath.normalizedEnd <= rowNormalizedStart ||
          detectedPath.normalizedStart >= rowNormalizedEnd) {
        continue;
      }

      final path = detectedPath.path;
      final activePath = _interactiveTerminalFilePathCandidate(path);
      if (activePath != null) {
        final visibleSegment = resolveTerminalFilePathSegmentOnRow(
          rowText: rowText,
          rowStartOffset: rowStart,
          rowColumnOffsets: rowColumnOffsets,
          originalToNormalizedOffsets:
              snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets,
          normalizedPathStart: detectedPath.normalizedStart,
          normalizedPathEnd: detectedPath.normalizedStart + activePath.length,
        );
        if (visibleSegment == null) {
          continue;
        }
        segments.add((
          path: path,
          text: visibleSegment.text,
          startColumn: visibleSegment.startColumn,
          endColumn: visibleSegment.endColumn,
        ));
      } else if (requiresTerminalFilePathVerification(path)) {
        relativeCandidatesToPrime.add(path);
      }
    }

    for (final path in relativeCandidatesToPrime) {
      _primeTerminalFilePathVerification(path);
    }

    return segments;
  }

  ({String text, int cursorOffset})? _buildWrappedTerminalCommandSnapshot() {
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = _buildTerminalLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
        preserveTrailingPadding: lineIndex < endRow,
        preserveOffset: lineIndex == row
            ? buffer.cursorX.clamp(0, buffer.viewWidth)
            : 0,
      );
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
    }

    final rowIndex = row - startRow;
    final cursorColumn = buffer.cursorX.clamp(0, buffer.viewWidth);
    final cursorOffset =
        rowStarts[rowIndex] + columnOffsets[rowIndex][cursorColumn];
    return (text: builder.toString(), cursorOffset: cursorOffset);
  }

  String? _terminalTextBeforeCursor() {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return null;
    }
    return snapshot.text.substring(0, snapshot.cursorOffset);
  }

  void _handleTerminalLinkTap(String link) {
    _clearPendingTouchSelectionRange();
    _clearHoveredTerminalPathUnderline();
    if (link.startsWith(_terminalSftpPathPrefix)) {
      unawaited(
        _openTerminalFilePath(link.substring(_terminalSftpPathPrefix.length)),
      );
      return;
    }

    unawaited(_openTerminalLink(link));
  }

  void _showTerminalLinkMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTerminalLink(String link) async {
    final normalizedLink = normalizeTerminalLinkCandidate(link);
    final uri = Uri.tryParse(normalizedLink);
    if (uri == null) {
      _showTerminalLinkMessage('Could not open $link');
      return;
    }

    if (!isLaunchableTerminalUri(uri)) {
      _showTerminalLinkMessage('Blocked unsupported link scheme: $link');
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      launched = false;
    }
    if (launched || !mounted) {
      return;
    }

    _showTerminalLinkMessage('Could not open $link');
  }

  Future<void> _openTerminalFilePath(String path) async {
    final normalizedPath = trimTerminalFilePathCandidate(path);
    if (!isSupportedTerminalFilePath(normalizedPath)) {
      _showTerminalLinkMessage('Could not open $path');
      return;
    }

    final verifiedPath = await _resolveVerifiedTerminalFilePath(normalizedPath);
    if (!mounted || verifiedPath == null) {
      return;
    }

    final connectionId = _connectionId;
    final result = await context.pushNamed<String>(
      Routes.sftp,
      pathParameters: {'hostId': widget.hostId.toString()},
      queryParameters: {
        if (connectionId != null) 'connectionId': connectionId.toString(),
        'path': verifiedPath,
      },
    );
    if (!mounted || result == null) {
      return;
    }

    _showTerminalLinkMessage(result);
  }

  Widget get _selectionActions => Material(
    elevation: 2,
    borderRadius: BorderRadius.circular(12),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () => unawaited(_copySelection()),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copy'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () => unawaited(_pasteClipboard()),
              icon: const Icon(Icons.paste_outlined),
              label: const Text('Paste'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () {
                _terminalController.clearSelection();
                _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
              },
              icon: const Icon(Icons.close),
              label: const Text('Clear'),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _copySelection() async {
    if (_isNativeSelectionMode) {
      final text = selectedNativeOverlayText(_nativeSelectionController.value);
      if (text.isEmpty) {
        return;
      }

      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied')));
      return;
    }

    final selection = _terminalController.selection;
    if (selection == null) {
      return;
    }
    final text = trimTerminalSelectionText(_terminal.buffer.getText(selection));
    if (text.isEmpty) {
      _restoreTerminalFocus();
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    _terminalController.clearSelection();
    _restoreTerminalFocus();

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  void _showClipboardMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyWorkingDirectory() async {
    final path = _workingDirectoryPath;
    if (path == null || path.isEmpty) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    await Clipboard.setData(ClipboardData(text: path));
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied current directory')));
  }

  SshSession? _activeSession() {
    final connectionId = _connectionId;
    final sessionsNotifier = _sessionsNotifier;
    if (connectionId == null || sessionsNotifier == null) {
      return null;
    }
    return sessionsNotifier.getSession(connectionId);
  }

  String _terminalPathCacheKey(String terminalPath) =>
      '${_currentTerminalPathCacheScope()}:$terminalPath';

  String _currentTerminalPathCacheScope() =>
      '${widget.hostId}:${_connectionId ?? 0}:${_workingDirectoryPath ?? ''}';

  void _syncVerifiedTerminalPathCacheScope() {
    final nextScope = _currentTerminalPathCacheScope();
    if (_terminalPathCacheScope == nextScope) {
      return;
    }
    _terminalPathCacheScope = nextScope;
    _resetVerifiedTerminalPathCache();
  }

  void _resetVerifiedTerminalPathCache() {
    _verifiedTerminalPathCache.clear();
    _verifiedTerminalPathCacheOrder.clear();
    _verifyingTerminalPathCacheKeys.clear();
  }

  void _cacheVerifiedTerminalPath(
    String cacheKey, {
    required String terminalPath,
    required String resolvedPath,
  }) {
    _verifiedTerminalPathCache.remove(cacheKey);
    _verifiedTerminalPathCache[cacheKey] = (
      terminalPath: terminalPath,
      resolvedPath: resolvedPath,
    );
    _verifiedTerminalPathCacheOrder
      ..remove(cacheKey)
      ..addLast(cacheKey);
    while (_verifiedTerminalPathCacheOrder.length >
        _maxVerifiedTerminalPathCacheEntries) {
      final evictedKey = _verifiedTerminalPathCacheOrder.removeFirst();
      _verifiedTerminalPathCache.remove(evictedKey);
    }
  }

  void _disposeTerminalPathVerificationSftp() {
    _terminalPathVerificationSftp?.close();
    _terminalPathVerificationSftp = null;
    _terminalPathVerificationSftpFuture = null;
    _terminalPathVerificationSession = null;
    _terminalPathVerificationHomeDirectory = null;
  }

  Future<SftpClient?> _resolveTerminalPathVerificationSftp(
    SshSession session,
  ) async {
    if (!identical(_terminalPathVerificationSession, session)) {
      _disposeTerminalPathVerificationSftp();
      _terminalPathVerificationSession = session;
    }

    final cachedSftp = _terminalPathVerificationSftp;
    if (cachedSftp != null) {
      return cachedSftp;
    }

    final inFlight = _terminalPathVerificationSftpFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = session
        .sftp()
        .timeout(_terminalPathVerificationTimeout)
        .then<SftpClient?>((sftp) {
          if (!identical(_terminalPathVerificationSession, session)) {
            sftp.close();
            return null;
          }
          _terminalPathVerificationSftp = sftp;
          return sftp;
        });
    _terminalPathVerificationSftpFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_terminalPathVerificationSftpFuture, future)) {
        _terminalPathVerificationSftpFuture = null;
      }
    }
  }

  Future<String?> _resolveTerminalPathVerificationHomeDirectory(
    SftpClient sftp,
    String terminalPath,
  ) async {
    if (terminalPath != '~' && !terminalPath.startsWith('~/')) {
      return null;
    }
    final cachedHomeDirectory = _terminalPathVerificationHomeDirectory;
    if (cachedHomeDirectory != null) {
      return cachedHomeDirectory;
    }

    final homeDirectory = normalizeSftpAbsolutePath(
      await sftp.absolute('.').timeout(_terminalPathVerificationTimeout),
    );
    _terminalPathVerificationHomeDirectory = homeDirectory;
    return homeDirectory;
  }

  _VerifiedTerminalPath? _verifiedTerminalPath(String terminalPath) {
    _syncVerifiedTerminalPathCacheScope();
    return _verifiedTerminalPathCache[_terminalPathCacheKey(terminalPath)];
  }

  String? _interactiveTerminalFilePathCandidate(String terminalPath) {
    final verifiedPath = _verifiedTerminalPath(terminalPath);
    if (verifiedPath != null) {
      return verifiedPath.terminalPath;
    }
    if (!_isInteractiveTerminalFilePath(terminalPath)) {
      return null;
    }
    return terminalPath;
  }

  bool _isInteractiveTerminalFilePath(String terminalPath) =>
      shouldActivateTerminalFilePath(
        terminalPath,
        hasVerifiedPath: _verifiedTerminalPath(terminalPath) != null,
      );

  void _primeTerminalFilePathVerification(String terminalPath) {
    if (!requiresTerminalFilePathVerification(terminalPath)) {
      return;
    }

    _syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    if (_verifiedTerminalPathCache.containsKey(cacheKey) ||
        _verifyingTerminalPathCacheKeys.contains(cacheKey)) {
      return;
    }

    _verifyingTerminalPathCacheKeys.add(cacheKey);
    unawaited(() async {
      try {
        final verifiedPath = await _resolveVerifiedTerminalFilePath(
          terminalPath,
          showErrors: false,
        );
        if (!mounted || verifiedPath == null) {
          return;
        }
        setState(() {
          _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = true;
        });
      } finally {
        _verifyingTerminalPathCacheKeys.remove(cacheKey);
      }
    }());
  }

  Future<String?> _resolveVerifiedTerminalFilePath(
    String terminalPath, {
    bool showErrors = true,
  }) async {
    _syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    final cachedPath = _verifiedTerminalPathCache[cacheKey];
    if (cachedPath != null) {
      return cachedPath.resolvedPath;
    }

    final session = _activeSession();
    final isExplicitPath = isExplicitTerminalFilePath(terminalPath);
    if (session == null) {
      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }

    try {
      final sftp = await _resolveTerminalPathVerificationSftp(session);
      if (sftp == null) {
        return null;
      }
      final verificationCandidates =
          requiresTerminalFilePathVerification(terminalPath)
          ? resolveTerminalFilePathVerificationCandidates(terminalPath)
          : <String>[terminalPath];
      for (final candidate in verificationCandidates) {
        final homeDirectory =
            await _resolveTerminalPathVerificationHomeDirectory(
              sftp,
              candidate,
            );
        final resolvedPath = resolveRequestedSftpPath(
          candidate,
          workingDirectory: _workingDirectoryPath,
          homeDirectory: homeDirectory,
        );
        if (resolvedPath == null) {
          continue;
        }

        try {
          await sftp
              .stat(resolvedPath)
              .timeout(_terminalPathVerificationTimeout);
        } on SftpStatusError catch (error) {
          if (error.code == SftpStatusCode.noSuchFile) {
            continue;
          }
          rethrow;
        }

        _cacheVerifiedTerminalPath(
          cacheKey,
          terminalPath: candidate,
          resolvedPath: resolvedPath,
        );
        return resolvedPath;
      }

      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage(
          'Could not open "$terminalPath" in SFTP: path does not exist',
        );
      }
      return null;
    } on TimeoutException {
      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage('Timed out opening "$terminalPath" in SFTP');
      }
      return null;
    } on SftpStatusError catch (error) {
      if (showErrors && isExplicitPath) {
        final message = error.code == SftpStatusCode.noSuchFile
            ? 'Could not open "$terminalPath" in SFTP: path does not exist'
            : 'Could not open "$terminalPath" in SFTP';
        _showTerminalLinkMessage(message);
      }
      return null;
    } on Object catch (error, stackTrace) {
      debugPrint(
        'Failed to resolve terminal file path "$terminalPath": $error',
      );
      debugPrint('$stackTrace');
      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }
  }

  int? _resolveOriginalTerminalPathMatchEnd({
    required _NormalizedTerminalPathSnapshot normalizedSnapshot,
    required int normalizedStart,
    required int normalizedLength,
  }) {
    if (normalizedLength <= 0) {
      return null;
    }

    final normalizedEnd = normalizedStart + normalizedLength;
    if (normalizedEnd > normalizedSnapshot.normalizedToOriginalEnds.length) {
      return null;
    }

    return normalizedSnapshot.normalizedToOriginalEnds[normalizedEnd - 1];
  }

  Future<void> _pasteClipboard() async {
    try {
      if (_isAndroidPlatform) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes);
          return;
        }
      }

      final clipboardFiles = await Pasteboard.files();
      if (clipboardFiles.isNotEmpty) {
        await _pasteClipboardFiles(clipboardFiles);
        return;
      }

      if (!_isAndroidPlatform) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes);
          return;
        }
      }

      final text = await Pasteboard.text;
      if (text == null || text.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        _showClipboardMessage('Clipboard is empty');
        return;
      }

      final shouldPaste =
          !_shouldReviewTerminalCommandInsertion ||
          await _confirmTerminalInsertionIfNeeded(
            insertedText: text,
            buildReview: (commandText) => assessClipboardPasteCommand(
              commandText,
              bracketedPasteModeEnabled: _terminal.bracketedPasteMode,
            ),
            title: 'Review clipboard paste',
            messageBuilder: (review) => review.bracketedPasteModeEnabled
                ? 'This clipboard content looks risky even with bracketed paste enabled.'
                : 'This clipboard content could execute multiple or reshaped commands.',
            confirmLabel: 'Paste anyway',
          );
      if (!shouldPaste) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      _followLiveOutput();
      _terminal.paste(text);
      _terminalController.clearSelection();
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    } on PlatformException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        'Clipboard access failed: ${error.message ?? error.code}',
      );
    } on FileSystemException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        error.message.isEmpty
            ? 'Clipboard file upload failed'
            : 'Clipboard file upload failed: ${error.message}',
      );
    } on SftpError catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Remote upload failed: ${error.message}');
    } on Object catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard upload failed: $error');
    }
  }

  Future<void> _pastePickedImage() async {
    final pickerRequest = resolveTerminalUploadPickerRequest(images: true);
    await _pickAndPasteFiles(
      dialogTitle: pickerRequest.dialogTitle,
      pickerType: pickerRequest.pickerType,
      itemLabelSingular: pickerRequest.itemLabelSingular,
      itemLabelPlural: pickerRequest.itemLabelPlural,
      allowMultiple: pickerRequest.allowMultiple,
      failureContext: pickerRequest.failureContext,
    );
  }

  Future<void> _pastePickedFiles() async {
    final pickerRequest = resolveTerminalUploadPickerRequest(images: false);
    await _pickAndPasteFiles(
      dialogTitle: pickerRequest.dialogTitle,
      pickerType: pickerRequest.pickerType,
      itemLabelSingular: pickerRequest.itemLabelSingular,
      itemLabelPlural: pickerRequest.itemLabelPlural,
      allowMultiple: pickerRequest.allowMultiple,
      failureContext: pickerRequest.failureContext,
    );
  }

  Future<void> _pickAndPasteFiles({
    required String dialogTitle,
    required FileType pickerType,
    required String itemLabelSingular,
    required String itemLabelPlural,
    required bool allowMultiple,
    required String failureContext,
  }) async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        type: pickerType,
        allowMultiple: allowMultiple,
        withData: kIsWeb,
        withReadStream: !kIsWeb,
      );
      if (!mounted) {
        return;
      }
      if (result == null || result.files.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      await _pasteSelectedFiles(
        result.files,
        itemLabelSingular: itemLabelSingular,
        itemLabelPlural: itemLabelPlural,
      );
    } on PlatformException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        '$failureContext failed: ${error.message ?? error.code}',
      );
    } on FileSystemException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        error.message.isEmpty
            ? '$failureContext failed'
            : '$failureContext failed: ${error.message}',
      );
    } on SftpError catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Remote upload failed: ${error.message}');
    } on Object catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('$failureContext failed: $error');
    }
  }

  Future<T> _withClipboardSftp<T>(
    Future<T> Function(SftpClient sftp, RemoteFileService remoteFileService)
    action,
  ) async {
    final session = _activeSession();
    if (session == null) {
      throw StateError('Connection is not ready yet');
    }

    final remoteFileService = ref.read(remoteFileServiceProvider);
    final sftp = await session.sftp();
    try {
      await remoteFileService.ensureDirectoryExists(
        sftp,
        remoteClipboardUploadDirectory,
      );
      return await action(sftp, remoteFileService);
    } finally {
      sftp.close();
    }
  }

  Future<({String name, Uint8List bytes})> _readAndroidClipboardContentUri(
    String uri,
  ) async {
    final response = await _clipboardContentChannel.invokeMethod<Object>(
      'readContentUri',
      {'uri': uri},
    );
    if (response is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Unexpected clipboard content response',
      );
    }

    final name = response['name'];
    final bytes = response['bytes'];
    if (name is! String || bytes is! Uint8List) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Clipboard content response was incomplete',
      );
    }

    return (name: name, bytes: bytes);
  }

  Future<bool> _confirmClipboardUpload({
    required String title,
    required String message,
    required String confirmLabel,
    List<String> details = const [],
  }) async {
    if (!mounted) {
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final detail in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('\u2022 $detail'),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _pasteClipboardFiles(List<String> clipboardFiles) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard files?',
      message:
          'This will upload ${clipboardFiles.length} clipboard file${clipboardFiles.length == 1 ? '' : 's'} to $remoteClipboardUploadDirectory on the connected host and paste their remote paths into the terminal.',
      confirmLabel: 'Upload and paste',
      details: [
        for (var index = 0; index < clipboardFiles.length; index++)
          clipboardFiles[index].startsWith('content://')
              ? 'Clipboard file ${index + 1}'
              : path.basename(clipboardFiles[index]),
      ],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final timestamp = DateTime.now();
    final remotePaths = await _withClipboardSftp((
      sftp,
      remoteFileService,
    ) async {
      final remotePaths = <String>[];
      for (var index = 0; index < clipboardFiles.length; index++) {
        final localPath = clipboardFiles[index];
        final isContentUri = localPath.startsWith('content://');
        late final String sourceName;
        late final String remotePath;

        if (isContentUri) {
          if (!_isAndroidPlatform) {
            throw const FileSystemException(
              'Clipboard file URIs are not supported on this platform yet',
            );
          }
          final clipboardFile = await _readAndroidClipboardContentUri(
            localPath,
          );
          sourceName = clipboardFile.name;
          remotePath = joinRemotePath(
            remoteClipboardUploadDirectory,
            buildClipboardUploadFileName(
              sourceName,
              timestamp,
              sequence: index,
            ),
          );
          await remoteFileService.uploadBytes(
            sftp: sftp,
            remotePath: remotePath,
            bytes: clipboardFile.bytes,
          );
        } else {
          sourceName = path.basename(localPath);
          remotePath = joinRemotePath(
            remoteClipboardUploadDirectory,
            buildClipboardUploadFileName(
              sourceName,
              timestamp,
              sequence: index,
            ),
          );
          await remoteFileService.uploadStream(
            sftp: sftp,
            remotePath: remotePath,
            stream: File(localPath).openRead(),
          );
        }
        remotePaths.add(remotePath);
      }
      return remotePaths;
    });

    _followLiveOutput();
    _terminal.paste('${buildTerminalUploadInsertion(remotePaths)} ');
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage(
      'Uploaded ${remotePaths.length} file${remotePaths.length == 1 ? '' : 's'} to $remoteClipboardUploadDirectory',
    );
  }

  Future<void> _pasteClipboardImage(Uint8List imageBytes) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard image?',
      message:
          'This will upload the clipboard image to $remoteClipboardUploadDirectory on the connected host and paste its remote path into the terminal.',
      confirmLabel: 'Upload and paste',
      details: const ['image.png'],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final remotePath = await _withClipboardSftp((
      sftp,
      remoteFileService,
    ) async {
      final remotePath = joinRemotePath(
        remoteClipboardUploadDirectory,
        buildClipboardImageFileName(DateTime.now()),
      );
      await remoteFileService.uploadBytes(
        sftp: sftp,
        remotePath: remotePath,
        bytes: imageBytes,
      );
      return remotePath;
    });
    _followLiveOutput();
    _terminal.paste('${shellEscapePosix(remotePath)} ');
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage('Uploaded clipboard image to $remotePath');
  }

  Future<void> _pasteSelectedFiles(
    List<PlatformFile> selectedFiles, {
    required String itemLabelSingular,
    required String itemLabelPlural,
  }) async {
    if (!mounted) {
      return;
    }
    final itemLabel = selectedFiles.length == 1
        ? itemLabelSingular
        : itemLabelPlural;
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload selected $itemLabel?',
      message:
          'This will upload ${selectedFiles.length == 1 ? 'the selected $itemLabelSingular' : '${selectedFiles.length} selected $itemLabelPlural'} to $remoteClipboardUploadDirectory on the connected host and paste ${selectedFiles.length == 1 ? 'its remote path' : 'their remote paths'} into the terminal.',
      confirmLabel: 'Upload and paste',
      details: [
        for (var index = 0; index < selectedFiles.length; index++)
          resolvePickedTerminalUploadFileName(
            selectedFiles[index],
            index: index,
          ),
      ],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final timestamp = DateTime.now();
    final remotePaths = await _withClipboardSftp((
      sftp,
      remoteFileService,
    ) async {
      final remotePaths = <String>[];
      for (var index = 0; index < selectedFiles.length; index++) {
        final file = selectedFiles[index];
        final sourceName = resolvePickedTerminalUploadFileName(
          file,
          index: index,
        );
        final remotePath = joinRemotePath(
          remoteClipboardUploadDirectory,
          buildClipboardUploadFileName(sourceName, timestamp, sequence: index),
        );
        final readStream = resolvePickedTerminalUploadReadStream(file);
        if (readStream != null) {
          await remoteFileService.uploadStream(
            sftp: sftp,
            remotePath: remotePath,
            stream: readStream,
          );
        } else {
          final bytes = file.bytes;
          if (bytes == null) {
            throw const FileSystemException('Unable to read selected file');
          }
          await remoteFileService.uploadBytes(
            sftp: sftp,
            remotePath: remotePath,
            bytes: bytes,
          );
        }
        remotePaths.add(remotePath);
      }
      return remotePaths;
    });

    _followLiveOutput();
    _terminal.paste('${buildTerminalUploadInsertion(remotePaths)} ');
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage(
      'Uploaded ${selectedFiles.length == 1 ? 'selected $itemLabelSingular' : '${remotePaths.length} $itemLabelPlural'} to $remoteClipboardUploadDirectory',
    );
  }

  Future<bool> _confirmKeyboardInsertion(TerminalCommandReview review) async {
    if (!_shouldReviewTerminalCommandInsertion) {
      return true;
    }
    final shouldInsert = await _confirmCommandInsertion(
      title: 'Review keyboard paste',
      message:
          'This text inserted from your keyboard could execute multiple or reshaped commands.',
      confirmLabel: 'Insert anyway',
      review: review,
    );
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    return shouldInsert;
  }

  Future<bool> _confirmDesktopInsertedText(String text) async {
    if (text.length <= 1) {
      return true;
    }
    if (!_shouldReviewTerminalCommandInsertion) {
      return true;
    }

    return _confirmTerminalInsertionIfNeeded(
      insertedText: text,
      buildReview: (commandText) => assessClipboardPasteCommand(
        commandText,
        bracketedPasteModeEnabled: false,
      ),
      title: 'Review keyboard paste',
      messageBuilder: (_) =>
          'This text inserted from your keyboard could execute multiple or reshaped commands.',
      confirmLabel: 'Insert anyway',
    );
  }

  /// Shows snippet picker and inserts selected snippet into terminal.
  Future<void> _showSnippetPicker() async {
    final snippetRepo = ref.read(snippetRepositoryProvider);
    final snippets = await snippetRepo.getAll();

    if (!mounted) return;

    if (snippets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No snippets available. Add some first!')),
      );
      return;
    }

    final variablePattern = RegExp(r'\{\{(\w+)\}\}');

    final result =
        await showModalBottomSheet<
          ({String command, bool hadVariableSubstitution, int snippetId})
        >(
          context: context,
          isScrollControlled: true,
          builder: (context) => DraggableScrollableSheet(
            maxChildSize: 0.8,
            minChildSize: 0.3,
            expand: false,
            builder: (context, scrollController) => Column(
              children: [
                // Handle bar
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        'Snippets',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: snippets.length,
                    itemBuilder: (context, index) {
                      final snippet = snippets[index];
                      final hasVariables = variablePattern.hasMatch(
                        snippet.command,
                      );
                      return ListTile(
                        leading: Icon(
                          hasVariables ? Icons.tune : Icons.code,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(snippet.name),
                        subtitle: Text(
                          snippet.command.replaceAll('\n', ' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        trailing: hasVariables
                            ? const Chip(label: Text('Has variables'))
                            : null,
                        onTap: () async {
                          // Handle variable substitution
                          final command = await _substituteVariables(
                            context,
                            snippet,
                          );
                          if (command != null && context.mounted) {
                            Navigator.pop(context, (
                              command: command.command,
                              hadVariableSubstitution:
                                  command.hadVariableSubstitution,
                              snippetId: snippet.id,
                            ));
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );

    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    if (result != null && result.command.isNotEmpty) {
      final shouldInsert = await _confirmTerminalInsertionIfNeeded(
        insertedText: result.command,
        buildReview: (commandText) => assessSnippetCommandInsertion(
          commandText,
          hadVariableSubstitution: result.hadVariableSubstitution,
        ),
        title: 'Review snippet command',
        messageBuilder: (_) =>
            'Confirm the rendered command before inserting it.',
        confirmLabel: 'Insert command',
      );
      if (!shouldInsert) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }
      _followLiveOutput();
      // Insert the command into terminal
      _terminal.paste(result.command);
      // Track usage
      unawaited(snippetRepo.incrementUsage(result.snippetId));
    }
  }

  /// Shows dialog for variable substitution if snippet has variables.
  Future<({String command, bool hadVariableSubstitution})?>
  _substituteVariables(BuildContext context, Snippet snippet) async {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(snippet.command);
    final variables = matches.map((m) => m.group(1)!).toSet().toList();

    if (variables.isEmpty) {
      return (command: snippet.command, hadVariableSubstitution: false);
    }

    final controllers = {for (final v in variables) v: TextEditingController()};
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Variables for "${snippet.name}"'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final variable in variables) ...[
                  TextFormField(
                    controller: controllers[variable],
                    decoration: InputDecoration(
                      labelText: variable,
                      hintText: 'Enter value for $variable',
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a value';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Insert'),
          ),
        ],
      ),
    );

    if (result != true) {
      for (final c in controllers.values) {
        c.dispose();
      }
      return null;
    }

    // Substitute variables
    var command = snippet.command;
    for (final entry in controllers.entries) {
      command = command.replaceAll('{{${entry.key}}}', entry.value.text);
      entry.value.dispose();
    }

    return (command: command, hadVariableSubstitution: true);
  }

  Future<_AutoConnectReviewDecision> _reviewImportedAutoConnectCommand(
    TerminalCommandReview review,
  ) async {
    final decision = await showDialog<_AutoConnectReviewDecision>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review imported auto-connect command'),
        content: _buildCommandReviewContent(
          review: review,
          message:
              'Imported auto-connect commands never run silently. Review this one before letting it execute.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.skip),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.runOnce),
            child: const Text('Run once'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.trustAndRun),
            child: const Text('Always run'),
          ),
        ],
      ),
    );
    return decision ?? _AutoConnectReviewDecision.skip;
  }

  Future<bool> _confirmCommandInsertion({
    required String title,
    required String message,
    required String confirmLabel,
    required TerminalCommandReview review,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: _buildCommandReviewContent(review: review, message: message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Widget _buildCommandReviewContent({
    required TerminalCommandReview review,
    required String message,
  }) {
    final reasons = describeTerminalCommandReview(review);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber_rounded, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(reason)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              review.command,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalStatusChip extends StatelessWidget {
  const _TerminalStatusChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.colorScheme,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
