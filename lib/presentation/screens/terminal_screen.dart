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
  const TerminalScreen({required this.hostId, super.key});

  /// The host ID to connect to.
  final int hostId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  late Terminal _terminal;
  late FocusNode _terminalFocusNode;
  final _toolbarKey = GlobalKey<KeyboardToolbarState>();
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

  // Track whether the app is in the background so we can auto-reconnect
  // when it resumes if the OS killed the socket.
  bool _wasBackgrounded = false;
  bool _connectionLostWhileBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

    // Clean up any previous connection state before reconnecting.
    await _outputSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _doneSubscription?.cancel();
    _outputSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    _shell = null;

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
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _error = 'Failed to start shell: $e';
      });
    }
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
      }
      // TODO: Add remote forwarding support when needed
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
    if (!mounted) {
      _sessionsNotifier?.disconnect(widget.hostId);
      unawaited(BackgroundSshService.stop());
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
    _sessionsNotifier?.disconnect(widget.hostId);
    unawaited(BackgroundSshService.stop());
  }

  Future<void> _disconnect() async {
    await _outputSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _doneSubscription?.cancel();
    _outputSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    await _sessionsNotifier?.disconnect(widget.hostId);
    unawaited(BackgroundSshService.stop());
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _outputSubscription?.cancel();
    _stderrSubscription?.cancel();
    _doneSubscription?.cancel();
    _terminalFocusNode.dispose();
    // Disconnect session when leaving the screen (use cached notifier)
    _sessionsNotifier?.disconnect(widget.hostId);
    unawaited(BackgroundSshService.stop());
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
              const PopupMenuItem(value: 'snippets', child: Text('Snippets')),
              const PopupMenuDivider(),
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
          if (_showKeyboard)
            KeyboardToolbar(
              key: _toolbarKey,
              terminal: _terminal,
              terminalFocusNode: _terminalFocusNode,
            ),
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

    final terminalView = TerminalView(
      _terminal,
      focusNode: isMobile ? null : _terminalFocusNode,
      theme: terminalTheme.toXtermTheme(),
      textStyle: textStyle,
      padding: const EdgeInsets.all(8),
      deleteDetection: !isMobile,
      autofocus: !isMobile,
      hardwareKeyboardOnly: isMobile,
      simulateScroll: !isMobile,
    );

    if (!isMobile) return terminalView;

    // On mobile, wrap with our own text input handler that enables
    // IME suggestions so swipe typing correctly inserts spaces.
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
      case 'snippets':
        await _showSnippetPicker();
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
