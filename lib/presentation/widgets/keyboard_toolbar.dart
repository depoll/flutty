import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'terminal_key_input.dart';

/// Whether the toolbar should keep the bottom safe-area inset.
///
/// When the system keyboard is visible, the toolbar is already lifted above the
/// obscured region by the viewport inset. In that state, keeping the bottom
/// safe-area inset just adds unnecessary extra gap above the keyboard.
bool shouldKeepToolbarBottomSafeArea(MediaQueryData mediaQuery) =>
    mediaQuery.viewInsets.bottom == 0;

/// Resolves the terminal output sequence for a Tab action.
///
/// An explicit Shift modifier from the terminal toolbar turns Tab into the
/// reverse-tab escape sequence. Plain Tab remains a literal tab character.
String resolveTerminalTabInput({required bool shiftActive}) =>
    shiftActive ? '\x1b[Z' : '\t';

int? _ctrlCodeForCharacter(String text) {
  if (text.length != 1) {
    return null;
  }

  final codeUnit = text.codeUnitAt(0);
  if (codeUnit >= 0x61 && codeUnit <= 0x7A) {
    return codeUnit - 0x60;
  }
  if (codeUnit >= 0x40 && codeUnit <= 0x5F) {
    return codeUnit - 0x40;
  }
  if (codeUnit == 0x20) {
    return 0x00;
  }
  if (codeUnit == 0x3F) {
    return 0x7F;
  }
  return null;
}

/// Stores the toolbar modifier state independently of the widget lifecycle.
class KeyboardToolbarController extends ChangeNotifier {
  bool? _ctrlState;
  bool? _altState;
  bool? _shiftState;

  /// The current Ctrl modifier mode: off (`null`), one-shot (`false`), locked (`true`).
  bool? get ctrlState => _ctrlState;

  /// The current Alt modifier mode: off (`null`), one-shot (`false`), locked (`true`).
  bool? get altState => _altState;

  /// The current Shift modifier mode: off (`null`), one-shot (`false`), locked (`true`).
  bool? get shiftState => _shiftState;

  /// Whether Ctrl is currently active (one-shot or locked).
  bool get isCtrlActive => _ctrlState != null;

  /// Whether Alt is currently active (one-shot or locked).
  bool get isAltActive => _altState != null;

  /// Whether Shift is currently active (one-shot or locked).
  bool get isShiftActive => _shiftState != null;

  /// Toggles Ctrl between off and one-shot mode.
  void toggleCtrl() => _toggleModifier(_Modifier.ctrl);

  /// Toggles Alt between off and one-shot mode.
  void toggleAlt() => _toggleModifier(_Modifier.alt);

  /// Toggles Shift between off and one-shot mode.
  void toggleShift() => _toggleModifier(_Modifier.shift);

  /// Locks or unlocks Ctrl.
  void lockCtrl() => _lockModifier(_Modifier.ctrl);

  /// Locks or unlocks Alt.
  void lockAlt() => _lockModifier(_Modifier.alt);

  /// Locks or unlocks Shift.
  void lockShift() => _lockModifier(_Modifier.shift);

  /// Clears any one-shot modifiers while preserving locked modifiers.
  void consumeOneShot() {
    final changed = switch ((_ctrlState, _altState, _shiftState)) {
      (false, _, _) || (_, false, _) || (_, _, false) => true,
      _ => false,
    };
    if (!changed) {
      return;
    }

    if (_ctrlState case false) {
      _ctrlState = null;
    }
    if (_altState case false) {
      _altState = null;
    }
    if (_shiftState case false) {
      _shiftState = null;
    }
    notifyListeners();
  }

  /// Applies toolbar modifiers to a single system-keyboard text payload.
  ///
  /// This is used for soft-keyboard characters that reach the terminal through
  /// the regular text-input path instead of toolbar buttons or hardware keys.
  String applySystemKeyboardModifiers(String text) {
    if (text.length != 1) {
      return text;
    }

    var output = text;
    var shouldConsume = false;

    if (_ctrlState != null) {
      final ctrlCode = _ctrlCodeForCharacter(output);
      if (ctrlCode != null) {
        output = String.fromCharCode(ctrlCode);
      }
      shouldConsume = true;
    } else if (_altState != null) {
      output = '\x1b$output';
      shouldConsume = true;
    }

    if (shouldConsume) {
      consumeOneShot();
    }

    return output;
  }

