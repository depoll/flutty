part of '../screens/terminal_screen.dart';

/// Expandable tmux bar shown as a bottom overlay or a wide-layout side rail.
///
/// Bottom overlay collapsed: a slim handle bar sitting over bottom padding in
/// the terminal. Bottom overlay expanded: slides up over the terminal content.
/// Sidebar collapsed: a vertical window switcher rail. Sidebar expanded: a
/// master/detail panel docked beside the terminal.
class _TmuxExpandableBar extends StatefulWidget {
  const _TmuxExpandableBar({
    required this.session,
    required this.tmuxSessionName,
    required this.availableHeight,
    required this.placement,
    required this.recoveryGeneration,
    required this.isProUser,
    required this.startClisInYoloMode,
    required this.initiallyExpanded,
    required this.ref,
    required this.remoteMultiplexerService,
    required this.activeMuxBackend,
    required this.onAction,
    required this.onExpandedChanged,
    required this.onSidebarDragOffsetChanged,
    this.tmuxExtraFlags,
    this.scopeWorkingDirectory,
    this.onWindowsChanged,
    this.onWindowStateChanged,
    this.onActiveWindowTerminalModeChanged,
    this.onWindowLoadStalled,
    this.onSessionEnded,
    super.key,
  });

  /// The active SSH session.
  final SshSession session;

  /// The tmux session name.
  final String tmuxSessionName;

  /// Optional extra flags for tmux commands (e.g. custom socket path).
  final String? tmuxExtraFlags;

  /// The available terminal height the bar can expand into.
  final double availableHeight;

  /// Where the bar is rendered in the terminal layout.
  final TmuxBarPlacement placement;

  /// Forces state recovery when tmux window loading stalls.
  final int recoveryGeneration;

  /// Whether the user has Pro access.
  final bool isProUser;

  /// Whether supported coding CLIs should launch in YOLO mode for this host.
  final bool startClisInYoloMode;

  /// Whether the tmux window list should start expanded.
  final bool initiallyExpanded;

  /// Riverpod ref.
  final WidgetRef ref;

  /// Backend used to load and watch remote windows.
  final RemoteMultiplexerService remoteMultiplexerService;

  /// Active multiplexer backend for backend-specific lifecycle behavior.
  final RemoteMuxBackend activeMuxBackend;

  /// Callback for navigator actions.
  final Future<void> Function(TmuxNavigatorAction) onAction;

  /// Called when the expanded/collapsed state changes.
  final ValueChanged<bool> onExpandedChanged;

  /// Called as the sidebar is dragged horizontally so the parent can resize.
  final ValueChanged<double> onSidebarDragOffsetChanged;

  /// Called whenever the full remote window snapshot changes.
  final ValueChanged<List<TmuxWindow>>? onWindowsChanged;

  final void Function(
    SshSession session,
    String sessionName, {
    required bool activeWindowChanged,
  })?
  onWindowStateChanged;

  /// Called when the active window's terminal-mode metadata changes without the
  /// active window itself changing — for example when the foreground app enters
  /// or leaves mouse or bracketed-paste mode. Lets the parent inherit the active
  /// mux window's local terminal modes without waiting for a window switch.
  final VoidCallback? onActiveWindowTerminalModeChanged;

  final Future<void> Function(SshSession session, String sessionName)?
  onWindowLoadStalled;

  final Future<void> Function(SshSession session, String sessionName)?
  onSessionEnded;

  /// Best-known project working directory for AI session scoping.
  final String? scopeWorkingDirectory;

  /// Height of the collapsed handle bar. The terminal adds this as
  /// bottom padding so the handle sits over empty space.
  static const handleHeight = tmuxHandleMinTouchExtent;

  @override
  State<_TmuxExpandableBar> createState() => _TmuxExpandableBarState();
}

