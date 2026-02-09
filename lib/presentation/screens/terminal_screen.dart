import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/keyboard_toolbar.dart';
import '../widgets/terminal_text_input_handler.dart';
import '../widgets/terminal_theme_picker.dart';

/// Terminal screen for SSH sessions.
class TerminalScreen extends ConsumerStatefulWidget {
  /// Creates a new [TerminalScreen].
  const TerminalScreen({required this.hostId, super.key});

  /// The host ID to connect to.
  final int hostId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late Terminal _terminal;
  late FocusNode _terminalFocusNode;
  SSHSession? _shell;
  StreamSubscription<dynamic>? _outputSubscription;
  StreamSubscription<dynamic>? _stderrSubscription;
  StreamSubscription<void>? _doneSubscription;
  bool _isConnecting = true;
  String? _error;
  bool _showKeyboard = true;
  bool _systemKeyboardVisible = true;

  // Theme state
  Host? _host;
  TerminalThemeData? _currentTheme;
  TerminalThemeData? _sessionThemeOverride;

  // Cache the notifier for use in dispose
  ActiveSessionsNotifier? _sessionsNotifier;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminalFocusNode = FocusNode();
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_loadHostAndConnect);
  }

  Future<void> _loadHostAndConnect() async {
    // Load host data first for theme
    final hostRepo = ref.read(hostRepositoryProvider);
    _host = await hostRepo.getById(widget.hostId);
    await _loadTheme();
    await _connect();
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

  Future<void> _connect() async {
    if (!mounted) return;

    setState(() {
      _isConnecting = true;
      _error = null;
    });

    _sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final result = await _sessionsNotifier!.connect(widget.hostId);

    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _isConnecting = false;
        _error = result.error ?? 'Connection failed';
      });
      return;
    }

    final session = _sessionsNotifier!.getSession(widget.hostId);
    if (session == null) {
      setState(() {
        _isConnecting = false;
        _error = 'Session not found';
      });
      return;
    }

    try {
      _shell = await session.getShell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      if (!mounted) return;

      // Use streaming UTF-8 decoder that properly handles chunked data
      _outputSubscription = _shell!.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((data) => _terminal.write(data));

      _stderrSubscription = _shell!.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((data) => _terminal.write(data));

      // Listen for shell completion (logout, exit, connection drop)
      _doneSubscription = _shell!.done.asStream().listen((_) {
        if (mounted) {
          _handleShellClosed();
        }
      });

      _terminal.onOutput = (data) {
        _shell?.write(utf8.encode(data));
      };

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _shell?.resizeTerminal(width, height);
      };

      setState(() => _isConnecting = false);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _error = 'Failed to start shell: $e';
      });
    }
  }

  void _handleShellClosed() {
    if (!mounted) return;
    setState(() {
      _error = 'Connection closed';
    });
    // Clean up the session state
    _sessionsNotifier?.disconnect(widget.hostId);
  }

  Future<void> _disconnect() async {
    await _outputSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _doneSubscription?.cancel();
    _outputSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    await _sessionsNotifier?.disconnect(widget.hostId);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _outputSubscription?.cancel();
    _stderrSubscription?.cancel();
    _doneSubscription?.cancel();
    _terminalFocusNode.dispose();
    // Disconnect session when leaving the screen (use cached notifier)
    _sessionsNotifier?.disconnect(widget.hostId);
    super.dispose();
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
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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
                _systemKeyboardVisible
                    ? Icons.keyboard_hide
                    : Icons.keyboard_alt_outlined,
              ),
              onPressed: _toggleSystemKeyboard,
              tooltip: _systemKeyboardVisible
                  ? 'Hide system keyboard'
                  : 'Show system keyboard',
            ),
          IconButton(
            icon: Icon(_showKeyboard ? Icons.space_bar : Icons.more_horiz),
            onPressed: () => setState(() => _showKeyboard = !_showKeyboard),
            tooltip: _showKeyboard ? 'Hide toolbar' : 'Show toolbar',
          ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
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
          Expanded(child: _buildTerminalView(terminalTheme)),
          if (_showKeyboard) KeyboardToolbar(terminal: _terminal),
        ],
      ),
    );
  }

  /// Toggles the system keyboard visibility on mobile platforms.
  void _toggleSystemKeyboard() {
    setState(() {
      _systemKeyboardVisible = !_systemKeyboardVisible;
    });
    if (_systemKeyboardVisible) {
      _terminalFocusNode.requestFocus();
    } else {
      _terminalFocusNode.unfocus();
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

  Widget _buildTerminalView(TerminalThemeData terminalTheme) {
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
              ElevatedButton(onPressed: _connect, child: const Text('Retry')),
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
    final textStyle = _getTerminalTextStyle(fontFamily, fontSize);

    // Disable simulated scroll (arrow keys) on mobile since the toolbar
    // provides arrow keys and swiping should scroll the terminal buffer.
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    final terminalView = TerminalView(
      _terminal,
      focusNode: _terminalFocusNode,
      theme: terminalTheme.toXtermTheme(),
      textStyle: textStyle,
      padding: const EdgeInsets.all(8),
      deleteDetection: !isMobile,
      autofocus: true,
      simulateScroll: !isMobile,
      // On mobile, we handle soft keyboard input ourselves to fix Enter.
      hardwareKeyboardOnly: isMobile,
    );

    if (!isMobile) return terminalView;

    // Wrap with our own TextInputClient that properly handles
    // TextInputAction.newline (which xterm ignores, breaking Enter on iOS).
    return TerminalTextInputHandler(
      terminal: _terminal,
      focusNode: _terminalFocusNode,
      deleteDetection: true,
      child: terminalView,
    );
  }

  /// Gets the terminal text style for the given font family using Google Fonts.
  TerminalStyle _getTerminalTextStyle(String fontFamily, double fontSize) {
    final textStyle = switch (fontFamily) {
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

    if (textStyle != null) {
      return TerminalStyle.fromTextStyle(textStyle);
    }
    return TerminalStyle(fontSize: fontSize);
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'copy':
        // xterm doesn't expose selectedText directly
        // Copy functionality requires integration with TerminalView's selection
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Use long-press to select and copy')),
          );
        }
      case 'paste':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (data?.text != null) {
          _terminal.paste(data!.text!);
        }
      case 'clear':
        _terminal.buffer.clear();
      case 'disconnect':
        await _disconnect();
    }
  }
}
