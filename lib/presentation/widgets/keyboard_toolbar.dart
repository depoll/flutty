import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// Compact keyboard toolbar for terminal input.
///
/// Features:
/// - Modifier keys (Ctrl, Alt, Shift) with toggle/lock functionality
/// - Navigation keys (arrows, Home, End, PgUp, PgDn)
/// - Special keys (Esc, Tab, Enter, pipe, etc.)
/// - Haptic feedback
class KeyboardToolbar extends StatefulWidget {
  /// Creates a new [KeyboardToolbar].
  const KeyboardToolbar({
    required this.terminal,
    this.onKeyPressed,
    this.terminalFocusNode,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Optional callback when any key is pressed.
  final VoidCallback? onKeyPressed;

  /// Optional focus node for the terminal. When provided, the toolbar
  /// re-requests focus after interactions so the soft keyboard stays visible.
  final FocusNode? terminalFocusNode;

  @override
  State<KeyboardToolbar> createState() => KeyboardToolbarState();
}

/// State for [KeyboardToolbar], exposed so the terminal screen can query
/// active modifier state for system keyboard input.
class KeyboardToolbarState extends State<KeyboardToolbar> {
  // Modifier states: null = off, false = one-shot, true = locked
  bool? _ctrlState;
  bool? _altState;
  bool? _shiftState;

  /// Whether Ctrl is currently active (one-shot or locked).
  bool get isCtrlActive => _ctrlState != null;

  /// Whether Alt is currently active (one-shot or locked).
  bool get isAltActive => _altState != null;

  /// Whether Shift is currently active (one-shot or locked).
  bool get isShiftActive => _shiftState != null;

  /// Consumes one-shot modifiers (call after applying them).
  void consumeOneShot() => _consumeOneShot();

  /// Re-requests focus on the terminal so the soft keyboard stays visible.
  void _refocusTerminal() {
    widget.terminalFocusNode?.requestFocus();
  }

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
          children: [_buildModifierRow(), _buildNavigationRow()],
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
      _ToolbarButton(label: '/', onTap: () => _sendText('/')),
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
    _refocusTerminal();
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
    _refocusTerminal();
  }

  void _consumeOneShot() {
    setState(() {
      if (_ctrlState case false) _ctrlState = null;
      if (_altState case false) _altState = null;
      if (_shiftState case false) _shiftState = null;
    });
    _refocusTerminal();
  }

  void _sendEscape() {
    HapticFeedback.lightImpact();
    widget.terminal.textInput('\x1b');
    widget.onKeyPressed?.call();
    // Clear one-shot modifiers without the immediate refocus that
    // _consumeOneShot() would do. Refocus after a short delay so the
    // remote terminal's escape-sequence parser times out the bare ESC
    // before the next keystroke can arrive and be misinterpreted as
    // Alt+<key>.
    setState(() {
      if (_ctrlState case false) _ctrlState = null;
      if (_altState case false) _altState = null;
      if (_shiftState case false) _shiftState = null;
    });
    Future<void>.delayed(const Duration(milliseconds: 100), _refocusTerminal);
  }

  void _sendTab() {
    HapticFeedback.lightImpact();
    if (_shiftState != null) {
      // Shift+Tab sends reverse-tab escape sequence
      widget.terminal.textInput('\x1b[Z');
    } else {
      widget.terminal.textInput('\t');
    }
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
      final codeUnit = text.codeUnitAt(0);
      int? ctrlCode;
      if (codeUnit >= 0x61 && codeUnit <= 0x7A) {
        ctrlCode = codeUnit - 0x60;
      } else if (codeUnit >= 0x40 && codeUnit <= 0x5F) {
        ctrlCode = codeUnit - 0x40;
      } else if (codeUnit == 0x20) {
        ctrlCode = 0x00;
      } else if (codeUnit == 0x3F) {
        ctrlCode = 0x7F;
      }
      if (ctrlCode != null) {
        output = String.fromCharCode(ctrlCode);
      }
    }

    if (_altState != null) {
      // Alt/Meta sends ESC prefix
      output = '\x1b$output';
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

  String _getModifierPrefix() {
    var mod = 1;
    if (_shiftState != null) mod += 1;
    if (_altState != null) mod += 2;
    if (_ctrlState != null) mod += 4;
    return mod > 1 ? '$mod' : '';
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
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final String? tooltip;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget button = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      onLongPressStart: widget.onLongPressStart != null
          ? (_) => widget.onLongPressStart?.call()
          : null,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _isPressed
              ? colorScheme.primary.withAlpha(50)
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          border: _isPressed ? Border.all(color: colorScheme.primary) : null,
        ),
        child: Center(
          child: widget.icon != null
              ? Icon(widget.icon, size: 18, color: colorScheme.onSurfaceVariant)
              : Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurfaceVariant,
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
