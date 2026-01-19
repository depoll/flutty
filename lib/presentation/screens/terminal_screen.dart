import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../domain/services/ssh_service.dart';

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
  SSHSession? _shell;
  StreamSubscription<dynamic>? _outputSubscription;
  StreamSubscription<dynamic>? _stderrSubscription;
  StreamSubscription<void>? _doneSubscription;
  bool _isConnecting = true;
  String? _error;
  bool _showKeyboard = true;
  
  // Cache the notifier for use in dispose
  ActiveSessionsNotifier? _sessionsNotifier;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_connect);
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

      _outputSubscription = _shell!.stdout.listen((data) {
        _terminal.write(utf8.decode(data));
      });

      _stderrSubscription = _shell!.stderr.listen((data) {
        _terminal.write(utf8.decode(data));
      });

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
    // Disconnect session when leaving the screen (use cached notifier)
    _sessionsNotifier?.disconnect(widget.hostId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          IconButton(
            icon: Icon(_showKeyboard ? Icons.keyboard_hide : Icons.keyboard),
            onPressed: () => setState(() => _showKeyboard = !_showKeyboard),
            tooltip: _showKeyboard ? 'Hide keyboard' : 'Show keyboard',
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
          Expanded(child: _buildTerminalView(isDark)),
          if (_showKeyboard) _KeyboardToolbar(terminal: _terminal),
        ],
      ),
    );
  }

  Widget _buildTerminalView(bool isDark) {
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

    return TerminalView(
      _terminal,
      theme: isDark ? _darkTerminalTheme : _lightTerminalTheme,
      textStyle: const TerminalStyle(fontSize: 14),
    );
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

  static const _darkTerminalTheme = TerminalTheme(
    cursor: Color(0xFFE5E5E5),
    selection: Color(0xFF4D4D4D),
    foreground: Color(0xFFE5E5E5),
    background: Color(0xFF1E1E2E),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF0DBC79),
    yellow: Color(0xFFE5E510),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFBC3FBC),
    cyan: Color(0xFF11A8CD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFF14C4C),
    brightGreen: Color(0xFF23D18B),
    brightYellow: Color(0xFFF5F543),
    brightBlue: Color(0xFF3B8EEA),
    brightMagenta: Color(0xFFD670D6),
    brightCyan: Color(0xFF29B8DB),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFDF5D),
    searchHitBackgroundCurrent: Color(0xFFFF9632),
    searchHitForeground: Color(0xFF000000),
  );

  static const _lightTerminalTheme = TerminalTheme(
    cursor: Color(0xFF000000),
    selection: Color(0xFFADD6FF),
    foreground: Color(0xFF000000),
    background: Color(0xFFFFFFFF),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF00BC00),
    yellow: Color(0xFFA5A900),
    blue: Color(0xFF0451A5),
    magenta: Color(0xFFBC05BC),
    cyan: Color(0xFF0598BC),
    white: Color(0xFF555555),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFCD3131),
    brightGreen: Color(0xFF14CE14),
    brightYellow: Color(0xFFB5BA00),
    brightBlue: Color(0xFF0451A5),
    brightMagenta: Color(0xFFBC05BC),
    brightCyan: Color(0xFF0598BC),
    brightWhite: Color(0xFFA5A5A5),
    searchHitBackground: Color(0xFFFFDF5D),
    searchHitBackgroundCurrent: Color(0xFFFF9632),
    searchHitForeground: Color(0xFF000000),
  );
}

/// Keyboard toolbar with special keys for terminal input.
class _KeyboardToolbar extends StatelessWidget {
  const _KeyboardToolbar({required this.terminal});

  final Terminal terminal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Modifier keys row
            _buildKeyRow([
              _ToolbarKey(label: 'Esc', onTap: () => _sendKey('\x1b')),
              _ToolbarKey(label: 'Tab', onTap: () => _sendKey('\t')),
              const _ModifierKey(label: 'Ctrl', modifier: _Modifier.ctrl),
              const _ModifierKey(label: 'Alt', modifier: _Modifier.alt),
              _ToolbarKey(label: '↑', onTap: () => _sendKey('\x1b[A')),
              _ToolbarKey(label: '↓', onTap: () => _sendKey('\x1b[B')),
              _ToolbarKey(label: '←', onTap: () => _sendKey('\x1b[D')),
              _ToolbarKey(label: '→', onTap: () => _sendKey('\x1b[C')),
            ]),
            // Function and navigation keys
            _buildKeyRow([
              _ToolbarKey(label: 'Home', onTap: () => _sendKey('\x1b[H')),
              _ToolbarKey(label: 'End', onTap: () => _sendKey('\x1b[F')),
              _ToolbarKey(label: 'PgUp', onTap: () => _sendKey('\x1b[5~')),
              _ToolbarKey(label: 'PgDn', onTap: () => _sendKey('\x1b[6~')),
              _ToolbarKey(label: 'Ins', onTap: () => _sendKey('\x1b[2~')),
              _ToolbarKey(label: 'Del', onTap: () => _sendKey('\x1b[3~')),
              _ToolbarKey(label: '|', onTap: () => _sendKey('|')),
              _ToolbarKey(label: '/', onTap: () => _sendKey('/')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyRow(List<Widget> keys) => SizedBox(
    height: 44,
    child: Row(children: keys.map((key) => Expanded(child: key)).toList()),
  );

  void _sendKey(String key) {
    HapticFeedback.lightImpact();
    terminal
      ..keyInput(TerminalKey.escape)
      ..textInput(key);
  }
}

enum _Modifier { ctrl, alt }

class _ModifierKey extends StatefulWidget {
  const _ModifierKey({required this.label, required this.modifier});

  final String label;
  final _Modifier modifier;

  @override
  State<_ModifierKey> createState() => _ModifierKeyState();
}

class _ModifierKeyState extends State<_ModifierKey> {
  bool _isActive = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() => _isActive = !_isActive);
      },
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _isActive
              ? colorScheme.primary
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _isActive
                  ? colorScheme.onPrimary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarKey extends StatelessWidget {
  const _ToolbarKey({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