class _TmuxExpandableBarState extends State<_TmuxExpandableBar>
    with SingleTickerProviderStateMixin {
  static const _monkeyMuxHandleIconAsset =
      'assets/icons/monkeyssh_icon_monochrome.png';
  static const _denseTileVisualDensity = VisualDensity(vertical: -2);
  static const _denseTilePadding = EdgeInsets.symmetric(horizontal: 12);
  static const _groupTilePadding = EdgeInsets.only(left: 52, right: 12);
  static const _pendingSelectionTimeout = Duration(seconds: 2);
  static const _sidebarDragStartThreshold = 8.0;

  List<TmuxWindow>? _windows;
  AgentLaunchTool? _preferredLaunchTool;
  final Set<String> _seenAlertWindowKeys = <String>{};
  final Map<String, int> _seenAlertWindowIndexesByKey = <String, int>{};
  late bool _expanded;
  bool _isLoading = true;
  bool _showSessions = false;
  bool _hasInitializedSessionProviders = false;
  double _dragOffset = 0;
  int? _sidebarDragPointer;
  Offset? _sidebarDragStartGlobalPosition;
  Offset? _sidebarDragLastGlobalPosition;
  bool _isSidebarDragActive = false;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
  StreamSubscription<AcpSessionManagerState>? _acpSessionSubscription;
  List<AcpSessionState> _nativeAcpSessions = const <AcpSessionState>[];
  List<AcpRecentSessionRef> _nativeAcpRecents = const <AcpRecentSessionRef>[];
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;
  bool _loadingWindows = false;
  bool _pendingWindowReload = false;
  int _windowReloadGeneration = 0;
  int _windowEventGeneration = 0;
  int? _pendingSelectedWindowIndex;
  Timer? _pendingSelectionTimer;
  Timer? _windowRetryTimer;
  int _windowRetryAttempts = 0;
  int _consecutiveEmptyWindowReloads = 0;
  bool _windowReloadRecoveryRequested = false;
  bool _sessionEndedNotified = false;
  late LocalNotificationService _localNotifications;

  RemoteMultiplexerService get _mux => widget.remoteMultiplexerService;

  bool get _isSidebar => widget.placement == TmuxBarPlacement.sidebar;

  List<TmuxWindow>? get currentWindowsSnapshot => _windows;

  bool get hasPendingWindowSelection => _pendingSelectedWindowIndex != null;

  bool get _emptyWindowListEndsSession =>
      widget.activeMuxBackend == RemoteMuxBackend.monkeyMux;

  bool get _showsExpandedSidebarContent => _expanded || _dragOffset > 0;

  AgentSessionDiscoveryService get _discovery =>
      widget.ref.read(agentSessionDiscoveryServiceProvider);

  List<TmuxWindow>? get _displayedWindows => resolveTmuxBarDisplayedWindows(
    _windows,
    pendingSelectedWindowIndex: _pendingSelectedWindowIndex,
  );

  @override
  void initState() {
    super.initState();
    _localNotifications = widget.ref.read(localNotificationServiceProvider);
    _expanded = widget.initiallyExpanded;
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // A single subtle attention nudge (ease-out up, ease-in settle) — not a
    // springy bounce, per the design system's "no bounce/elastic" rule.
    _bounceAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: -6,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: -6,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 1.4,
      ),
    ]).animate(_bounceController);
    unawaited(_loadPreferredLaunchTool());
    unawaited(
      widget.ref
          .read(tmuxServiceProvider)
          .prefetchInstalledAgentTools(widget.session),
    );
    _loadWindows();
    _subscribeToWindowChanges();
    _subscribeToNativeAcpSessions();
  }

  @override
  void didUpdateWidget(covariant _TmuxExpandableBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged =
        oldWidget.session.connectionId != widget.session.connectionId ||
        oldWidget.tmuxSessionName != widget.tmuxSessionName ||
        oldWidget.tmuxExtraFlags != widget.tmuxExtraFlags;
    final backendChanged =
        oldWidget.activeMuxBackend != widget.activeMuxBackend ||
        oldWidget.remoteMultiplexerService != widget.remoteMultiplexerService;
    final recoveryChanged =
        oldWidget.recoveryGeneration != widget.recoveryGeneration;
    if (!sessionChanged && !backendChanged && !recoveryChanged) {
      return;
    }
    final wasExpanded = _expanded;
    _clearPendingSelectedWindow(notify: false);
    _resetWindowReloadRecovery();
    if (!shouldPreserveTmuxBarSnapshotOnUpdate(
      sessionChanged: sessionChanged,
      backendChanged: backendChanged,
      recoveryChanged: recoveryChanged,
    )) {
      _clearSeenAlertNotifications(
        oldWidget.session,
        oldWidget.tmuxSessionName,
      );
      setState(() {
        _windows = null;
        _isLoading = true;
        _expanded = false;
        _showSessions = false;
        _hasInitializedSessionProviders = false;
        _dragOffset = 0;
      });
      if (wasExpanded) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onExpandedChanged(false);
          }
        });
      }
      unawaited(
        widget.ref
            .read(tmuxServiceProvider)
            .prefetchInstalledAgentTools(widget.session),
      );
    } else if (!(_windows?.isNotEmpty ?? false)) {
      setState(() => _isLoading = true);
    }
    if (sessionChanged || backendChanged) {
      _sessionEndedNotified = false;
      unawaited(_windowChangeSubscription?.cancel());
      _subscribeToWindowChanges();
      _subscribeToNativeAcpSessions();
    }
    unawaited(_loadPreferredLaunchTool());
    _loadWindows();
  }

  @override
  void dispose() {
    _clearPendingSelectedWindow(notify: false);
    _resetWindowReloadRecovery();
    unawaited(_windowChangeSubscription?.cancel());
    unawaited(_acpSessionSubscription?.cancel());
    _clearSeenAlertNotifications(widget.session, widget.tmuxSessionName);
    _bounceController.dispose();
    super.dispose();
  }

  List<AcpSwitcherEntry> get _nativeAcpEntries =>
      widget.activeMuxBackend == RemoteMuxBackend.monkeyMux
      ? buildAcpSwitcherEntries(
          sessions: _nativeAcpSessions,
          recents: _nativeAcpRecents,
        )
      : const <AcpSwitcherEntry>[];

  void _subscribeToNativeAcpSessions() {
    unawaited(_acpSessionSubscription?.cancel());
    _acpSessionSubscription = null;
    if (widget.activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      if (mounted) {
        setState(() {
          _nativeAcpSessions = const <AcpSessionState>[];
          _nativeAcpRecents = const <AcpRecentSessionRef>[];
        });
      }
      return;
    }
    final manager = widget.ref.read(acpSessionManagerProvider);
    final hostId = widget.session.hostId;
    _nativeAcpSessions = manager.state.sessions
        .where((session) => session.key.hostId == hostId)
        .toList(growable: false);
    _acpSessionSubscription = manager.states.listen((state) {
      if (!mounted || widget.session.hostId != hostId) {
        return;
      }
      setState(() {
        _nativeAcpSessions = state.sessions
            .where((session) => session.key.hostId == hostId)
            .toList(growable: false);
      });
    });
    unawaited(_loadNativeAcpRecents(manager, hostId));
  }

  Future<void> _loadNativeAcpRecents(
    AcpSessionManager manager,
    int hostId,
  ) async {
    final recents = await manager.loadNavigableSessions(hostId);
    if (!mounted || widget.session.hostId != hostId) {
      return;
    }
    setState(() => _nativeAcpRecents = recents);
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

  void _subscribeToWindowChanges() {
    final generation = ++_windowEventGeneration;
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'bar_subscribe',
      fields: {
        'connectionId': widget.session.connectionId,
        'generation': generation,
      },
    );
    _windowChangeSubscription = _mux
        .watchWindowChanges(
          widget.session,
          widget.tmuxSessionName,
          extraFlags: widget.tmuxExtraFlags,
        )
        .listen((event) => _handleWindowChangeEvent(event, generation));
  }

  void _handleWindowChangeEvent(TmuxWindowChangeEvent event, int generation) {
    if (!mounted) return;
    if (generation != _windowEventGeneration) return;
    if (event is TmuxWindowReloadEvent) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_reload_event',
        fields: {
          'connectionId': widget.session.connectionId,
          'generation': generation,
        },
      );
      _loadWindows();
      _notifyWindowStateChanged(activeWindowChanged: false);
      return;
    }
    if (event is TmuxWindowListEvent) {
      _windowReloadGeneration += 1;
      _resetWindowReloadRecovery();
      if (event.windows.isEmpty && _emptyWindowListEndsSession) {
        _applyWindows(const <TmuxWindow>[]);
        _notifySessionEnded();
        return;
      }
      final currentWindows = _windows;
      final windows = currentWindows == null
          ? event.windows
          : applyTmuxWindowChangeEvent(currentWindows, event);
      final shouldNotifyWindowStateChanged =
          currentWindows == null ||
          _shouldRefreshTmuxThemeAfterWindowChange(currentWindows, windows);
      final activeWindowChanged =
          currentWindows != null &&
          _didDisplayedTmuxWindowChange(currentWindows, windows);
      _applyWindows(windows);
      if (shouldNotifyWindowStateChanged) {
        _notifyWindowStateChanged(activeWindowChanged: activeWindowChanged);
      }
      return;
    }
    final currentWindows = _windows;
    if (currentWindows == null) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_snapshot_without_state',
        fields: {'connectionId': widget.session.connectionId},
      );
      _loadWindows();
      return;
    }
    _windowReloadGeneration += 1;
    _resetWindowReloadRecovery();
    final windows = applyTmuxWindowChangeEvent(currentWindows, event);
    final shouldNotifyWindowStateChanged =
        _shouldRefreshTmuxThemeAfterWindowChange(currentWindows, windows);
    final activeWindowChanged = _didDisplayedTmuxWindowChange(
      currentWindows,
      windows,
    );
    DiagnosticsLogService.instance.debug(
      'tmux.ui',
      'bar_snapshot_applied',
      fields: {
        'connectionId': widget.session.connectionId,
        'windowCount': windows.length,
        'themeRefreshNeeded': shouldNotifyWindowStateChanged,
      },
    );
    _applyWindows(windows);
    if (shouldNotifyWindowStateChanged) {
      _notifyWindowStateChanged(activeWindowChanged: activeWindowChanged);
    }
  }

  void _notifyWindowStateChanged({required bool activeWindowChanged}) {
    widget.onWindowStateChanged?.call(
      widget.session,
      widget.tmuxSessionName,
      activeWindowChanged: activeWindowChanged,
    );
  }

  bool _didDisplayedTmuxWindowChange(
    List<TmuxWindow> previousWindows,
    List<TmuxWindow> nextWindows,
  ) =>
      _displayedTmuxWindowContext(previousWindows) !=
      _displayedTmuxWindowContext(nextWindows);

  ({String key, int? panePid})? _displayedTmuxWindowContext(
    List<TmuxWindow> windows,
  ) {
    final activeWindow = windows.where((window) => window.isActive).firstOrNull;
    if (activeWindow == null) {
      return null;
    }
    return (
      key: activeWindow.id ?? '#${activeWindow.index}',
      panePid: activeWindow.panePid,
    );
  }

  bool _shouldRefreshTmuxThemeAfterWindowChange(
    List<TmuxWindow> previousWindows,
    List<TmuxWindow> nextWindows,
  ) {
    if (previousWindows.length != nextWindows.length) {
      return true;
    }
    for (final nextWindow in nextWindows) {
      final previousWindow = previousWindows
          .where(
            (window) => _isSameTmuxWindowForThemeRefresh(window, nextWindow),
          )
          .firstOrNull;
      if (previousWindow == null ||
          _tmuxWindowRefreshIdentity(previousWindow) !=
              _tmuxWindowRefreshIdentity(nextWindow)) {
        return true;
      }
    }
    return false;
  }

  bool _isSameTmuxWindowForThemeRefresh(
    TmuxWindow previousWindow,
    TmuxWindow nextWindow,
  ) {
    final nextId = nextWindow.id;
    if (nextId != null) {
      return previousWindow.id == nextId;
    }
    return previousWindow.index == nextWindow.index;
  }

  ({
    String? currentCommand,
    AgentLaunchTool? foregroundAgentTool,
    String? id,
    int index,
    bool isActive,
    int? panePid,
    String? paneStartCommand,
  })
  _tmuxWindowRefreshIdentity(TmuxWindow window) => (
    currentCommand: window.currentCommand,
    foregroundAgentTool: window.foregroundAgentTool,
    id: window.id,
    index: window.index,
    isActive: window.isActive,
    panePid: window.panePid,
    paneStartCommand: window.paneStartCommand,
  );

  void _applyWindows(List<TmuxWindow> windows) {
    final previousTerminalModeSignature = activeTmuxWindowTerminalModeSignature(
      _windows,
    );
    // Detect new alerts that weren't in the previous window list.
    final newAlerts = windows.where(
      (w) =>
          w.hasAlert &&
          !w.isActive &&
          !_seenAlertWindowKeys.contains(_tmuxAlertWindowKey(w)),
    );
    if (newAlerts.isNotEmpty) {
      final reduceMotion =
          !mounted || (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
      if (!reduceMotion) {
        unawaited(_bounceController.forward(from: 0));
      }
      for (final w in newAlerts) {
        final windowKey = _tmuxAlertWindowKey(w);
        _seenAlertWindowKeys.add(windowKey);
        _seenAlertWindowIndexesByKey[windowKey] = w.index;
        _sendAlertNotification(w, windows);
      }
    }

    final activeAlerts = _seenAlertWindowKeys
        .where(
          (key) => windows.any(
            (w) => _tmuxAlertWindowKey(w) == key && w.hasAlert && w.isActive,
          ),
        )
        .toList(growable: false);
    for (final windowKey in activeAlerts) {
      _clearAlertNotification(windowKey);
    }

    final clearedAlerts = _seenAlertWindowKeys
        .where(
          (key) =>
              !windows.any((w) => _tmuxAlertWindowKey(w) == key && w.hasAlert),
        )
        .toList(growable: false);
    for (final windowKey in clearedAlerts) {
      _clearAlertNotification(windowKey);
      _seenAlertWindowKeys.remove(windowKey);
      _seenAlertWindowIndexesByKey.remove(windowKey);
    }

    final nextPendingSelectedWindowIndex =
        resolveTmuxBarPendingSelectedWindowIndex(
          windows,
          pendingSelectedWindowIndex: _pendingSelectedWindowIndex,
        );
    if (_pendingSelectedWindowIndex != null &&
        nextPendingSelectedWindowIndex == null) {
      _pendingSelectionTimer?.cancel();
      _pendingSelectionTimer = null;
    }

    setState(() {
      _windows = windows;
      _isLoading = false;
      _pendingSelectedWindowIndex = nextPendingSelectedWindowIndex;
    });
    widget.onWindowsChanged?.call(windows);

    // Terminal-mode toggles arrive as `window_updated` events that don't change
    // the active window or its theme identity, so they wouldn't otherwise
    // notify the parent. Surface them explicitly so local mode state stays in
    // sync and touch-scroll routing doesn't get stuck until the next switch.
    if (activeTmuxWindowTerminalModeSignature(windows) !=
        previousTerminalModeSignature) {
      widget.onActiveWindowTerminalModeChanged?.call();
    }
  }

  void _startPendingSelectionTimer(int windowIndex) {
    _pendingSelectionTimer?.cancel();
    _pendingSelectionTimer = Timer(_pendingSelectionTimeout, () {
      _pendingSelectionTimer = null;
      if (!mounted || _pendingSelectedWindowIndex != windowIndex) {
        return;
      }
      setState(() => _pendingSelectedWindowIndex = null);
    });
  }

  void _clearPendingSelectedWindow({required bool notify}) {
    _pendingSelectionTimer?.cancel();
    _pendingSelectionTimer = null;
    if (_pendingSelectedWindowIndex == null) {
      return;
    }
    if (!notify || !mounted) {
      _pendingSelectedWindowIndex = null;
      return;
    }
    setState(() => _pendingSelectedWindowIndex = null);
  }

  void _cancelWindowRetry() {
    _windowRetryTimer?.cancel();
    _windowRetryTimer = null;
  }

  void _resetWindowReloadRecovery() {
    _cancelWindowRetry();
    _windowRetryAttempts = 0;
    _consecutiveEmptyWindowReloads = 0;
    _windowReloadRecoveryRequested = false;
  }

  void _scheduleWindowRetry() {
    if (!mounted || (_windowRetryTimer?.isActive ?? false)) {
      return;
    }
    final delay = resolveTmuxWindowReloadRetryDelay(_windowRetryAttempts);
    _windowRetryAttempts += 1;
    DiagnosticsLogService.instance.warning(
      'tmux.ui',
      'bar_retry_scheduled',
      fields: {
        'connectionId': widget.session.connectionId,
        'attempt': _windowRetryAttempts,
        'delayMs': delay.inMilliseconds,
      },
    );
    _windowRetryTimer = Timer(delay, () {
      _windowRetryTimer = null;
      if (mounted) {
        unawaited(_loadWindows());
      }
    });
  }

  bool get _shouldRequestWindowReloadRecovery =>
      !(_windows?.isNotEmpty ?? false) && _windowRetryAttempts >= 1;

  void _requestWindowReloadRecovery() {
    if (_windowReloadRecoveryRequested) {
      return;
    }
    _windowReloadRecoveryRequested = true;
    DiagnosticsLogService.instance.warning(
      'tmux.ui',
      'bar_recovery_requested',
      fields: {'connectionId': widget.session.connectionId},
    );
    final onWindowLoadStalled = widget.onWindowLoadStalled;
    if (onWindowLoadStalled != null) {
      unawaited(onWindowLoadStalled(widget.session, widget.tmuxSessionName));
    }
  }

  void _notifySessionEnded() {
    if (_sessionEndedNotified) {
      return;
    }
    _sessionEndedNotified = true;
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'mux_session_ended',
      fields: {
        'connectionId': widget.session.connectionId,
        'backend': widget.activeMuxBackend.storageValue,
      },
    );
    final onSessionEnded = widget.onSessionEnded;
    if (onSessionEnded != null) {
      unawaited(onSessionEnded(widget.session, widget.tmuxSessionName));
    }
  }

  bool collapseIfExpanded() {
    if (!_expanded) {
      return false;
    }
    setState(() {
      _expanded = false;
      _dragOffset = 0;
    });
    widget.onExpandedChanged(false);
    return true;
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

  Future<void> _loadWindows() async {
    if (_loadingWindows) {
      _pendingWindowReload = true;
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_reload_queued',
        fields: {'connectionId': widget.session.connectionId},
      );
      return;
    }
    _loadingWindows = true;
    final reloadGeneration = ++_windowReloadGeneration;
    DiagnosticsLogService.instance.debug(
      'tmux.ui',
      'bar_reload_start',
      fields: {
        'connectionId': widget.session.connectionId,
        'generation': reloadGeneration,
      },
    );
    try {
      final reloadedWindows = await _mux.listWindows(
        widget.session,
        widget.tmuxSessionName,
        extraFlags: widget.tmuxExtraFlags,
      );
      if (!mounted) return;
      if (reloadGeneration < _windowReloadGeneration) return;
      final isEmptyReload = reloadedWindows.isEmpty;
      if (isEmptyReload) {
        _consecutiveEmptyWindowReloads += 1;
      } else {
        _resetWindowReloadRecovery();
      }
      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'bar_reload_result',
        fields: {
          'connectionId': widget.session.connectionId,
          'generation': reloadGeneration,
          'windowCount': reloadedWindows.length,
          'consecutiveEmptyReloads': _consecutiveEmptyWindowReloads,
        },
      );
      if (isEmptyReload && _emptyWindowListEndsSession) {
        _applyWindows(const <TmuxWindow>[]);
        _notifySessionEnded();
        return;
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
        DiagnosticsLogService.instance.warning(
          'tmux.ui',
          'bar_reload_preserved_previous',
          fields: {
            'connectionId': widget.session.connectionId,
            'generation': reloadGeneration,
          },
        );
        final shouldRecover = _shouldRequestWindowReloadRecovery;
        _scheduleWindowRetry();
        if (shouldRecover) {
          final wasExpanded = _expanded;
          setState(() {
            _expanded = false;
            _isLoading = false;
          });
          if (wasExpanded) {
            widget.onExpandedChanged(false);
          }
          _requestWindowReloadRecovery();
        } else if (_windows != null || !_isLoading) {
          setState(() {
            _windows = null;
            _isLoading = true;
          });
        }
        return;
      }
      if (isEmptyReload) {
        _scheduleWindowRetry();
      } else {
        _resetWindowReloadRecovery();
      }
      _applyWindows(windows);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'bar_reload_failed',
        fields: {
          'connectionId': widget.session.connectionId,
          'generation': reloadGeneration,
          'errorType': error.runtimeType,
        },
      );
      if (!mounted) return;
      final shouldRecover = _shouldRequestWindowReloadRecovery;
      _scheduleWindowRetry();
      if (_windows?.isNotEmpty ?? false) {
        if (_isLoading) {
          setState(() => _isLoading = false);
        }
      } else if (shouldRecover) {
        final wasExpanded = _expanded;
        setState(() {
          _expanded = false;
          _isLoading = false;
        });
        if (wasExpanded) {
          widget.onExpandedChanged(false);
        }
        _requestWindowReloadRecovery();
      } else {
        setState(() => _isLoading = true);
      }
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
    final command = discovery.buildResumeCommand(
      info,
      startInYoloMode: widget.startClisInYoloMode,
    );
    final wasExpanded = _expanded;
    setState(() => _expanded = false);
    if (wasExpanded) {
      widget.onExpandedChanged(false);
    }
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

  Future<void> _showNewWindowPicker({BuildContext? anchorContext}) async {
    final installedToolsFuture = widget.ref
        .read(tmuxServiceProvider)
        .detectInstalledAgentTools(widget.session);
    final nativeAcpAvailable =
        widget.activeMuxBackend == RemoteMuxBackend.monkeyMux;
    final nativeAcpProviderIds = nativeAcpAvailable
        ? builtinNativeAcpProvidersByTool()
        : const <AgentLaunchTool, String>{};
    if (!mounted || (anchorContext != null && !anchorContext.mounted)) {
      return;
    }
    final usesTerminalOnlyContextMenu =
        _isSidebar &&
        anchorContext != null &&
        widget.activeMuxBackend != RemoteMuxBackend.monkeyMux;
    final action = usesTerminalOnlyContextMenu
        ? await showTmuxNewWindowContextMenu(
            context: context,
            anchorContext: anchorContext,
            isProUser: widget.isProUser,
            startClisInYoloMode: widget.startClisInYoloMode,
            installedToolsFuture: installedToolsFuture,
            preferredTool: _preferredLaunchTool,
          )
        : await showTmuxNewWindowPicker(
            context: context,
            isProUser: widget.isProUser,
            startClisInYoloMode: widget.startClisInYoloMode,
            installedToolsFuture: installedToolsFuture,
            preferredTool: _preferredLaunchTool,
            nativeAcpProviderIds: nativeAcpProviderIds,
            allowNativeAcpProviderPicker: nativeAcpAvailable,
          );
    if (!mounted || action == null) {
      return;
    }
    final scopedAction = switch (action) {
      TmuxNewAcpSessionAction(:final providerId) => TmuxNewAcpSessionAction(
        providerId: providerId,
        workingDirectory: widget.scopeWorkingDirectory,
      ),
      _ => action,
    };
    await widget.onAction(scopedAction);
  }

  int _tmuxAlertNotificationId(
    SshSession session,
    String tmuxSessionName,
    String windowKey,
  ) =>
      Object.hash(
        session.hostId,
        session.connectionId,
        tmuxSessionName,
        windowKey,
      ) &
      0x7fffffff;

  int _legacyTmuxAlertNotificationId(
    SshSession session,
    String tmuxSessionName,
    int windowIndex,
  ) =>
      Object.hash(
        session.hostId,
        session.connectionId,
        tmuxSessionName,
        windowIndex,
      ) &
      0x7fffffff;

  Set<int> _tmuxAlertIndexNotificationIds(
    SshSession session,
    String tmuxSessionName,
    int windowIndex,
  ) => {
    _legacyTmuxAlertNotificationId(session, tmuxSessionName, windowIndex),
    _tmuxAlertNotificationId(
      session,
      tmuxSessionName,
      _tmuxAlertIndexWindowKey(windowIndex),
    ),
  };

  Set<int> _tmuxAlertNotificationIdsForWindowKey(
    SshSession session,
    String tmuxSessionName,
    String windowKey,
  ) {
    final notificationIds = <int>{};
    if (isValidTmuxWindowId(windowKey)) {
      notificationIds.add(
        _tmuxAlertNotificationId(session, tmuxSessionName, windowKey),
      );
    }
    final legacyWindowIndex = _tmuxAlertLegacyWindowIndex(windowKey);
    if (legacyWindowIndex != null) {
      notificationIds.addAll(
        _tmuxAlertIndexNotificationIds(
          session,
          tmuxSessionName,
          legacyWindowIndex,
        ),
      );
    }
    return notificationIds;
  }

  int? _tmuxAlertLegacyWindowIndex(String windowKey) {
    const legacyPrefix = 'index:';
    if (windowKey.startsWith(legacyPrefix)) {
      return int.tryParse(windowKey.substring(legacyPrefix.length));
    }
    return _seenAlertWindowIndexesByKey[windowKey];
  }

  String _tmuxAlertIndexWindowKey(int windowIndex) => 'index:$windowIndex';

  String _tmuxAlertWindowKey(TmuxWindow window) =>
      window.id != null && isValidTmuxWindowId(window.id!)
      ? window.id!
      : _tmuxAlertIndexWindowKey(window.index);

  void _sendAlertNotification(TmuxWindow window, List<TmuxWindow> windows) {
    final content = resolveTmuxAlertNotificationContent(
      tmuxSessionName: widget.tmuxSessionName,
      window: window,
      windows: windows,
    );
    final windowId = window.id;
    final stableWindowId = windowId != null && isValidTmuxWindowId(windowId)
        ? windowId
        : null;
    final session = widget.session;
    final tmuxSessionName = widget.tmuxSessionName;
    final windowIndex = window.index;
    final notificationId = stableWindowId != null
        ? _tmuxAlertNotificationId(session, tmuxSessionName, stableWindowId)
        : _legacyTmuxAlertNotificationId(session, tmuxSessionName, windowIndex);
    final obsoleteNotificationIds = _tmuxAlertIndexNotificationIds(
      session,
      tmuxSessionName,
      windowIndex,
    )..remove(notificationId);
    final payload = TmuxAlertNotificationPayload(
      hostId: session.hostId,
      connectionId: session.connectionId,
      tmuxSessionName: tmuxSessionName,
      windowIndex: windowIndex,
      windowId: stableWindowId,
    );
    unawaited(HapticFeedback.mediumImpact());
    unawaited(() async {
      for (final obsoleteNotificationId in obsoleteNotificationIds) {
        await _localNotifications.clearTmuxAlert(obsoleteNotificationId);
      }
      await _localNotifications.showTmuxAlert(
        notificationId: notificationId,
        title: content.title,
        body: content.body,
        payload: payload,
      );
    }());
  }

  void _clearAlertNotification(String windowKey) {
    for (final notificationId in _tmuxAlertNotificationIdsForWindowKey(
      widget.session,
      widget.tmuxSessionName,
      windowKey,
    )) {
      unawaited(_localNotifications.clearTmuxAlert(notificationId));
    }
  }

  void _clearAlertNotificationFor(
    SshSession session,
    String tmuxSessionName,
    String windowKey,
  ) {
    for (final notificationId in _tmuxAlertNotificationIdsForWindowKey(
      session,
      tmuxSessionName,
      windowKey,
    )) {
      unawaited(_localNotifications.clearTmuxAlert(notificationId));
    }
  }

  void _clearSeenAlertNotifications(
    SshSession session,
    String tmuxSessionName,
  ) {
    for (final windowKey in _seenAlertWindowKeys) {
      _clearAlertNotificationFor(session, tmuxSessionName, windowKey);
    }
    _seenAlertWindowKeys.clear();
    _seenAlertWindowIndexesByKey.clear();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_isSidebar) {
      return;
    }
    setState(() {
      _dragOffset += _expanded ? details.delta.dy : -details.delta.dy;
      _dragOffset = _dragOffset.clamp(0.0, 300.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_isSidebar) {
      return;
    }
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
    if (shouldExpand) {
      widget.onExpandedChanged(true);
    } else if (shouldCollapse) {
      widget.onExpandedChanged(false);
    }
    if (shouldExpand) _loadWindows();
  }

  void _applySidebarDragDelta(double deltaX) {
    const maxDrag = tmuxSidebarExpandedWidth - tmuxSidebarCollapsedWidth;
    final nextDragOffset = (_dragOffset + deltaX).clamp(
      _expanded ? -maxDrag : 0.0,
      _expanded ? 0.0 : maxDrag,
    );
    if (nextDragOffset == _dragOffset) {
      return;
    }
    setState(() => _dragOffset = nextDragOffset);
    widget.onSidebarDragOffsetChanged(nextDragOffset);
  }

  void _finishSidebarDrag(double velocity) {
    final shouldExpand =
        !_expanded &&
        (velocity > 200 || _dragOffset > tmuxSidebarDragThreshold);
    final shouldCollapse =
        _expanded &&
        (velocity < -200 || _dragOffset < -tmuxSidebarDragThreshold);
    setState(() {
      if (shouldExpand) {
        _expanded = true;
      } else if (shouldCollapse) {
        _expanded = false;
      }
      _dragOffset = 0;
    });
    widget.onSidebarDragOffsetChanged(0);
    if (shouldExpand) {
      widget.onExpandedChanged(true);
      _loadWindows();
    } else if (shouldCollapse) {
      widget.onExpandedChanged(false);
    }
  }

  void _onHorizontalDragCancel() {
    if (!_isSidebar || _dragOffset == 0) {
      return;
    }
    setState(() => _dragOffset = 0);
    widget.onSidebarDragOffsetChanged(0);
  }

  void _onSidebarPointerDown(PointerDownEvent event) {
    if (!_isSidebar || _sidebarDragPointer != null) {
      return;
    }
    _sidebarDragPointer = event.pointer;
    _sidebarDragStartGlobalPosition = event.position;
    _sidebarDragLastGlobalPosition = event.position;
    _isSidebarDragActive = false;
  }

  void _onSidebarPointerMove(PointerMoveEvent event) {
    final start = _sidebarDragStartGlobalPosition;
    final last = _sidebarDragLastGlobalPosition;
    if (!_isSidebar ||
        _sidebarDragPointer != event.pointer ||
        start == null ||
        last == null) {
      return;
    }
    final totalDelta = event.position - start;
    if (!_isSidebarDragActive) {
      if (totalDelta.dx.abs() < _sidebarDragStartThreshold &&
          totalDelta.dy.abs() < _sidebarDragStartThreshold) {
        _sidebarDragLastGlobalPosition = event.position;
        return;
      }
      if (totalDelta.dx.abs() <= totalDelta.dy.abs()) {
        _sidebarDragLastGlobalPosition = event.position;
        return;
      }
      _isSidebarDragActive = true;
    }

    final deltaX = event.position.dx - last.dx;
    _sidebarDragLastGlobalPosition = event.position;
    if (deltaX == 0) {
      return;
    }
    _applySidebarDragDelta(deltaX);
  }

  void _onSidebarPointerUp(PointerUpEvent event) {
    if (!_isSidebar || _sidebarDragPointer != event.pointer) {
      return;
    }
    final shouldFinishDrag = _isSidebarDragActive || _dragOffset != 0;
    _resetSidebarPointerDrag();
    if (shouldFinishDrag) {
      _finishSidebarDrag(0);
    }
  }

  void _onSidebarPointerCancel(PointerCancelEvent event) {
    if (_sidebarDragPointer != event.pointer) {
      return;
    }
    final shouldCancelDrag = _isSidebarDragActive || _dragOffset != 0;
    _resetSidebarPointerDrag();
    if (shouldCancelDrag) {
      _onHorizontalDragCancel();
    }
  }

  void _resetSidebarPointerDrag() {
    _sidebarDragPointer = null;
    _sidebarDragStartGlobalPosition = null;
    _sidebarDragLastGlobalPosition = null;
    _isSidebarDragActive = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_isSidebar) {
      return _buildSidebar(context);
    }

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
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: DecoratedBox(
            decoration: BoxDecoration(
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
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onSidebarPointerDown,
      onPointerMove: _onSidebarPointerMove,
      onPointerUp: _onSidebarPointerUp,
      onPointerCancel: _onSidebarPointerCancel,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            children: [
              _buildSidebarHandle(theme),
              if (_showsExpandedSidebarContent)
                Expanded(child: _buildWindowList(theme))
              else
                Expanded(child: _buildCollapsedSidebarWindowRail(theme)),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleExpanded() {
    final wasExpanded = _expanded;
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged(!wasExpanded);
    // Refresh window list when expanding to get current active state.
    if (!wasExpanded) {
      _loadWindows();
    }
  }

  Widget _buildHandleBar(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    final handleLabel = resolveTmuxBarHandleLabel(
      widget.tmuxSessionName,
      activeWindowTitle: resolveTmuxBarActiveWindowTitle(displayedWindows),
    );
    final activeWindowTool = resolveTmuxBarActiveWindowTool(displayedWindows);
    final tooltip = _expanded
        ? 'Collapse tmux windows'
        : 'Show tmux windows: $handleLabel';

    return Semantics(
      button: true,
      toggled: _expanded,
      label: 'tmux windows: $handleLabel',
      hint: _expanded
          ? 'Double tap to collapse the tmux window list'
          : 'Double tap to show tmux windows',
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          key: const ValueKey('tmux-handle-bar'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleExpanded,
          child: SizedBox(
            height: _TmuxExpandableBar.handleHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _buildHandleIcon(theme, activeWindowTool),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      handleLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(110),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const SizedBox(width: 28, height: 4),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 300),
                    turns: _expanded ? 0.5 : 0,
                    child: Icon(
                      Icons.keyboard_arrow_up,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarHandle(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    final handleLabel = resolveTmuxBarHandleLabel(
      widget.tmuxSessionName,
      activeWindowTitle: resolveTmuxBarActiveWindowTitle(displayedWindows),
    );
    final activeWindowTool = resolveTmuxBarActiveWindowTool(displayedWindows);
    final tooltip = _expanded
        ? 'Collapse tmux windows'
        : 'Show tmux windows: $handleLabel';
    final icon = _buildHandleIcon(theme, activeWindowTool);

    return Semantics(
      button: true,
      toggled: _expanded,
      label: 'tmux windows: $handleLabel',
      hint: _expanded
          ? 'Double tap or drag left to collapse the tmux window sidebar'
          : 'Double tap or drag right to show tmux windows',
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          key: const ValueKey('tmux-handle-bar'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleExpanded,
          child: SizedBox(
            height: 56,
            width: double.infinity,
            child: _showsExpandedSidebarContent
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        icon,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            handleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_left,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  )
                : Center(child: icon),
          ),
        ),
      ),
    );
  }

  Widget _buildHandleIcon(ThemeData theme, AgentLaunchTool? activeWindowTool) {
    final color = theme.colorScheme.primary;
    if (activeWindowTool != null) {
      return AgentToolIcon(tool: activeWindowTool, size: 16, color: color);
    }
    if (widget.activeMuxBackend == RemoteMuxBackend.monkeyMux) {
      return ImageIcon(
        const AssetImage(_monkeyMuxHandleIconAsset),
        key: const ValueKey('monkeymux-handle-icon'),
        size: 16,
        color: color,
      );
    }
    return Icon(Icons.window_outlined, size: 16, color: color);
  }

  Widget _buildCollapsedSidebarWindowRail(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator.adaptive(strokeWidth: 2),
        ),
      );
    }

    final nativeEntries = _nativeAcpEntries;
    if ((displayedWindows == null || displayedWindows.isEmpty) &&
        nativeEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final window in displayedWindows ?? const <TmuxWindow>[])
            _buildCollapsedSidebarWindowButton(theme, window),
          for (final entry in nativeEntries)
            _buildCollapsedNativeAcpButton(theme, entry),
          const SizedBox(height: 4),
          _buildCollapsedSidebarNewWindowButton(theme),
        ],
      ),
    );
  }

  Widget _buildCollapsedSidebarWindowButton(
    ThemeData theme,
    TmuxWindow window,
  ) {
    final isActive = window.isActive;
    final progress = widget.activeMuxBackend == RemoteMuxBackend.monkeyMux
        ? window.terminalProgress
        : null;
    final title = _redactStoreScreenshotIdentities
        ? _storeScreenshotWindowTitle(window)
        : window.displayTitle;
    final iconColor = isActive
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Tooltip(
        message: 'Switch to $title',
        child: Semantics(
          button: true,
          selected: isActive,
          label: 'tmux window ${window.index}: $title',
          child: InkWell(
            key: ValueKey('tmux-sidebar-window-${window.index}'),
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: isActive
                ? null
                : () {
                    setState(() {
                      _pendingSelectedWindowIndex = window.index;
                    });
                    _startPendingSelectionTimer(window.index);
                    unawaited(
                      widget.onAction(TmuxSwitchWindowAction(window.index)),
                    );
                  },
            child: Ink(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isActive
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHigh,
                border: window.hasAlert
                    ? Border.all(color: theme.colorScheme.error, width: 2)
                    : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    AgentToolIcon(
                      tool: window.foregroundAgentTool,
                      color: iconColor,
                      fallbackIcon: Icons.terminal,
                    ),
                    Positioned(
                      right: -9,
                      bottom: -9,
                      child: _buildCollapsedSidebarWindowIndex(
                        theme,
                        window,
                        isActive: isActive,
                      ),
                    ),
                    if (window.hasAlert)
                      Positioned(
                        right: -10,
                        top: -10,
                        child: Icon(
                          Icons.notifications_active,
                          size: 14,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    if (progress != null)
                      Positioned(
                        left: -7,
                        right: 7,
                        bottom: -11,
                        child: _MuxWindowProgressIndicator(
                          key: ValueKey(
                            'monkeymux-sidebar-progress-${window.index}',
                          ),
                          progress: progress,
                          semanticsWindowLabel: isActive
                              ? null
                              : 'MonkeyMux window ${window.index}: $title',
                          compact: true,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebarWindowIndex(
    ThemeData theme,
    TmuxWindow window, {
    required bool isActive,
  }) {
    final colorScheme = theme.colorScheme;
    return DecoratedBox(
      key: ValueKey('tmux-sidebar-window-index-${window.index}'),
      decoration: BoxDecoration(
        color: isActive
            ? colorScheme.primary
            : colorScheme.surfaceContainerHigh,
        border: Border.all(
          color: theme.colorScheme.surfaceContainerHighest,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          '${window.index}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: isActive
                ? colorScheme.onPrimary
                : colorScheme.onSurfaceVariant,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebarNewWindowButton(ThemeData theme) => Builder(
    builder: (buttonContext) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Tooltip(
        message: 'New Window',
        child: Semantics(
          button: true,
          label: 'New tmux window',
          child: InkWell(
            key: const ValueKey('tmux-sidebar-new-window'),
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: () =>
                unawaited(_showNewWindowPicker(anchorContext: buttonContext)),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.add_circle_outline,
                size: 22,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildWindowList(ThemeData theme) {
    final displayedWindows = _displayedWindows;
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

    final nativeEntries = _nativeAcpEntries;
    if ((displayedWindows == null || displayedWindows.isEmpty) &&
        nativeEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          for (final window in displayedWindows ?? const <TmuxWindow>[])
            _buildWindowTile(theme, window),
          for (final entry in nativeEntries) _buildNativeAcpTile(theme, entry),
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
              final wasExpanded = _expanded;
              setState(() => _expanded = false);
              if (wasExpanded) {
                widget.onExpandedChanged(false);
              }
              unawaited(_showNewWindowPicker());
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
            loadSessions: (maxSessions) => _discovery.discoverSessionsStream(
              widget.session,
              workingDirectory: _resolveRecentSessionScopeWorkingDirectory(),
              maxPerTool: maxSessions,
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
      leading: AgentToolIcon(
        toolName: provider.toolName,
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

  AgentLaunchTool? _nativeAcpTool(AcpSessionKey key) =>
      switch (key.providerId) {
        AcpBuiltinProviderIds.copilotCli => AgentLaunchTool.copilotCli,
        AcpBuiltinProviderIds.openCode => AgentLaunchTool.openCode,
        AcpBuiltinProviderIds.pi => AgentLaunchTool.pi,
        _ => null,
      };

  Widget _buildCollapsedNativeAcpButton(
    ThemeData theme,
    AcpSwitcherEntry entry,
  ) {
    final key = entry.session?.key ?? entry.recent!.key;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Tooltip(
        message: 'Open ${entry.title}',
        child: InkWell(
          key: ValueKey('monkeymux-sidebar-acp-${key.value}'),
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onTap: () =>
              unawaited(widget.onAction(TmuxOpenAcpSessionAction(key))),
          child: Ink(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: AgentToolIcon(
                tool: _nativeAcpTool(key),
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNativeAcpTile(ThemeData theme, AcpSwitcherEntry entry) {
    final session = entry.session;
    final recent = entry.recent;
    final key = session?.key ?? recent!.key;
    final status = session == null ? null : acpStatusDisplay(session.status);
    final statusColor = status == null
        ? theme.colorScheme.onSurfaceVariant
        : acpStatusColor(theme.colorScheme, status.tone);
    return ListTile(
      key: ValueKey('monkeymux-acp-${key.value}'),
      dense: true,
      minTileHeight: 44,
      contentPadding: const EdgeInsets.only(left: 12, right: 8),
      horizontalTitleGap: 10,
      leading: AgentToolIcon(
        tool: _nativeAcpTool(key),
        size: 18,
        color: statusColor,
      ),
      title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${acpCwdSummary(session?.cwd ?? recent?.cwd)} · '
        '${status?.label ?? 'recent'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
      ),
      trailing: const Icon(Icons.chat_bubble_outline, size: 16),
      onTap: () => unawaited(widget.onAction(TmuxOpenAcpSessionAction(key))),
    );
  }

  Widget _buildWindowTile(ThemeData theme, TmuxWindow window) {
    final isActive = window.isActive;
    final title = _redactStoreScreenshotIdentities
        ? _storeScreenshotWindowTitle(window)
        : window.displayTitle;
    final secondaryTitle = _redactStoreScreenshotIdentities
        ? null
        : window.secondaryTitle;
    final iconColor = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final progress = widget.activeMuxBackend == RemoteMuxBackend.monkeyMux
        ? window.terminalProgress
        : null;

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
              title,
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
      subtitle: secondaryTitle == null && progress == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (secondaryTitle != null)
                  Text(
                    secondaryTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (progress != null) ...[
                  if (secondaryTitle != null) const SizedBox(height: 3),
                  _MuxWindowProgressIndicator(
                    key: ValueKey('monkeymux-window-progress-${window.index}'),
                    progress: progress,
                    semanticsWindowLabel: isActive
                        ? null
                        : 'MonkeyMux window ${window.index}: $title',
                  ),
                ],
              ],
            ),
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
                if (_pendingSelectedWindowIndex == window.index) {
                  _pendingSelectedWindowIndex = null;
                  _pendingSelectionTimer?.cancel();
                  _pendingSelectionTimer = null;
                }
              });
            },
          ),
        ],
      ),
      onTap: isActive
          ? () {
              final wasExpanded = _expanded;
              setState(() => _expanded = false);
              if (wasExpanded) {
                widget.onExpandedChanged(false);
              }
            }
          : () {
              setState(() {
                _pendingSelectedWindowIndex = window.index;
                _expanded = false;
              });
              widget.onExpandedChanged(false);
              _startPendingSelectionTimer(window.index);
              unawaited(widget.onAction(TmuxSwitchWindowAction(window.index)));
            },
    );
  }
}

class _MuxWindowProgressIndicator extends StatelessWidget {
  const _MuxWindowProgressIndicator({
    required this.progress,
    required this.semanticsWindowLabel,
    this.compact = false,
    super.key,
  });

  final TerminalProgress progress;
  final String? semanticsWindowLabel;
  final bool compact;

  String get _progressLabel => switch (progress.state) {
    TerminalProgressState.normal => 'progress',
    TerminalProgressState.error => 'progress, error',
    TerminalProgressState.indeterminate => 'progress, indeterminate',
    TerminalProgressState.pausedOrWarning => 'progress, paused or warning',
  };

  Color _color(ColorScheme colorScheme) => switch (progress.state) {
    TerminalProgressState.normal ||
    TerminalProgressState.indeterminate => colorScheme.primary,
    TerminalProgressState.error => colorScheme.error,
    TerminalProgressState.pausedOrWarning => colorScheme.tertiary,
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final percentage = progress.percentage;
    final hasPercentage = percentage != null;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final indicatorValue = hasPercentage
        ? progress.fraction
        : (disableAnimations ? 0.5 : null);

    final indicator = ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: indicatorValue,
          minHeight: compact ? 2 : 3,
          color: _color(colorScheme),
          backgroundColor: colorScheme.surfaceContainerHighest,
        ),
      ),
    );
    final windowLabel = semanticsWindowLabel;
    if (windowLabel == null) {
      return indicator;
    }
    return Semantics(
      label: '$windowLabel, $_progressLabel',
      value: hasPercentage ? '$percentage' : null,
      minValue: hasPercentage ? '0' : null,
      maxValue: hasPercentage ? '100' : null,
      role: hasPercentage
          ? SemanticsRole.progressBar
          : SemanticsRole.loadingSpinner,
      child: indicator,
    );
  }
}

/// Store-safe window title that brands by detected agent without private names.
String _storeScreenshotWindowTitle(TmuxWindow window) {
  final tool =
      window.foregroundAgentTool ??
      agentLaunchToolForCommandName(window.name) ??
      agentLaunchToolForCommandText(window.name);
  if (tool != null) {
    return '${tool.label} Workspace';
  }
  final name = window.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  return window.displayTitle;
}
