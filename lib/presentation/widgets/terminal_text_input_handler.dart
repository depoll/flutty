import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// xterm 4.0.0 does not expose keyToTerminalKey via a public API.
// Pinned to xterm 4.0.0.
// ignore: implementation_imports
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/xterm.dart';

import '../../domain/models/auto_connect_command.dart';

const _deleteDetectionMarker = '\u200B\u200B';
final _leadingSwipeNewlineArtifactPattern = RegExp(r'^[\r\n]+ ?(?=\S)');

/// Confirms suspicious text inserted through the system keyboard or IME.
typedef TerminalTextInputReviewCallback =
    Future<bool> Function(TerminalCommandReview review);

/// Whether a pointer-up event should request the terminal soft keyboard.
///
/// Touch input should only open the keyboard after a tap-like gesture. Scrolls
/// and pinches must not reopen the IME after it has been dismissed.
@visibleForTesting
bool shouldRequestKeyboardForTerminalPointerUp({
  required PointerDeviceKind pointerKind,
  required int activeTouchPointers,
  required bool hadMultipleTouchPointers,
  required bool movedBeyondTapSlop,
  required bool readOnly,
}) {
  if (readOnly) {
    return false;
  }

  if (pointerKind != PointerDeviceKind.touch) {
    return true;
  }

  return activeTouchPointers == 1 &&
      !hadMultipleTouchPointers &&
      !movedBeyondTapSlop;
}

/// Controls a [TerminalTextInputHandler] from an ancestor widget.
class TerminalTextInputHandlerController {
  _TerminalTextInputHandlerState? _state;

  // ignore: use_setters_to_change_properties
  void _attach(_TerminalTextInputHandlerState state) {
    _state = state;
  }

  void _detach(_TerminalTextInputHandlerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  /// Prevents the next touch tap-up from reopening the soft keyboard.
  void suppressNextTouchKeyboardRequest() {
    _state?._suppressNextTouchKeyboardRequest();
  }
}

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
    this.controller,
    this.deleteDetection = false,
    this.keyboardAppearance = Brightness.dark,
    this.onUserInput,
    this.onReviewInsertedText,
    this.readOnly = false,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Focus node that controls keyboard visibility.
  final FocusNode focusNode;

  /// The [TerminalView] child (should use `hardwareKeyboardOnly: true`).
  final Widget child;

  /// Optional controller for externally coordinating touch/keyboard behavior.
  final TerminalTextInputHandlerController? controller;

  /// Whether to use the delete-detection workaround for mobile.
  final bool deleteDetection;

  /// The appearance of the keyboard (iOS only).
  final Brightness keyboardAppearance;

  /// Called when user input has been accepted for sending to the terminal.
  final VoidCallback? onUserInput;

  /// Called before suspicious multi-character IME insertions are sent.
  final TerminalTextInputReviewCallback? onReviewInsertedText;

  /// Whether input should be suppressed.
  final bool readOnly;

  @override
  State<TerminalTextInputHandler> createState() =>
      _TerminalTextInputHandlerState();
}