  void _toggleModifier(_Modifier mod) {
    switch (mod) {
      case _Modifier.ctrl:
        _ctrlState = _ctrlState == null ? false : null;
      case _Modifier.alt:
        _altState = _altState == null ? false : null;
      case _Modifier.shift:
        _shiftState = _shiftState == null ? false : null;
    }
    notifyListeners();
  }

  void _lockModifier(_Modifier mod) {
    switch (mod) {
      case _Modifier.ctrl:
        _ctrlState = _ctrlState ?? false ? null : true;
      case _Modifier.alt:
        _altState = _altState ?? false ? null : true;
      case _Modifier.shift:
        _shiftState = _shiftState ?? false ? null : true;
    }
    notifyListeners();
  }
}

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
    this.controller,
    this.onKeyPressed,
    this.terminalFocusNode,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Optional controller that keeps modifier state stable across rebuilds.
  final KeyboardToolbarController? controller;

  /// Optional callback when any key is pressed.
  final VoidCallback? onKeyPressed;

  /// Optional focus node for the terminal. When provided, the toolbar
  /// re-requests focus after interactions so the soft keyboard stays visible.
  final FocusNode? terminalFocusNode;

  @override
  State<KeyboardToolbar> createState() => KeyboardToolbarState();
}

/// State for [KeyboardToolbar].
class KeyboardToolbarState extends State<KeyboardToolbar> {
  late final KeyboardToolbarController _fallbackController;

  KeyboardToolbarController get _controller =>
      widget.controller ?? _fallbackController;

