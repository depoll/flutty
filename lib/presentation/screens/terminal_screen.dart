import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/background_ssh_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/keyboard_toolbar.dart';
import '../widgets/terminal_text_input_handler.dart';
import '../widgets/terminal_theme_picker.dart';

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
  static const _terminalViewportPadding = EdgeInsets.all(8);

  late Terminal _terminal;
  late final TerminalController _terminalController;
  late final ScrollController _terminalScrollController;
  late final ScrollController _nativeSelectionScrollController;
  late final TextEditingController _nativeSelectionController;
  late final FocusNode _nativeSelectionFocusNode;
  late FocusNode _terminalFocusNode;
  final _toolbarKey = GlobalKey<KeyboardToolbarState>();
  SSHSession? _shell;
  StreamSubscription<void>? _doneSubscription;
  bool _isConnecting = true;
  String? _error;
  bool _showKeyboard = true;
  bool _isUsingAltBuffer = false;
  bool _hasTerminalSelection = false;
  bool _isNativeSelectionMode = false;
  bool _isSyncingNativeScroll = false;
  bool _hadNativeSelection = false;
  int? _connectionId;

  // Theme state
  Host? _host;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminalScrollController = ScrollController()
      ..addListener(_syncNativeScrollFromTerminal);
    _nativeSelectionScrollController = ScrollController()
      ..addListener(_syncTerminalScrollFromNative);
    _nativeSelectionController = TextEditingController();
    _nativeSelectionController.addListener(_onNativeSelectionChanged);
    _nativeSelectionFocusNode = FocusNode();
    _isUsingAltBuffer = _terminal.isUsingAltBuffer;
    _terminal.addListener(_onTerminalStateChanged);
    _terminalController.addListener(_onSelectionChanged);
    _terminalFocusNode = FocusNode();
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_loadHostAndConnect);
  }

  void _onTerminalStateChanged() {
    final isUsingAltBuffer = _terminal.isUsingAltBuffer;
    if (!mounted || _isUsingAltBuffer == isUsingAltBuffer) {
      return;
    }

    setState(() {
      _isUsingAltBuffer = isUsingAltBuffer;
    });
  }

  void _onSelectionChanged() {
    if (!mounted) {
      return;
    }

    final selection = _terminalController.selection;
    final hasSelection = selection != null;
    if (_isMobilePlatform && hasSelection && !_isNativeSelectionMode) {
      _enterNativeSelectionMode(initialRange: selection);
      return;
    }

    if (_hasTerminalSelection == hasSelection) {
      return;
    }

    setState(() {
      _hasTerminalSelection = hasSelection;
    });
  }

  void _onNativeSelectionChanged() {
    if (!_isNativeSelectionMode) {
      return;
    }

    final hasSelection = !_nativeSelectionController.selection.isCollapsed;
    if (hasSelection) {
      _hadNativeSelection = true;
      return;
    }

    if (_hadNativeSelection) {
      _hadNativeSelection = false;
      _exitNativeSelectionMode();
    }
  }

  void _syncNativeScrollFromTerminal() {
    if (!_isNativeSelectionMode ||
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
    if (!_isNativeSelectionMode ||
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
    await _loadTheme();
    await _connect(preferredConnectionId: widget.connectionId);
  }

  Future<void> _loadTheme() async {
    if (!mounted) return;

    final brightness = MediaQuery.of(context).platformBrightness;
    final themeService = ref.read(terminalThemeServiceProvider);
    final theme = await themeService.getThemeForHost(_host, brightness);

    if (mounted) {
      setState(() => _currentTheme = theme);
    }
  }

  Future<void> _connect({
    int? preferredConnectionId,
    bool forceNew = false,
  }) async {
    if (!mounted) return;

    // Clean up any previous connection state before reconnecting.
    await _doneSubscription?.cancel();
    _doneSubscription = null;
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
        await _openShell(existingSession);
        return;
      }
      shouldForceNew = true;
    }

    final result = await _sessionsNotifier!.connect(
      widget.hostId,
      forceNew: shouldForceNew,
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
        _terminal.removeListener(_onTerminalStateChanged);
        _terminal = existingTerminal;
        _isUsingAltBuffer = _terminal.isUsingAltBuffer;
        _terminal.addListener(_onTerminalStateChanged);
        _shell = await session.getShell();
        _wireTerminalCallbacks(session);
        setState(() => _isConnecting = false);
        unawaited(
          BackgroundSshService.start(
            hostName: _host?.label ?? _host?.hostname ?? 'SSH server',
          ),
        );
        return;
      }

      // First time opening shell for this session — create terminal in session.
      final sessionTerminal = session.getOrCreateTerminal();
      _terminal.removeListener(_onTerminalStateChanged);
      _terminal = sessionTerminal;
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminal.addListener(_onTerminalStateChanged);

      _shell = await session.getShell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      _wireTerminalCallbacks(session);

      if (!mounted) return;

      setState(() => _isConnecting = false);

      // Start the background service to keep the connection alive
      // when the app is backgrounded.
      unawaited(
        BackgroundSshService.start(
          hostName: _host?.label ?? _host?.hostname ?? 'SSH server',
        ),
      );

      // Start port forwards
      await _startPortForwards(session);
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
      final toolbar = _toolbarKey.currentState;
      if (toolbar != null && output.length == 1) {
        if (toolbar.isCtrlActive) {
          final codeUnit = output.codeUnitAt(0);
          int? ctrlCode;
          if (codeUnit >= 0x61 && codeUnit <= 0x7A) {
            // 'a'–'z' → 0x01–0x1A
            ctrlCode = codeUnit - 0x60;
          } else if (codeUnit >= 0x40 && codeUnit <= 0x5F) {
            // '@'–'_' (includes A–Z) → 0x00–0x1F
            ctrlCode = codeUnit - 0x40;
          } else if (codeUnit == 0x20) {
            ctrlCode = 0x00; // Ctrl+Space → NUL
          } else if (codeUnit == 0x3F) {
            ctrlCode = 0x7F; // Ctrl+? → DEL
          }
          if (ctrlCode != null) {
            output = String.fromCharCode(ctrlCode);
          }
          toolbar.consumeOneShot();
        } else if (toolbar.isAltActive) {
          // Alt sends ESC prefix
          output = '\x1b$output';
          toolbar.consumeOneShot();
        }
      }

      _shell?.write(utf8.encode(output));
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _shell?.resizeTerminal(width, height);
    };
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

  void _handleShellClosed() {
    final connectionId = _connectionId;
    if (!mounted) {
      if (connectionId != null) {
        unawaited(_sessionsNotifier?.disconnect(connectionId));
      }
      _stopBackgroundServiceIfNoConnections();
      return;
    }
    // If the app is in the background, don't show the error screen
    // immediately — defer it so we can auto-reconnect on resume.
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = true;
    } else {
      setState(() {
        _error = 'Connection closed';
      });
    }
    // Clean up the session state regardless of background/foreground.
    if (connectionId != null) {
      unawaited(_sessionsNotifier?.disconnect(connectionId));
    }
    _stopBackgroundServiceIfNoConnections();
  }

  Future<void> _disconnect() async {
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    if (_connectionId != null) {
      await _sessionsNotifier?.disconnect(_connectionId!);
    }
    _stopBackgroundServiceIfNoConnections();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _terminal.removeListener(_onTerminalStateChanged);
    _terminalController
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _terminalScrollController
      ..removeListener(_syncNativeScrollFromTerminal)
      ..dispose();
    _nativeSelectionScrollController
      ..removeListener(_syncTerminalScrollFromNative)
      ..dispose();
    _nativeSelectionController
      ..removeListener(_onNativeSelectionChanged)
      ..dispose();
    _nativeSelectionFocusNode.dispose();
    _doneSubscription?.cancel();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      if (_connectionLostWhileBackgrounded && mounted) {
        _connectionLostWhileBackgrounded = false;
        _terminal.write('\r\n[reconnecting...]\r\n');
        _connect();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload theme when system brightness changes
    if (_currentTheme != null && _sessionThemeOverride == null) {
      _loadTheme();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final systemKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

    // Use session override, or loaded theme, or fallback
    final terminalTheme =
        _sessionThemeOverride ??
        _currentTheme ??
        (isDark ? TerminalThemes.midnightPurple : TerminalThemes.cleanWhite);

    return Scaffold(
      appBar: AppBar(
        title: Text(_host?.label ?? 'Terminal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            onPressed: _showThemePicker,
            tooltip: 'Change theme',
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
            icon: Icon(
              _showKeyboard ? Icons.space_bar : Icons.keyboard_outlined,
            ),
            onPressed: () => setState(() => _showKeyboard = !_showKeyboard),
            tooltip: _showKeyboard ? 'Hide toolbar' : 'Show toolbar',
          ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'snippets', child: Text('Snippets')),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'native_select',
                child: Text(
                  _isNativeSelectionMode
                      ? 'Exit Native Selection'
                      : 'Native Selection',
                ),
              ),
              const PopupMenuItem(value: 'copy', child: Text('Copy')),
              const PopupMenuItem(value: 'paste', child: Text('Paste')),
              const PopupMenuItem(value: 'clear', child: Text('Clear')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'disconnect',
                child: Text('Disconnect'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildTerminalView(terminalTheme, isMobile)),
          if (_showKeyboard && !_isNativeSelectionMode)
            KeyboardToolbar(
              key: _toolbarKey,
              terminal: _terminal,
              terminalFocusNode: _terminalFocusNode,
            ),
        ],
      ),
    );
  }

  void _stopBackgroundServiceIfNoConnections() {
    final connectionStates = ref.read(activeSessionsProvider);
    final hasActiveConnection = connectionStates.values.any(
      (state) =>
          state == SshConnectionState.connected ||
          state == SshConnectionState.connecting ||
          state == SshConnectionState.authenticating ||
          state == SshConnectionState.reconnecting,
    );
    if (!hasActiveConnection) {
      unawaited(BackgroundSshService.stop());
    }
  }

  /// Toggles the system keyboard visibility on mobile platforms.
  void _toggleSystemKeyboard(bool isVisible) {
    if (isVisible) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    } else {
      _terminalFocusNode.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    }
  }

  Future<void> _showThemePicker() async {
    final currentId = _sessionThemeOverride?.id ?? _currentTheme?.id;
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );

    if (theme != null && mounted) {
      setState(() => _sessionThemeOverride = theme);

      // Show option to save to host
      if (_host != null) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
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
                    child: const Text('Save to Host'),
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

  Widget _buildTerminalView(TerminalThemeData terminalTheme, bool isMobile) {
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

    if (_error != null) {
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
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => _connect(preferredConnectionId: _connectionId),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Get font size from settings (use setting value, not responsive calculation)
    final fontSize = ref.watch(fontSizeNotifierProvider);

    // Get font family from host (if set) or global settings
    final hostFont = _host?.terminalFontFamily;
    final globalFont = ref.watch(fontFamilyNotifierProvider);
    final fontFamily = hostFont ?? globalFont;
    final terminalTextStyle = _getTerminalTextStyle(fontFamily, fontSize);
    final nativeSelectionTextStyle = _getNativeSelectionTextStyle(
      terminalTextStyle,
    );

    final terminalView = TerminalView(
      _terminal,
      controller: _terminalController,
      scrollController: _terminalScrollController,
      focusNode: isMobile ? null : _terminalFocusNode,
      theme: terminalTheme.toXtermTheme(),
      textStyle: terminalTextStyle,
      padding: _terminalViewportPadding,
      deleteDetection: !isMobile,
      autofocus: !isMobile,
      hardwareKeyboardOnly: isMobile,
      readOnly: _isNativeSelectionMode,
      // On touch devices, simulating wheel scroll with Up/Down keys in alt
      // buffer makes swipe scroll behave like rapid history navigation.
      simulateScroll: !isMobile && _isUsingAltBuffer,
    );

    if (!isMobile) return terminalView;

    Widget mobileTerminalView = terminalView;
    if (_isUsingAltBuffer) {
      // xterm's alt-buffer scroll handler can convert touch scroll into input
      // events for some TUIs. On mobile, consume vertical drags at this layer
      // so swipe scrolling never becomes terminal key/mouse input.
      mobileTerminalView = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragDown: (_) {},
        onVerticalDragStart: (_) {},
        onVerticalDragUpdate: (_) {},
        onVerticalDragEnd: (_) {},
        onVerticalDragCancel: () {},
        child: mobileTerminalView,
      );
    }

    // On mobile, wrap with our own text input handler that enables
    // IME suggestions so swipe typing correctly inserts spaces.
    if (_isNativeSelectionMode) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          _nativeSelectionOverlay(nativeSelectionTextStyle),
        ],
      );
    } else if (_hasTerminalSelection) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          Positioned(left: 12, right: 12, bottom: 12, child: _selectionActions),
        ],
      );
    }

    return TerminalTextInputHandler(
      terminal: _terminal,
      focusNode: _terminalFocusNode,
      deleteDetection: true,
      readOnly: _isNativeSelectionMode,
      child: mobileTerminalView,
    );
  }

  Widget _nativeSelectionOverlay(TextStyle textStyle) => Positioned.fill(
    child: Padding(
      padding: _terminalViewportPadding,
      child: TextField(
        controller: _nativeSelectionController,
        focusNode: _nativeSelectionFocusNode,
        readOnly: true,
        showCursor: false,
        scrollController: _nativeSelectionScrollController,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: textStyle,
        strutStyle: StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ),
  );

  /// Gets the terminal text style for the given font family using Google Fonts.
  TerminalStyle _getTerminalTextStyle(String fontFamily, double fontSize) {
    final textStyle = _resolveTerminalTextStyle(fontFamily, fontSize);
    if (textStyle != null) {
      return TerminalStyle.fromTextStyle(textStyle);
    }
    return TerminalStyle(fontSize: fontSize);
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

  TextStyle? _resolveTerminalTextStyle(String fontFamily, double fontSize) =>
      switch (fontFamily) {
        'JetBrains Mono' => GoogleFonts.jetBrainsMono(fontSize: fontSize),
        'Fira Code' => GoogleFonts.firaCode(fontSize: fontSize),
        'Source Code Pro' => GoogleFonts.sourceCodePro(fontSize: fontSize),
        'Ubuntu Mono' => GoogleFonts.ubuntuMono(fontSize: fontSize),
        'Roboto Mono' => GoogleFonts.robotoMono(fontSize: fontSize),
        'IBM Plex Mono' => GoogleFonts.ibmPlexMono(fontSize: fontSize),
        'Inconsolata' => GoogleFonts.inconsolata(fontSize: fontSize),
        'Anonymous Pro' => GoogleFonts.anonymousPro(fontSize: fontSize),
        'Cousine' => GoogleFonts.cousine(fontSize: fontSize),
        'PT Mono' => GoogleFonts.ptMono(fontSize: fontSize),
        'Space Mono' => GoogleFonts.spaceMono(fontSize: fontSize),
        'VT323' => GoogleFonts.vt323(fontSize: fontSize),
        'Share Tech Mono' => GoogleFonts.shareTechMono(fontSize: fontSize),
        'Overpass Mono' => GoogleFonts.overpassMono(fontSize: fontSize),
        'Oxygen Mono' => GoogleFonts.oxygenMono(fontSize: fontSize),
        _ => null,
      };

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'snippets':
        await _showSnippetPicker();
        break;
      case 'native_select':
        _toggleNativeSelectionMode();
        break;
      case 'copy':
        await _copySelection();
        break;
      case 'paste':
        await _pasteClipboard();
        break;
      case 'clear':
        _terminal.buffer.clear();
        _terminalController.clearSelection();
        break;
      case 'disconnect':
        await _disconnect();
        break;
    }
  }

  void _toggleNativeSelectionMode() {
    if (_isNativeSelectionMode) {
      _exitNativeSelectionMode();
      return;
    }

    _enterNativeSelectionMode(initialRange: _terminalController.selection);
  }

  void _enterNativeSelectionMode({BufferRange? initialRange}) {
    if (_isNativeSelectionMode) {
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
            textLength: snapshot.text.length,
          );
    _nativeSelectionController.value = TextEditingValue(
      text: snapshot.text,
      selection: selection,
    );
    _hadNativeSelection = !selection.isCollapsed;
    setState(() {
      _isNativeSelectionMode = true;
      _hasTerminalSelection = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncNativeScrollFromTerminal();
      _nativeSelectionFocusNode.requestFocus();
    });
    if (_terminalController.selection != null) {
      _terminalController.clearSelection();
    }
  }

  void _exitNativeSelectionMode() {
    setState(() {
      _isNativeSelectionMode = false;
      _hasTerminalSelection = false;
    });
    _hadNativeSelection = false;
    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    _terminalFocusNode.requestFocus();
  }

  ({String text, List<int> lineStarts, List<List<int>> columnOffsets})
  _buildNativeSelectionSnapshotData() {
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

    return (
      text: builder.toString(),
      lineStarts: lineStarts,
      columnOffsets: lineColumnOffsets,
    );
  }

  ({String text, List<int> columnOffsets}) _buildNativeSelectionLineSnapshot(
    BufferLine line,
    int viewWidth,
  ) {
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

    return (text: builder.toString(), columnOffsets: columnOffsets);
  }

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

  Widget get _selectionActions => SafeArea(
    top: false,
    child: Material(
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
                onPressed: _terminalController.clearSelection,
                icon: const Icon(Icons.close),
                label: const Text('Clear'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection == null) {
      return;
    }

    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    _terminalController.clearSelection();

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }

    _terminal.paste(text);
    _terminalController.clearSelection();
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
        await showModalBottomSheet<({String command, int snippetId})>(
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
                              command: command,
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

    if (result != null && result.command.isNotEmpty) {
      // Insert the command into terminal
      _terminal.paste(result.command);
      // Track usage
      unawaited(snippetRepo.incrementUsage(result.snippetId));
    }
  }

  /// Shows dialog for variable substitution if snippet has variables.
  Future<String?> _substituteVariables(
    BuildContext context,
    Snippet snippet,
  ) async {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(snippet.command);
    final variables = matches.map((m) => m.group(1)!).toSet().toList();

    if (variables.isEmpty) {
      return snippet.command;
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

    return command;
  }
}