class _TerminalTextInputHandlerState extends State<TerminalTextInputHandler>
    with TextInputClient {
  TextInputConnection? _connection;
  final Set<int> _activeTouchPointers = <int>{};
  final Map<int, Offset> _touchPointerDownPositions = <int, Offset>{};
  final Set<int> _touchPointersMovedBeyondTapSlop = <int>{};
  bool _touchSequenceHadMultiplePointers = false;
  bool _skipNextTouchKeyboardRequest = false;
  bool _sawImeComposition = false;
  String _lastSentText = '';
  int _pendingEnterActionSuppressions = 0;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(TerminalTextInputHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else if (oldWidget.readOnly && widget.focusNode.hasFocus) {
      _openInputConnection();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    widget.focusNode.removeListener(_onFocusChange);
    _activeTouchPointers.clear();
    _touchPointerDownPositions.clear();
    _touchPointersMovedBeyondTapSlop.clear();
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _handlePointerDown,
    onPointerMove: _handlePointerMove,
    onPointerUp: _handlePointerUp,
    onPointerCancel: _handlePointerCancel,
    child: Focus(
      focusNode: widget.focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    ),
  );

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouchPointers.add(event.pointer);
      _touchPointerDownPositions[event.pointer] = event.position;
      if (_activeTouchPointers.length > 1) {
        _touchSequenceHadMultiplePointers = true;
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch ||
        _touchPointersMovedBeyondTapSlop.contains(event.pointer)) {
      return;
    }

    final startPosition = _touchPointerDownPositions[event.pointer];
    if (startPosition == null) {
      return;
    }

    final delta = event.position - startPosition;
    if (delta.distance > kTouchSlop) {
      _touchPointersMovedBeyondTapSlop.add(event.pointer);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    final shouldRequestKeyboard = shouldRequestKeyboardForTerminalPointerUp(
      pointerKind: event.kind,
      activeTouchPointers: _activeTouchPointers.length,
      hadMultipleTouchPointers: _touchSequenceHadMultiplePointers,
      movedBeyondTapSlop: _touchPointersMovedBeyondTapSlop.contains(
        event.pointer,
      ),
      readOnly: widget.readOnly,
    );
    final shouldSkipKeyboardRequest =
        event.kind == PointerDeviceKind.touch && _skipNextTouchKeyboardRequest;
    if (event.kind == PointerDeviceKind.touch) {
      _skipNextTouchKeyboardRequest = false;
    }
    _clearPointerTracking(event);
    if (shouldRequestKeyboard && !shouldSkipKeyboardRequest) {
      requestKeyboard();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _skipNextTouchKeyboardRequest = false;
    }
    _clearPointerTracking(event);
  }

  void _clearPointerTracking(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }

    _activeTouchPointers.remove(event.pointer);
    _touchPointerDownPositions.remove(event.pointer);
    _touchPointersMovedBeyondTapSlop.remove(event.pointer);
    if (_activeTouchPointers.isEmpty) {
      _touchSequenceHadMultiplePointers = false;
    }
  }

  void _notifyUserInput() {
    widget.onUserInput?.call();
  }

  // -- Hardware key event handling --

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (widget.readOnly) {
      return KeyEventResult.ignored;
    }

    final hasShortcutModifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!_currentEditingState.composing.isCollapsed && !hasShortcutModifier) {
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

    if (handled) {
      _notifyUserInput();
    }

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

  void _suppressNextTouchKeyboardRequest() {
    _skipNextTouchKeyboardRequest = true;
  }

  // -- Focus handling --

  void _onFocusChange() {
    if (widget.focusNode.hasFocus) {
      final consumedKeyboardToken = widget.focusNode.consumeKeyboardToken();
      if (!hasInputConnection || consumedKeyboardToken) {
        _openInputConnection();
      }
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
        // Keep these explicit because terminal IME behavior is central here.
        // ignore: avoid_redundant_argument_values
        autocorrect: false,
        inputAction: TextInputAction.newline,
        keyboardAppearance: widget.keyboardAppearance,
        // Enable suggestions so the IME adds spaces between swiped words.
        // ignore: avoid_redundant_argument_values
        enableSuggestions: true,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);
      _connection!.show();
      _sawImeComposition = false;
      _lastSentText = '';
      _pendingEnterActionSuppressions = 0;
      _currentEditingState = _initEditingState.copyWith();
      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
    _sawImeComposition = false;
    _lastSentText = '';
    _pendingEnterActionSuppressions = 0;
    _currentEditingState = _initEditingState.copyWith();
  }

  // -- Editing state --

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length,
          ),
        )
      : TextEditingValue.empty;

  late TextEditingValue _currentEditingState = _initEditingState.copyWith();

  int _editingPrefixLength(String text) {
    if (!widget.deleteDetection) {
      return 0;
    }

    var prefixLength = 0;
    while (prefixLength < text.length &&
        prefixLength < _deleteDetectionMarker.length &&
        text.codeUnitAt(prefixLength) ==
            _deleteDetectionMarker.codeUnitAt(prefixLength)) {
      prefixLength++;
    }
    return prefixLength;
  }

  int _commonPrefixLength(String a, String b) {
    final maxLength = a.length < b.length ? a.length : b.length;
    var index = 0;
    while (index < maxLength && a.codeUnitAt(index) == b.codeUnitAt(index)) {
      index++;
    }
    return index;
  }

  String _extractRawInputText(String text) =>
      text.substring(_editingPrefixLength(text));

  String _extractInputText(String text) {
    final extractedText = _extractRawInputText(text);
    if (_lastSentText.isNotEmpty) {
      return extractedText;
    }
    final sanitizedText = extractedText.replaceFirst(
      _leadingSwipeNewlineArtifactPattern,
      '',
    );
    if (_sawImeComposition &&
        sanitizedText.startsWith(' ') &&
        !sanitizedText.startsWith('  ') &&
        sanitizedText.trimLeft().isNotEmpty) {
      return sanitizedText.substring(1);
    }
    return sanitizedText;
  }

  int _sendInputDelta(String currentText) {
    final delta = _computeTextDelta(currentText);
    final deletedCount = delta.deletedCount;

    for (var i = 0; i < deletedCount; i++) {
      widget.terminal.keyInput(TerminalKey.backspace);
    }

    final appendedText = delta.appendedText;
    if (appendedText.isNotEmpty) {
      widget.terminal.textInput(appendedText);
    }

    _lastSentText = currentText;
    return '\n'.allMatches(appendedText).length;
  }

  ({int deletedCount, String appendedText}) _computeTextDelta(
    String currentText,
  ) {
    final commonPrefix = _commonPrefixLength(_lastSentText, currentText);
    return (
      deletedCount: _lastSentText.length - commonPrefix,
      appendedText: currentText.substring(commonPrefix),
    );
  }

  TerminalCommandReview? _reviewForInsertedText(
    TextEditingValue value,
    String currentText,
  ) {
    if (widget.onReviewInsertedText == null ||
        _sawImeComposition ||
        !value.selection.isCollapsed) {
      return null;
    }

    final delta = _computeTextDelta(currentText);
    if (delta.appendedText.length <= 1) {
      return null;
    }

    final review = assessClipboardPasteCommand(
      delta.appendedText,
      bracketedPasteModeEnabled: false,
    );
    return review.requiresReview ? review : null;
  }

  int _clampTextOffset(int offset, int maxOffset) {
    if (offset < 0) {
      return 0;
    }
    if (offset > maxOffset) {
      return maxOffset;
    }
    return offset;
  }

  int _normalizeUserOffset({
    required int rawOffset,
    required int rawPrefixLength,
    required int trimmedLeadingCharacters,
    required int userTextLength,
  }) => _clampTextOffset(
    rawOffset - rawPrefixLength - trimmedLeadingCharacters,
    userTextLength,
  );

  TextSelection? _normalizeSelectionForUserText({
    required TextSelection selection,
    required int rawPrefixLength,
    required int trimmedLeadingCharacters,
    required int userTextLength,
  }) {
    if (!selection.isValid) {
      return null;
    }

    return TextSelection(
      baseOffset: _normalizeUserOffset(
        rawOffset: selection.baseOffset,
        rawPrefixLength: rawPrefixLength,
        trimmedLeadingCharacters: trimmedLeadingCharacters,
        userTextLength: userTextLength,
      ),
      extentOffset: _normalizeUserOffset(
        rawOffset: selection.extentOffset,
        rawPrefixLength: rawPrefixLength,
        trimmedLeadingCharacters: trimmedLeadingCharacters,
        userTextLength: userTextLength,
      ),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  TextRange _normalizeComposingForUserText({
    required TextRange composing,
    required int rawPrefixLength,
    required int trimmedLeadingCharacters,
    required int userTextLength,
  }) {
    if (!composing.isValid || composing.isCollapsed) {
      return TextRange.empty;
    }

    final start = _normalizeUserOffset(
      rawOffset: composing.start,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: userTextLength,
    );
    final end = _normalizeUserOffset(
      rawOffset: composing.end,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: userTextLength,
    );
    if (start >= end) {
      return TextRange.empty;
    }
    return TextRange(start: start, end: end);
  }

  TextEditingValue _editingStateForUserText({
    required String userText,
    TextSelection? userSelection,
    TextRange userComposing = TextRange.empty,
  }) {
    final prefixLength = widget.deleteDetection
        ? _initEditingState.text.length
        : 0;
    final text = widget.deleteDetection
        ? '${_initEditingState.text}$userText'
        : userText;
    final selection = userSelection == null
        ? TextSelection.collapsed(offset: prefixLength + userText.length)
        : TextSelection(
            baseOffset: prefixLength + userSelection.baseOffset,
            extentOffset: prefixLength + userSelection.extentOffset,
            affinity: userSelection.affinity,
            isDirectional: userSelection.isDirectional,
          );
    final composing = userComposing.isValid && !userComposing.isCollapsed
        ? TextRange(
            start: prefixLength + userComposing.start,
            end: prefixLength + userComposing.end,
          )
        : TextRange.empty;
    return TextEditingValue(
      text: text,
      selection: selection,
      composing: composing,
    );
  }

  void _syncEditingStateWithUserText(
    String userText, {
    TextEditingValue? sourceValue,
  }) {
    final rawPrefixLength = sourceValue == null
        ? _initEditingState.text.length
        : _editingPrefixLength(sourceValue.text);
    final rawUserText = sourceValue == null
        ? userText
        : _extractRawInputText(sourceValue.text);
    final trimmedLeadingCharacters = rawUserText.length - userText.length;
    final userSelection = sourceValue == null
        ? null
        : _normalizeSelectionForUserText(
            selection: sourceValue.selection,
            rawPrefixLength: rawPrefixLength,
            trimmedLeadingCharacters: trimmedLeadingCharacters,
            userTextLength: userText.length,
          );
    final userComposing = sourceValue == null
        ? TextRange.empty
        : _normalizeComposingForUserText(
            composing: sourceValue.composing,
            rawPrefixLength: rawPrefixLength,
            trimmedLeadingCharacters: trimmedLeadingCharacters,
            userTextLength: userText.length,
          );
    final nextState = _editingStateForUserText(
      userText: userText,
      userSelection: userSelection,
      userComposing: userComposing,
    );
    final shouldResyncText =
        sourceValue == null || sourceValue.text != nextState.text;
    _currentEditingState = nextState;
    if (shouldResyncText && hasInputConnection) {
      _connection!.setEditingState(nextState);
    }
  }

  // -- TextInputClient implementation --

  @override
  TextEditingValue? get currentTextEditingValue => _currentEditingState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    unawaited(_updateEditingValue(value));
  }

  Future<void> _updateEditingValue(TextEditingValue value) async {
    if (widget.readOnly) return;

    _currentEditingState = value;

    // Handle composing (IME input in progress).
    if (!_currentEditingState.composing.isCollapsed) {
      _sawImeComposition = true;
      return;
    }

    if (_currentEditingState.text.length < _initEditingState.text.length) {
      _notifyUserInput();
      widget.terminal.keyInput(TerminalKey.backspace);
      _sawImeComposition = false;
      _lastSentText = '';
      _pendingEnterActionSuppressions = 0;
      _syncEditingStateWithUserText('');
      return;
    }

    final currentText = _extractInputText(_currentEditingState.text);
    final review = _reviewForInsertedText(value, currentText);
    if (review != null) {
      final shouldInsert = await widget.onReviewInsertedText!(review);
      if (!mounted) {
        return;
      }
      if (!shouldInsert) {
        _syncEditingStateWithUserText(_lastSentText);
        _sawImeComposition = false;
        return;
      }
    }

    if (currentText != _lastSentText) {
      _notifyUserInput();
    }
    _pendingEnterActionSuppressions += _sendInputDelta(currentText);
    _syncEditingStateWithUserText(currentText, sourceValue: value);
    _sawImeComposition = false;
  }

  @override
  void performAction(TextInputAction action) {
    if (widget.readOnly) return;

    if (action == TextInputAction.newline || action == TextInputAction.done) {
      if (_pendingEnterActionSuppressions > 0) {
        _pendingEnterActionSuppressions--;
        return;
      }
      _notifyUserInput();
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
  void connectionClosed() {
    _connection = null;
    _sawImeComposition = false;
    _lastSentText = '';
    _pendingEnterActionSuppressions = 0;
    _currentEditingState = _initEditingState.copyWith();
    if (!widget.readOnly && widget.focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.focusNode.hasFocus) {
          _openInputConnection();
        }
      });
    }
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}
}
