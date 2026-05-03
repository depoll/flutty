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

/// Whether the extra-keys toolbar should collapse to a single row.
///
/// In landscape, vertical space is tighter and the toolbar behaves more like a
/// keyboard extension on compact screens, so it should stay to one
/// horizontally scrollable row.
bool shouldUseSingleRowKeyboardToolbar(MediaQueryData mediaQuery) =>
    mediaQuery.orientation == Orientation.landscape &&
    mediaQuery.size.shortestSide < 600;

/// Resolves the total rendered height of the keyboard toolbar.
double resolveKeyboardToolbarHeight(MediaQueryData mediaQuery) {
  final rowCount = shouldUseSingleRowKeyboardToolbar(mediaQuery) ? 1 : 2;
  final bottomInset = shouldKeepToolbarBottomSafeArea(mediaQuery)
      ? mediaQuery.padding.bottom
      : 0.0;
  return rowCount * _KeyRow.height + bottomInset;
}

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
    this.onPasteRequested,
    this.onPasteImageRequested,
    this.onPasteFilesRequested,
    this.terminalFocusNode,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Optional controller that keeps modifier state stable across rebuilds.
  final KeyboardToolbarController? controller;

  /// Optional callback when any key is pressed.
  final VoidCallback? onKeyPressed;

  /// Optional callback when the Paste key is tapped.
  final FutureOr<void> Function()? onPasteRequested;

  /// Optional callback when the Paste key's long-press image option is tapped.
  final FutureOr<void> Function()? onPasteImageRequested;

  /// Optional callback when the Paste key's long-press file option is tapped.
  final FutureOr<void> Function()? onPasteFilesRequested;

  /// Optional focus node for the terminal. When provided, the toolbar
  /// re-requests focus after interactions so the soft keyboard stays visible.
  final FocusNode? terminalFocusNode;

  @override
  State<KeyboardToolbar> createState() => KeyboardToolbarState();
}

/// State for [KeyboardToolbar].
class KeyboardToolbarState extends State<KeyboardToolbar> {
  static const _pasteOptionsWidth = 220.0;
  static const _pasteOptionHeight = 44.0;
  static const _pasteOptionsGap = 8.0;
  static const _pasteOptionsScreenMargin = 8.0;

