import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// xterm 4.0.0 does not expose keyToTerminalKey via a public API.
// Pinned to xterm 4.0.0.
// ignore: implementation_imports
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/xterm.dart';

/// Wraps a [TerminalView] to provide soft keyboard input on mobile with
/// proper IME configuration for swipe typing.
///
/// The xterm package's built-in [CustomTextEdit] hard-codes
/// `autocorrect: false` and `enableSuggestions: false`, which causes
/// most IMEs to drop spaces between swiped words. This widget replaces
/// that text input handling with `enableSuggestions: true` so swipe
/// typing works correctly.
///
/// The child [TerminalView] should use `hardwareKeyboardOnly: true`.
class TerminalTextInputHandler extends StatefulWidget {
  /// Creates a new [TerminalTextInputHandler].
  const TerminalTextInputHandler({
    required this.terminal,
    required this.focusNode,
    required this.child,
    this.deleteDetection = false,
    this.keyboardAppearance = Brightness.dark,
    this.readOnly = false,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Focus node that controls keyboard visibility.
  final FocusNode focusNode;

  /// The [TerminalView] child (should use `hardwareKeyboardOnly: true`).
  final Widget child;

  /// Whether to use the delete-detection workaround for mobile.
  final bool deleteDetection;

  /// The appearance of the keyboard (iOS only).
  final Brightness keyboardAppearance;

  /// Whether input should be suppressed.
  final bool readOnly;

  @override
  State<TerminalTextInputHandler> createState() =>
      _TerminalTextInputHandlerState();
}

class _TerminalTextInputHandlerState extends State<TerminalTextInputHandler>
    with TextInputClient {
  TextInputConnection? _connection;
  String _lastSentText = '';

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(TerminalTextInputHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else if (oldWidget.readOnly && widget.focusNode.hasFocus) {
      _openInputConnection();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    autofocus: true,
    onKeyEvent: _onKeyEvent,
    child: widget.child,
  );

  // -- Hardware key event handling --

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (widget.readOnly) {
      return KeyEventResult.ignored;
    }

    if (!_currentEditingState.composing.isCollapsed) {
      return KeyEventResult.skipRemainingHandlers;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);
    if (key == null) {
      return KeyEventResult.ignored;
    }

    final handled = widget.terminal.keyInput(
      key,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // -- Public API --

  /// Whether a text input connection is currently active.
  bool get hasInputConnection => _connection != null && _connection!.attached;

  /// Shows the soft keyboard.
  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  /// Hides the soft keyboard.
  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  // -- Focus handling --

  void _onFocusChange() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  // -- Input connection management --

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) return;

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        inputAction: TextInputAction.newline,
        keyboardAppearance: widget.keyboardAppearance,
        // Enable suggestions so the IME adds spaces between swiped words.
        // ignore: avoid_redundant_argument_values
        enableSuggestions: true,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);
      _connection!.show();
      _lastSentText = '';
      _currentEditingState = _initEditingState.copyWith();
      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
    _lastSentText = '';
    _currentEditingState = _initEditingState.copyWith();
  }

  // -- Editing state --

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : TextEditingValue.empty;

  late TextEditingValue _currentEditingState = _initEditingState.copyWith();

  int _commonPrefixLength(String a, String b) {
    final maxLength = a.length < b.length ? a.length : b.length;
    var index = 0;
    while (index < maxLength && a.codeUnitAt(index) == b.codeUnitAt(index)) {
      index++;
    }
    return index;
  }

  String _extractInputText(String text) {
    final initText = _initEditingState.text;
    if (text.startsWith(initText)) {
      return text.substring(initText.length);
    }
    return text;
  }

  void _sendInputDelta(String currentText) {
    final commonPrefix = _commonPrefixLength(_lastSentText, currentText);
    final deletedCount = _lastSentText.length - commonPrefix;

    for (var i = 0; i < deletedCount; i++) {
      widget.terminal.keyInput(TerminalKey.backspace);
    }

    final appendedText = currentText.substring(commonPrefix);
    if (appendedText.isNotEmpty) {
      widget.terminal.textInput(appendedText);
    }

    _lastSentText = currentText;
  }

  // -- TextInputClient implementation --

  @override
  TextEditingValue? get currentTextEditingValue => _currentEditingState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (widget.readOnly) return;

    _currentEditingState = value;

    // Handle composing (IME input in progress).
    if (!_currentEditingState.composing.isCollapsed) {
      return;
    }

    if (_currentEditingState.text.length < _initEditingState.text.length) {
      widget.terminal.keyInput(TerminalKey.backspace);
      _lastSentText = '';
    } else {
      _sendInputDelta(_extractInputText(_currentEditingState.text));
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (widget.readOnly) return;

    if (action == TextInputAction.newline || action == TextInputAction.done) {
      widget.terminal.keyInput(TerminalKey.enter);
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void connectionClosed() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}
}
