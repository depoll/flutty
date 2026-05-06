part of '../screens/terminal_screen.dart';

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
    required this.recoveryGeneration,
    required this.isProUser,
    required this.startClisInYoloMode,
    required this.initiallyExpanded,
    required this.ref,
    required this.onAction,
    required this.onExpandedChanged,
    this.tmuxExtraFlags,
    this.scopeWorkingDirectory,
    this.onWindowStateChanged,
    this.onWindowLoadStalled,
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

  /// Callback for navigator actions.
  final Future<void> Function(TmuxNavigatorAction) onAction;

  /// Called when the expanded/collapsed state changes.
  final ValueChanged<bool> onExpandedChanged;

  final void Function(SshSession session, String sessionName)?
  onWindowStateChanged;

  final Future<void> Function(SshSession session, String sessionName)?
  onWindowLoadStalled;

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
  static const _denseTileVisualDensity = VisualDensity(vertical: -2);
  static const _denseTilePadding = EdgeInsets.symmetric(horizontal: 12);
  static const _groupTilePadding = EdgeInsets.only(left: 52, right: 12);
  static const _pendingSelectionTimeout = Duration(seconds: 2);

  List<TmuxWindow>? _windows;
  AgentLaunchTool? _preferredLaunchTool;
  final Set<String> _seenAlertWindowKeys = <String>{};
  final Map<String, int> _seenAlertWindowIndexesByKey = <String, int>{};
  late bool _expanded;
  bool _isLoading = true;
  bool _showSessions = false;
  bool _hasInitializedSessionProviders = false;
  double _dragOffset = 0;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
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
  late LocalNotificationService _localNotifications;

  TmuxService get _tmux => widget.ref.read(tmuxServiceProvider);

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
    unawaited(_tmux.prefetchInstalledAgentTools(widget.session));
    _loadWindows();
    _subscribeToWindowChanges();
  }

  @override
  void didUpdateWidget(covariant _TmuxExpandableBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged =
        oldWidget.session.connectionId != widget.session.connectionId ||
        oldWidget.tmuxSessionName != widget.tmuxSessionName ||
        oldWidget.tmuxExtraFlags != widget.tmuxExtraFlags;
    final recoveryChanged =
        oldWidget.recoveryGeneration != widget.recoveryGeneration;
    if (!sessionChanged && !recoveryChanged) {
      return;
    }
    final wasExpanded = _expanded;
    _clearPendingSelectedWindow(notify: false);
    _resetWindowReloadRecovery();
    if (!shouldPreserveTmuxBarSnapshotOnUpdate(
      sessionChanged: sessionChanged,
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
      unawaited(_tmux.prefetchInstalledAgentTools(widget.session));
    } else if (!(_windows?.isNotEmpty ?? false)) {
      setState(() => _isLoading = true);
    }
    if (sessionChanged) {
      unawaited(_windowChangeSubscription?.cancel());
      _subscribeToWindowChanges();
    }
    unawaited(_loadPreferredLaunchTool());
    _loadWindows();
  }

  @override
  void dispose() {
    _clearPendingSelectedWindow(notify: false);
    _resetWindowReloadRecovery();
    unawaited(_windowChangeSubscription?.cancel());
    _clearSeenAlertNotifications(widget.session, widget.tmuxSessionName);
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
    _windowChangeSubscription = _tmux
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
      _notifyWindowStateChanged();
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
    DiagnosticsLogService.instance.debug(
      'tmux.ui',
      'bar_snapshot_applied',
      fields: {
        'connectionId': widget.session.connectionId,
        'windowCount': windows.length,
      },
    );
    _applyWindows(windows);
    _notifyWindowStateChanged();
  }

  void _notifyWindowStateChanged() {
    widget.onWindowStateChanged?.call(widget.session, widget.tmuxSessionName);
  }

  void _applyWindows(List<TmuxWindow> windows) {
    // Detect new alerts that weren't in the previous window list.
    final newAlerts = windows.where(
      (w) =>
          w.hasAlert &&
          !w.isActive &&
          !_seenAlertWindowKeys.contains(_tmuxAlertWindowKey(w)),
    );
    if (newAlerts.isNotEmpty) {
      unawaited(_bounceController.forward(from: 0));
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
      final reloadedWindows = await _tmux.listWindows(
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

  Future<void> _showNewWindowPicker() async {
    final installedToolsFuture = _tmux.detectInstalledAgentTools(
      widget.session,
    );
    final action = await showTmuxNewWindowPicker(
      context: context,
      isProUser: widget.isProUser,
      startClisInYoloMode: widget.startClisInYoloMode,
      installedToolsFuture: installedToolsFuture,
      preferredTool: _preferredLaunchTool,
    );
    if (!mounted || action == null) {
      return;
    }
    await widget.onAction(action);
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
    if (shouldExpand) {
      widget.onExpandedChanged(true);
    } else if (shouldCollapse) {
      widget.onExpandedChanged(false);
    }
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
          onTap: () {
            final wasExpanded = _expanded;
            setState(() => _expanded = !_expanded);
            widget.onExpandedChanged(!wasExpanded);
            // Refresh window list when expanding to get current active state.
            if (!wasExpanded) {
              _loadWindows();
            }
          },
          child: SizedBox(
            height: _TmuxExpandableBar.handleHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  AgentToolIcon(
                    tool: activeWindowTool,
                    size: 16,
                    color: theme.colorScheme.primary,
                    fallbackIcon: Icons.window_outlined,
                  ),
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

    if (displayedWindows == null || displayedWindows.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          for (final window in displayedWindows)
            _buildWindowTile(theme, window),
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

  Widget _buildWindowTile(ThemeData theme, TmuxWindow window) {
    final isActive = window.isActive;
    final title = _redactStoreScreenshotIdentities
        ? switch (window.name.trim()) {
            'claude' || 'claude-code' => 'Claude Code Workspace',
            'copilot' => 'Mobile Copilot Workspace',
            final name when name.isNotEmpty => name,
            _ => window.displayTitle,
          }
        : window.displayTitle;
    final secondaryTitle = _redactStoreScreenshotIdentities
        ? null
        : window.secondaryTitle;
    final iconColor = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

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