  late final KeyboardToolbarController _fallbackController;
  final _pasteButtonKey = GlobalKey();
  OverlayEntry? _pasteOptionsOverlay;
  _PasteToolbarAction? _highlightedPasteAction;

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
    _hidePasteOptionsMenu();
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
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keepBottomSafeArea = shouldKeepToolbarBottomSafeArea(mediaQuery);
    final useSingleRow = shouldUseSingleRowKeyboardToolbar(mediaQuery);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        bottom: keepBottomSafeArea,
        child: useSingleRow
            ? _buildLandscapeRow()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [_buildModifierRow(), _buildNavigationRow()],
              ),
      ),
    );
  }

  Widget _buildModifierRow() => _KeyRow(children: _buildModifierButtons());

  Widget _buildNavigationRow() => _KeyRow(
    children: [
      ..._buildArrowButtons(),
      ..._buildSeriesNavigationButtons(),
      _buildEnterButton(),
    ],
  );

  Widget _buildLandscapeRow() => _KeyRow(
    children: [
      ..._buildModifierButtons(),
      ..._buildArrowButtons(),
      ..._buildSeriesNavigationButtons(),
      _buildEnterButton(),
    ],
  );

  Widget _buildEnterButton() => _ToolbarButton(
    icon: Icons.keyboard_return_rounded,
    label: '',
    onTap: _sendEnter,
    tooltip: 'Enter',
  );

  List<Widget> _buildModifierButtons() => [
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
    _ToolbarButton(label: '~', onTap: () => _sendText('~'), tooltip: 'Tilde'),
    _ToolbarButton(
      key: _pasteButtonKey,
      icon: Icons.paste_rounded,
      label: 'Paste',
      onTap: _pasteClipboard,
      onLongPressStartWithDetails: _showPasteOptions,
      onLongPressMoveUpdate: _updatePasteOptionsHighlight,
      onLongPressEnd: _chooseHighlightedPasteOption,
      onLongPressCancel: _hidePasteOptionsMenu,
      tooltip: 'Paste',
    ),
  ];

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

  void _pasteClipboard() {
    HapticFeedback.lightImpact();
    widget.onKeyPressed?.call();
    _consumeOneShot();
    unawaited(_runToolbarAction(widget.onPasteRequested));
  }

  void _showPasteOptions(LongPressStartDetails details) {
    HapticFeedback.mediumImpact();
    widget.onKeyPressed?.call();
    _consumeOneShot();
    _showPasteOptionsMenu(details.globalPosition);
  }

  void _showPasteOptionsMenu(Offset globalPosition) {
    final overlay = Overlay.of(context);
    final buttonRect = _pasteButtonGlobalRect();
    if (buttonRect == null) {
      return;
    }
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return;
    }

    final overlaySize = overlayBox.size;
    final topLeft = overlayBox.globalToLocal(buttonRect.topLeft);
    final bottomRight = overlayBox.globalToLocal(buttonRect.bottomRight);
    final targetRect = Rect.fromPoints(topLeft, bottomRight);
    final menuHeight = _PasteToolbarAction.values.length * _pasteOptionHeight;
    final left = _clampDouble(
      targetRect.right - _pasteOptionsWidth,
      _pasteOptionsScreenMargin,
      overlaySize.width - _pasteOptionsWidth - _pasteOptionsScreenMargin,
    );
    final top = _clampDouble(
      targetRect.top - menuHeight - _pasteOptionsGap,
      _pasteOptionsScreenMargin,
      overlaySize.height - menuHeight - _pasteOptionsScreenMargin,
    );
    _hidePasteOptionsMenu();
    _highlightedPasteAction = _pasteActionAtGlobalPosition(
      globalPosition,
      menuOrigin: overlayBox.localToGlobal(Offset(left, top)),
    );
    _pasteOptionsOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        width: _pasteOptionsWidth,
        child: _PasteOptionsMenu(
          highlightedAction: _highlightedPasteAction,
          imageEnabled: widget.onPasteImageRequested != null,
          filesEnabled: widget.onPasteFilesRequested != null,
        ),
      ),
    );
    overlay.insert(_pasteOptionsOverlay!);
  }

  Rect? _pasteButtonGlobalRect() {
    final renderObject = _pasteButtonKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _updatePasteOptionsHighlight(LongPressMoveUpdateDetails details) {
    final action = _pasteActionAtGlobalPosition(details.globalPosition);
    if (action == _highlightedPasteAction) {
      return;
    }
    _highlightedPasteAction = action;
    _pasteOptionsOverlay?.markNeedsBuild();
  }

  _PasteToolbarAction? _pasteActionAtGlobalPosition(
    Offset globalPosition, {
    Offset? menuOrigin,
  }) {
    final overlay = _pasteOptionsOverlay;
    if (overlay == null && menuOrigin == null) {
      return null;
    }
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return null;
    }
    final offset = menuOrigin == null
        ? _pasteOptionsOverlayOffset(overlayBox.size)
        : null;
    if (menuOrigin == null && offset == null) {
      return null;
    }
    final origin = menuOrigin ?? overlayBox.localToGlobal(offset!);
    final local = globalPosition - origin;
    if (local.dx < 0 || local.dx > _pasteOptionsWidth || local.dy < 0) {
      return null;
    }
    final index = local.dy ~/ _pasteOptionHeight;
    if (index < 0 || index >= _PasteToolbarAction.values.length) {
      return null;
    }
    final action = _PasteToolbarAction.values[index];
    return _isPasteActionEnabled(action) ? action : null;
  }

  Offset? _pasteOptionsOverlayOffset(Size overlaySize) {
    final buttonRect = _pasteButtonGlobalRect();
    if (buttonRect == null) {
      return null;
    }
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return null;
    }
    final topLeft = overlayBox.globalToLocal(buttonRect.topLeft);
    final bottomRight = overlayBox.globalToLocal(buttonRect.bottomRight);
    final targetRect = Rect.fromPoints(topLeft, bottomRight);
    final menuHeight = _PasteToolbarAction.values.length * _pasteOptionHeight;
    return Offset(
      _clampDouble(
        targetRect.right - _pasteOptionsWidth,
        _pasteOptionsScreenMargin,
        overlaySize.width - _pasteOptionsWidth - _pasteOptionsScreenMargin,
      ),
      _clampDouble(
        targetRect.top - menuHeight - _pasteOptionsGap,
        _pasteOptionsScreenMargin,
        overlaySize.height - menuHeight - _pasteOptionsScreenMargin,
      ),
    );
  }

  bool _isPasteActionEnabled(_PasteToolbarAction action) => switch (action) {
    _PasteToolbarAction.images => widget.onPasteImageRequested != null,
    _PasteToolbarAction.files => widget.onPasteFilesRequested != null,
  };

  void _chooseHighlightedPasteOption(LongPressEndDetails details) {
    final action =
        _pasteActionAtGlobalPosition(details.globalPosition) ??
        _highlightedPasteAction;
    _hidePasteOptionsMenu();
    switch (action) {
      case _PasteToolbarAction.images:
        unawaited(_runToolbarAction(widget.onPasteImageRequested));
      case _PasteToolbarAction.files:
        unawaited(_runToolbarAction(widget.onPasteFilesRequested));
      case null:
        _refocusTerminal();
    }
  }

  void _hidePasteOptionsMenu() {
    _pasteOptionsOverlay?.remove();
    _pasteOptionsOverlay = null;
    _highlightedPasteAction = null;
  }

  Future<void> _runToolbarAction(FutureOr<void> Function()? action) async {
    if (action == null) {
      _refocusTerminal();
      return;
    }
    await action();
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

enum _PasteToolbarAction { images, files }

double _clampDouble(double value, double min, double max) {
  final effectiveMax = max < min ? min : max;
  return value.clamp(min, effectiveMax);
}

class _PasteOptionsMenu extends StatelessWidget {
  const _PasteOptionsMenu({
    required this.highlightedAction,
    required this.imageEnabled,
    required this.filesEnabled,
  });

  final _PasteToolbarAction? highlightedAction;
  final bool imageEnabled;
  final bool filesEnabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PasteOptionsMenuItem(
            icon: Icons.image_outlined,
            label: 'Paste Images',
            enabled: imageEnabled,
            highlighted: highlightedAction == _PasteToolbarAction.images,
          ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          _PasteOptionsMenuItem(
            icon: Icons.attach_file_rounded,
            label: 'Paste Files',
            enabled: filesEnabled,
            highlighted: highlightedAction == _PasteToolbarAction.files,
          ),
        ],
      ),
    );
  }
}

