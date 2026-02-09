import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// Comprehensive keyboard toolbar for terminal input.
///
/// Features:
/// - Modifier keys (Ctrl, Alt, Shift) with toggle/lock functionality
/// - Navigation keys (arrows, Home, End, PgUp, PgDn)
/// - Function keys (F1-F12) in swipeable row
/// - Special keys (Esc, Tab, pipe, etc.)
/// - Haptic feedback
/// - Key repeat on long press
class KeyboardToolbar extends StatefulWidget {
  /// Creates a new [KeyboardToolbar].
  const KeyboardToolbar({required this.terminal, this.onKeyPressed, super.key});

  /// The terminal to send input to.
  final Terminal terminal;

  /// Optional callback when any key is pressed.
  final VoidCallback? onKeyPressed;

  @override
  State<KeyboardToolbar> createState() => _KeyboardToolbarState();
}

class _KeyboardToolbarState extends State<KeyboardToolbar> {
  // Modifier states: null = off, false = one-shot, true = locked
  bool? _ctrlState;
  bool? _altState;
  bool? _shiftState;

  int _functionKeyPage = 0;

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
            // Modifier and essential keys row
            _buildModifierRow(),
            // Navigation keys row
            _buildNavigationRow(),
            // Function keys row (swipeable)
            _buildFunctionKeysRow(),
            // Quick actions row
            _buildQuickActionsRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildModifierRow() => _KeyRow(
    children: [
      _ToolbarButton(
        label: 'Esc',
        onTap: _sendEscape,
        onLongPressStart: _sendEscape,
      ),
      _ToolbarButton(label: 'Tab', onTap: _sendTab, onLongPressStart: _sendTab),
      _ModifierButton(
        label: 'Ctrl',
        state: _ctrlState,
        onTap: () => _toggleModifier(_Modifier.ctrl),
        onDoubleTap: () => _lockModifier(_Modifier.ctrl),
      ),
      _ModifierButton(
        label: 'Alt',
        state: _altState,
        onTap: () => _toggleModifier(_Modifier.alt),
        onDoubleTap: () => _lockModifier(_Modifier.alt),
      ),
      _ModifierButton(
        label: 'Shift',
        state: _shiftState,
        onTap: () => _toggleModifier(_Modifier.shift),
        onDoubleTap: () => _lockModifier(_Modifier.shift),
      ),
      _ToolbarButton(label: '|', onTap: () => _sendText('|')),
      _ToolbarButton(label: r'\', onTap: () => _sendText(r'\')),
      // Enter key for soft keyboards that don't reliably send Enter
      _ToolbarButton(
        icon: Icons.keyboard_return,
        label: '',
        onTap: _sendEnter,
        tooltip: 'Enter',
      ),
    ],
  );

  Widget _buildNavigationRow() => _KeyRow(
    children: [
      _ToolbarButton(
        label: '↑',
        onTap: () => _sendArrow(_Arrow.up),
        onLongPressStart: () => _sendArrow(_Arrow.up),
      ),
      _ToolbarButton(
        label: '↓',
        onTap: () => _sendArrow(_Arrow.down),
        onLongPressStart: () => _sendArrow(_Arrow.down),
      ),
      _ToolbarButton(
        label: '←',
        onTap: () => _sendArrow(_Arrow.left),
        onLongPressStart: () => _sendArrow(_Arrow.left),
      ),
      _ToolbarButton(
        label: '→',
        onTap: () => _sendArrow(_Arrow.right),
        onLongPressStart: () => _sendArrow(_Arrow.right),
      ),
      _ToolbarButton(label: 'Home', onTap: () => _sendSequence('\x1b[H')),
      _ToolbarButton(label: 'End', onTap: () => _sendSequence('\x1b[F')),
      _ToolbarButton(label: 'PgUp', onTap: () => _sendSequence('\x1b[5~')),
      _ToolbarButton(label: 'PgDn', onTap: () => _sendSequence('\x1b[6~')),
    ],
  );

  Widget _buildFunctionKeysRow() {
    const keysPerPage = 6;
    final startIndex = _functionKeyPage * keysPerPage;

    return _KeyRow(
      children: [
        _ToolbarButton(
          label: '<',
          onTap: () {
            if (_functionKeyPage > 0) {
              setState(() => _functionKeyPage--);
            }
          },
          enabled: _functionKeyPage > 0,
        ),
        ...List.generate(keysPerPage, (i) {
          final fKey = startIndex + i + 1;
          if (fKey > 12) {
            return const Expanded(child: SizedBox());
          }
          return Expanded(
            child: _ToolbarButton(
              label: 'F$fKey',
              onTap: () => _sendFunctionKey(fKey),
            ),
          );
        }),
        _ToolbarButton(
          label: '>',
          onTap: () {
            if (_functionKeyPage < 1) {
              setState(() => _functionKeyPage++);
            }
          },
          enabled: _functionKeyPage < 1,
        ),
      ],
    );
  }

  Widget _buildQuickActionsRow() => _KeyRow(
    children: [
      _ToolbarButton(label: 'Ins', onTap: () => _sendSequence('\x1b[2~')),
      _ToolbarButton(label: 'Del', onTap: () => _sendSequence('\x1b[3~')),
      _ToolbarButton(label: '`', onTap: () => _sendText('`')),
      _ToolbarButton(label: '-', onTap: () => _sendText('-')),
      _ToolbarButton(label: '=', onTap: () => _sendText('=')),
      _ToolbarButton(label: '[', onTap: () => _sendText('[')),
      _ToolbarButton(label: ']', onTap: () => _sendText(']')),
      _ToolbarButton(label: '/', onTap: () => _sendText('/')),
      _ToolbarButton(
        icon: Icons.content_paste,
        label: '',
        onTap: _paste,
        tooltip: 'Paste',
      ),
    ],
  );

  void _toggleModifier(_Modifier mod) {
    HapticFeedback.selectionClick();
    setState(() {
      switch (mod) {
        case _Modifier.ctrl:
          _ctrlState = _ctrlState == null ? false : null;
        case _Modifier.alt:
          _altState = _altState == null ? false : null;
        case _Modifier.shift:
          _shiftState = _shiftState == null ? false : null;
      }
    });
  }

  void _lockModifier(_Modifier mod) {
    HapticFeedback.mediumImpact();
    setState(() {
      switch (mod) {
        case _Modifier.ctrl:
          _ctrlState = _ctrlState ?? false ? null : true;
        case _Modifier.alt:
          _altState = _altState ?? false ? null : true;
        case _Modifier.shift:
          _shiftState = _shiftState ?? false ? null : true;
      }
    });
  }

  void _consumeOneShot() {
    setState(() {
      if (_ctrlState case false) _ctrlState = null;
      if (_altState case false) _altState = null;
      if (_shiftState case false) _shiftState = null;
    });
  }

  void _sendEscape() {
    HapticFeedback.lightImpact();
    widget.terminal.textInput('\x1b');
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendTab() {
    HapticFeedback.lightImpact();
    widget.terminal.textInput('\t');
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendEnter() {
    HapticFeedback.lightImpact();
    widget.terminal.keyInput(TerminalKey.enter);
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendText(String text) {
    HapticFeedback.lightImpact();
    var output = text;

    if (_ctrlState != null && text.length == 1) {
      // Convert to control character
      final code = text.toUpperCase().codeUnitAt(0);
      if (code >= 0x40 && code <= 0x5F) {
        output = String.fromCharCode(code - 0x40);
      }
    }

    if (_shiftState != null) {
      output = output.toUpperCase();
    }

    widget.terminal.textInput(output);
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendSequence(String sequence) {
    HapticFeedback.lightImpact();
    widget.terminal.textInput(sequence);
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendArrow(_Arrow arrow) {
    HapticFeedback.lightImpact();
    final modifier = _getModifierPrefix();
    final suffix = switch (arrow) {
      _Arrow.up => 'A',
      _Arrow.down => 'B',
      _Arrow.right => 'C',
      _Arrow.left => 'D',
    };

    if (modifier.isNotEmpty) {
      widget.terminal.textInput('\x1b[1;$modifier$suffix');
    } else {
      widget.terminal.textInput('\x1b[$suffix');
    }

    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendFunctionKey(int n) {
    HapticFeedback.lightImpact();
    final modifier = _getModifierPrefix();

    // F1-F4 use different sequences
    final sequence = switch (n) {
      1 => modifier.isEmpty ? '\x1bOP' : '\x1b[1;${modifier}P',
      2 => modifier.isEmpty ? '\x1bOQ' : '\x1b[1;${modifier}Q',
      3 => modifier.isEmpty ? '\x1bOR' : '\x1b[1;${modifier}R',
      4 => modifier.isEmpty ? '\x1bOS' : '\x1b[1;${modifier}S',
      5 => modifier.isEmpty ? '\x1b[15~' : '\x1b[15;$modifier~',
      6 => modifier.isEmpty ? '\x1b[17~' : '\x1b[17;$modifier~',
      7 => modifier.isEmpty ? '\x1b[18~' : '\x1b[18;$modifier~',
      8 => modifier.isEmpty ? '\x1b[19~' : '\x1b[19;$modifier~',
      9 => modifier.isEmpty ? '\x1b[20~' : '\x1b[20;$modifier~',
      10 => modifier.isEmpty ? '\x1b[21~' : '\x1b[21;$modifier~',
      11 => modifier.isEmpty ? '\x1b[23~' : '\x1b[23;$modifier~',
      12 => modifier.isEmpty ? '\x1b[24~' : '\x1b[24;$modifier~',
      _ => '',
    };

    if (sequence.isNotEmpty) {
      widget.terminal.textInput(sequence);
      widget.onKeyPressed?.call();
    }
    _consumeOneShot();
  }

  String _getModifierPrefix() {
    var mod = 1;
    if (_shiftState != null) mod += 1;
    if (_altState != null) mod += 2;
    if (_ctrlState != null) mod += 4;
    return mod > 1 ? '$mod' : '';
  }

  Future<void> _paste() async {
    unawaited(HapticFeedback.lightImpact());
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text case final text?) {
      widget.terminal.paste(text);
      widget.onKeyPressed?.call();
    }
  }
}

enum _Modifier { ctrl, alt, shift }

enum _Arrow { up, down, left, right }

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 42,
    child: Row(
      children: children.map((c) {
        if (c is Expanded) return c;
        return Expanded(child: c);
      }).toList(),
    ),
  );
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.onLongPressStart,
    this.enabled = true,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final bool enabled;
  final String? tooltip;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveColor = widget.enabled
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainerHighest.withAlpha(128);

    Widget button = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.enabled ? widget.onTap : null,
      onLongPressStart: widget.onLongPressStart != null && widget.enabled
          ? (_) => widget.onLongPressStart?.call()
          : null,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _isPressed
              ? colorScheme.primary.withAlpha(50)
              : effectiveColor,
          borderRadius: BorderRadius.circular(6),
          border: _isPressed ? Border.all(color: colorScheme.primary) : null,
        ),
        child: Center(
          child: widget.icon != null
              ? Icon(
                  widget.icon,
                  size: 18,
                  color: widget.enabled
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.onSurfaceVariant.withAlpha(128),
                )
              : Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: widget.enabled
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.onSurfaceVariant.withAlpha(128),
                  ),
                ),
        ),
      ),
    );

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return button;
  }
}

class _ModifierButton extends StatelessWidget {
  const _ModifierButton({
    required this.label,
    required this.state,
    required this.onTap,
    required this.onDoubleTap,
  });

  final String label;
  final bool? state; // null = off, false = one-shot, true = locked
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final Color bgColor;
    final Color textColor;
    final IconData? icon;

    if (state == null) {
      bgColor = colorScheme.surfaceContainerHighest;
      textColor = colorScheme.onSurfaceVariant;
      icon = null;
    } else if (state == false) {
      bgColor = colorScheme.primaryContainer;
      textColor = colorScheme.onPrimaryContainer;
      icon = null;
    } else {
      bgColor = colorScheme.primary;
      textColor = colorScheme.onPrimary;
      icon = Icons.lock;
    }

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
              ),
              if (icon != null) ...[
                const SizedBox(width: 2),
                Icon(icon, size: 10, color: textColor),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