  @override
  void initState() {
    super.initState();
    _fallbackController = KeyboardToolbarController();
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant KeyboardToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousController = oldWidget.controller ?? _fallbackController;
    final nextController = _controller;
    if (!identical(previousController, nextController)) {
      previousController.removeListener(_handleControllerChanged);
      nextController.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _fallbackController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Re-requests focus on the terminal so the soft keyboard stays visible.
  void _refocusTerminal() {
    widget.terminalFocusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keepBottomSafeArea = shouldKeepToolbarBottomSafeArea(
      MediaQuery.of(context),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        bottom: keepBottomSafeArea,
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
        icon: Icons.cancel_outlined,
        label: 'Esc',
        onTap: _sendEscape,
        onLongPressStart: _sendEscape,
        tooltip: 'Escape',
      ),
      _ToolbarButton(
        icon: Icons.keyboard_tab_rounded,
        mirrorIcon: _controller.isShiftActive,
        label: 'Tab',
        onTap: _sendTab,
        onLongPressStart: _sendTab,
        tooltip: 'Tab',
      ),
      _ModifierButton(
        icon: Icons.keyboard_control_key_rounded,
        label: 'Ctrl',
        state: _controller.ctrlState,
        onTap: _toggleCtrl,
        onDoubleTap: _lockCtrl,
        tooltip: 'Ctrl',
      ),
      _ModifierButton(
        icon: Icons.keyboard_option_key_rounded,
        label: 'Alt',
        state: _controller.altState,
        onTap: _toggleAlt,
        onDoubleTap: _lockAlt,
        tooltip: 'Alt',
      ),
      _ModifierButton(
        icon: Icons.north_rounded,
        label: 'Shift',
        state: _controller.shiftState,
        onTap: _toggleShift,
        onDoubleTap: _lockShift,
        tooltip: 'Shift',
      ),
      _ToolbarButton(label: '|', onTap: () => _sendText('|'), tooltip: 'Pipe'),
      _ToolbarButton(label: '/', onTap: () => _sendText('/'), tooltip: 'Slash'),
      _ToolbarButton(
        icon: Icons.keyboard_return_rounded,
        label: '',
        onTap: _sendEnter,
        tooltip: 'Enter',
      ),
    ],
  );

  Widget _buildNavigationRow() => _KeyRow(
    children: [..._buildArrowButtons(), ..._buildSeriesNavigationButtons()],
  );

  List<Widget> _buildSeriesNavigationButtons() => [
    _ToolbarButton(
      icon: Icons.expand_less_rounded,
      label: 'PgUp',
      onTap: () => _sendSequence('\x1b[5~'),
      onLongPressStart: () => _sendSequence('\x1b[5~'),
      onLongPressRepeat: () =>
          _sendSequence('\x1b[5~', withHaptic: false, consumeOneShot: false),
      tooltip: 'Page Up',
    ),
    _ToolbarButton(
      icon: Icons.expand_more_rounded,
      label: 'PgDn',
      onTap: () => _sendSequence('\x1b[6~'),
      onLongPressStart: () => _sendSequence('\x1b[6~'),
      onLongPressRepeat: () =>
          _sendSequence('\x1b[6~', withHaptic: false, consumeOneShot: false),
      tooltip: 'Page Down',
    ),
    _ToolbarButton(
      icon: Icons.first_page_rounded,
      label: 'Home',
      onTap: () => _sendSequence('\x1b[H'),
      onLongPressStart: () => _sendSequence('\x1b[H'),
      onLongPressRepeat: () =>
          _sendSequence('\x1b[H', withHaptic: false, consumeOneShot: false),
      tooltip: 'Home',
    ),
    _ToolbarButton(
      icon: Icons.last_page_rounded,
      label: 'End',
      onTap: () => _sendSequence('\x1b[F'),
      onLongPressStart: () => _sendSequence('\x1b[F'),
      onLongPressRepeat: () =>
          _sendSequence('\x1b[F', withHaptic: false, consumeOneShot: false),
      tooltip: 'End',
    ),
  ];

  List<Widget> _buildArrowButtons() => [
    _ToolbarButton(
      icon: Icons.arrow_back_rounded,
      label: '',
      onTap: () => _sendArrow(_Arrow.left),
      onLongPressStart: () => _sendArrow(_Arrow.left),
      onLongPressRepeat: () =>
          _sendArrow(_Arrow.left, withHaptic: false, consumeOneShot: false),
      tooltip: 'Left',
    ),
    _ToolbarButton(
      icon: Icons.arrow_forward_rounded,
      label: '',
      onTap: () => _sendArrow(_Arrow.right),
      onLongPressStart: () => _sendArrow(_Arrow.right),
      onLongPressRepeat: () =>
          _sendArrow(_Arrow.right, withHaptic: false, consumeOneShot: false),
      tooltip: 'Right',
    ),
    _ToolbarButton(
      icon: Icons.arrow_upward_rounded,
      label: '',
      onTap: () => _sendArrow(_Arrow.up),
      onLongPressStart: () => _sendArrow(_Arrow.up),
      onLongPressRepeat: () =>
          _sendArrow(_Arrow.up, withHaptic: false, consumeOneShot: false),
      tooltip: 'Up',
    ),
    _ToolbarButton(
      icon: Icons.arrow_downward_rounded,
      label: '',
      onTap: () => _sendArrow(_Arrow.down),
      onLongPressStart: () => _sendArrow(_Arrow.down),
      onLongPressRepeat: () =>
          _sendArrow(_Arrow.down, withHaptic: false, consumeOneShot: false),
      tooltip: 'Down',
    ),
  ];

  void _toggleCtrl() {
    HapticFeedback.selectionClick();
    _controller.toggleCtrl();
    _refocusTerminal();
  }

  void _toggleAlt() {
    HapticFeedback.selectionClick();
    _controller.toggleAlt();
    _refocusTerminal();
  }

  void _toggleShift() {
    HapticFeedback.selectionClick();
    _controller.toggleShift();
    _refocusTerminal();
  }

  void _lockCtrl() {
    HapticFeedback.mediumImpact();
    _controller.lockCtrl();
    _refocusTerminal();
  }

  void _lockAlt() {
    HapticFeedback.mediumImpact();
    _controller.lockAlt();
    _refocusTerminal();
  }

  void _lockShift() {
    HapticFeedback.mediumImpact();
    _controller.lockShift();
    _refocusTerminal();
  }

  void _consumeOneShot() {
    _controller.consumeOneShot();
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
    _controller.consumeOneShot();
    Future<void>.delayed(const Duration(milliseconds: 100), _refocusTerminal);
  }

  void _sendTab() {
    HapticFeedback.lightImpact();
    widget.terminal.textInput(
      resolveTerminalTabInput(shiftActive: _controller.isShiftActive),
    );
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendEnter() {
    HapticFeedback.lightImpact();
    sendTerminalEnterInput(
      widget.terminal,
      shiftActive: _controller.isShiftActive,
      altActive: _controller.isAltActive,
      ctrlActive: _controller.isCtrlActive,
    );
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendText(String text) {
    HapticFeedback.lightImpact();
    var output = text;

    if (_controller.isCtrlActive) {
      final ctrlCode = _ctrlCodeForCharacter(output);
      if (ctrlCode != null) {
        output = String.fromCharCode(ctrlCode);
      }
    }

    if (_controller.isAltActive) {
      // Alt/Meta sends ESC prefix
      output = '\x1b$output';
    }

    if (_controller.isShiftActive) {
      output = output.toUpperCase();
    }

    widget.terminal.textInput(output);
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendSequence(
    String sequence, {
    bool withHaptic = true,
    bool consumeOneShot = true,
  }) {
    if (withHaptic) {
      HapticFeedback.lightImpact();
    }
    widget.terminal.textInput(sequence);
    widget.onKeyPressed?.call();
    if (consumeOneShot) {
      _consumeOneShot();
    }
  }

  void _sendArrow(
    _Arrow arrow, {
    bool withHaptic = true,
    bool consumeOneShot = true,
  }) {
    if (withHaptic) {
      HapticFeedback.lightImpact();
    }
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
    if (consumeOneShot) {
      _consumeOneShot();
    }
  }

  String _getModifierPrefix() {
    var mod = 1;
    if (_controller.isShiftActive) mod += 1;
    if (_controller.isAltActive) mod += 2;
    if (_controller.isCtrlActive) mod += 4;
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
    this.mirrorIcon = false,
    this.onLongPressStart,
    this.onLongPressRepeat,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final bool mirrorIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressRepeat;
  final String? tooltip;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  static const _repeatInterval = Duration(milliseconds: 50);

  bool _isPressed = false;
  Timer? _repeatTimer;

  void _setPressed(bool isPressed) {
    if (_isPressed == isPressed || !mounted) {
      return;
    }
    setState(() => _isPressed = isPressed);
  }

  void _startRepeat() {
    final repeatAction = widget.onLongPressRepeat;
    if (repeatAction == null) {
      return;
    }

    _repeatTimer?.cancel();
    _setPressed(true);
    _repeatTimer = Timer.periodic(_repeatInterval, (_) {
      if (!mounted) {
        return;
      }
      repeatAction();
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _setPressed(false);
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  Widget _buildIcon(double size, Color color) {
    final icon = Icon(widget.icon, size: size, color: color);
    if (!widget.mirrorIcon) {
      return icon;
    }
    return Transform.flip(flipX: true, child: icon);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget button = GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: _stopRepeat,
      onTap: widget.onTap,
      onLongPressStart:
          widget.onLongPressStart != null || widget.onLongPressRepeat != null
          ? (_) {
              widget.onLongPressStart?.call();
              if (widget.onLongPressRepeat != null) {
                _startRepeat();
              }
            }
          : null,
      onLongPressEnd: widget.onLongPressRepeat != null
          ? (_) => _stopRepeat()
          : null,
      onLongPressCancel: widget.onLongPressRepeat != null ? _stopRepeat : null,
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
          child: widget.icon != null && widget.label.isNotEmpty
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildIcon(14, colorScheme.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                )
              : widget.icon != null
              ? _buildIcon(18, colorScheme.onSurfaceVariant)
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

class _ModifierButton extends StatefulWidget {
  const _ModifierButton({
    required this.label,
    required this.state,
    required this.onTap,
    required this.onDoubleTap,
    this.icon,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final bool? state; // null = off, false = one-shot, true = locked
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final String? tooltip;

  @override
  State<_ModifierButton> createState() => _ModifierButtonState();
}

class _ModifierButtonState extends State<_ModifierButton> {
  static const _doubleTapTimeout = Duration(milliseconds: 300);
  DateTime? _lastTapTime;

  void _handleTap() {
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < _doubleTapTimeout) {
      _lastTapTime = null;
      // Undo the single-tap toggle before applying double-tap lock,
      // so the lock/unlock sees the original state.
      widget.onTap();
      widget.onDoubleTap();
    } else {
      _lastTapTime = now;
      widget.onTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final Color bgColor;
    final Color textColor;
    final IconData? lockIcon;

    if (widget.state == null) {
      bgColor = colorScheme.surfaceContainerHighest;
      textColor = colorScheme.onSurfaceVariant;
      lockIcon = null;
    } else if (widget.state == false) {
      bgColor = colorScheme.primaryContainer;
      textColor = colorScheme.onPrimaryContainer;
      lockIcon = null;
    } else {
      bgColor = colorScheme.primary;
      textColor = colorScheme.onPrimary;
      lockIcon = Icons.lock;
    }

    Widget button = GestureDetector(
      onTap: _handleTap,
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
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: textColor),
                const SizedBox(width: 3),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
              ),
              if (lockIcon != null) ...[
                const SizedBox(width: 2),
                Icon(lockIcon, size: 10, color: textColor),
              ],
            ],
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