class _PasteOptionsMenuItem extends StatelessWidget {
  const _PasteOptionsMenuItem({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.highlighted,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final contentColor = enabled
        ? colorScheme.onSurfaceVariant
        : colorScheme.onSurfaceVariant.withAlpha(96);
    final backgroundColor = highlighted && enabled
        ? colorScheme.primaryContainer
        : Colors.transparent;
    final foregroundColor = highlighted && enabled
        ? colorScheme.onPrimaryContainer
        : contentColor;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: highlighted,
      label: label,
      child: Container(
        height: KeyboardToolbarState._pasteOptionHeight,
        color: backgroundColor,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: foregroundColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foregroundColor,
                  fontWeight: highlighted ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children});

  static const height = 42.0;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
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
    this.onLongPressStartWithDetails,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onLongPressCancel,
    this.onLongPressRepeat,
    this.tooltip,
    super.key,
  });

  final String label;
  final IconData? icon;
  final bool mirrorIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final GestureLongPressStartCallback? onLongPressStartWithDetails;
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;
  final VoidCallback? onLongPressRepeat;
  final String? tooltip;

  bool get hasLongPressHandler =>
      onLongPressStart != null ||
      onLongPressStartWithDetails != null ||
      onLongPressMoveUpdate != null ||
      onLongPressEnd != null ||
      onLongPressCancel != null ||
      onLongPressRepeat != null;

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
      onLongPressStart: widget.hasLongPressHandler
          ? (details) {
              widget.onLongPressStart?.call();
              widget.onLongPressStartWithDetails?.call(details);
              if (widget.onLongPressRepeat != null) {
                _startRepeat();
              }
            }
          : null,
      onLongPressMoveUpdate: widget.onLongPressMoveUpdate,
      onLongPressEnd: widget.hasLongPressHandler
          ? (details) {
              widget.onLongPressEnd?.call(details);
              _stopRepeat();
            }
          : null,
      onLongPressCancel: widget.hasLongPressHandler
          ? () {
              widget.onLongPressCancel?.call();
              _stopRepeat();
            }
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
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
        ),
      ),
    );

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return Semantics(
      button: true,
      label: widget.tooltip ?? widget.label,
      child: button,
    );
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
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
        ),
      ),
    );

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return Semantics(
      button: true,
      label: widget.tooltip ?? widget.label,
      toggled: widget.state != null,
      value: switch (widget.state) {
        null => 'off',
        false => 'one-shot',
        true => 'locked',
      },
      child: button,
    );
  }
}
