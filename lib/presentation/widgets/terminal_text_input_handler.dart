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
const _enterCommitNewlineSequences = <String>['\r\n', '\n', '\r'];

/// Confirms suspicious text inserted through the system keyboard or IME.
typedef TerminalTextInputReviewCallback =
    Future<bool> Function(TerminalCommandReview review);

/// Builds the command text that should be reviewed for a pending IME delta.
typedef TerminalTextInputReviewTextBuilder =
    String Function(
      ({int deletedCount, String appendedText}) delta,
      String currentText,
    );

/// Resolves the current terminal text that appears before the cursor.
typedef TerminalTextBeforeCursorResolver = String? Function();

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

  /// Explicitly shows the soft keyboard.
  ///
  /// This always opens the keyboard regardless of the
  /// [TerminalTextInputHandler.tapToShowKeyboard] setting and is intended for
  /// toolbar buttons or programmatic triggers.
  void requestKeyboard() {
    _state?.requestKeyboard();
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
    this.buildReviewTextForInsertedText,
    this.resolveTextBeforeCursor,
    this.hasActiveToolbarModifier,
    this.readOnly = false,
    this.tapToShowKeyboard = true,
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

  /// Builds the command text that should be reviewed for suspicious IME input.
  final TerminalTextInputReviewTextBuilder? buildReviewTextForInsertedText;

  /// Resolves the current terminal text that appears before the cursor.
  ///
  /// This lets the IME handler distinguish a stray leading swipe space from the
  /// only separator needed between existing terminal text and the next word.
  final TerminalTextBeforeCursorResolver? resolveTextBeforeCursor;

  /// Whether a toolbar modifier (Ctrl or Alt) is currently active.
  ///
  /// When a modifier is active, a typed character becomes a control code rather
  /// than visible text. In that case the IME buffer is cleared after sending
  /// the input so that stale suggestions don't accumulate from non-text input.
  final ValueGetter<bool>? hasActiveToolbarModifier;

  /// Whether input should be suppressed.
  final bool readOnly;

  /// Whether tapping the terminal should show the keyboard.
  ///
  /// When `false`, touch taps are ignored for keyboard purposes; the keyboard
  /// can still be opened via [requestKeyboard] (e.g. from a toolbar button).
  final bool tapToShowKeyboard;

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
  bool _isProcessingEditingValue = false;
  bool _lastProcessedUserSelectionWasValid = false;
  bool _lastProcessedSelectionWasCollapsed = true;
  bool _trimLeadingSuggestionSpaceAfterDelete = false;
  bool _trimLeadingSwipeSpaceAfterBufferClear = false;
  bool _resetNextInputAfterModifierChord = false;
  String _lastSentText = '';
  int _lastSentCursorOffset = 0;
  String? _pendingPerformedEnterText;
  int _pendingEnterActionSuppressions = 0;
  int _latestEditingValueRevision = 0;
  TextEditingValue? _queuedEditingValue;

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
      _openInputConnection(show: widget.tapToShowKeyboard);
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
    final shouldSkipTapToShow =
        event.kind == PointerDeviceKind.touch && !widget.tapToShowKeyboard;
    if (event.kind == PointerDeviceKind.touch) {
      _skipNextTouchKeyboardRequest = false;
    }
    _clearPointerTracking(event);
    if (shouldRequestKeyboard &&
        !shouldSkipKeyboardRequest &&
        !shouldSkipTapToShow) {
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

  void _trackHandledHardwareCursorKey(
    TerminalKey key, {
    required bool hasShortcutModifier,
  }) {
    if (hasShortcutModifier) {
      return;
    }

    final maxOffset = _textLengthInGraphemes(_lastSentText);
    switch (key) {
      case TerminalKey.arrowLeft:
        _lastSentCursorOffset = _clampTextOffset(
          _lastSentCursorOffset - 1,
          maxOffset,
        );
        return;
      case TerminalKey.arrowRight:
        _lastSentCursorOffset = _clampTextOffset(
          _lastSentCursorOffset + 1,
          maxOffset,
        );
        return;
      case TerminalKey.arrowUp:
      case TerminalKey.arrowDown:
        if (_lastSentText.isNotEmpty || _lastSentCursorOffset != 0) {
          _resetCommittedInputState();
        }
        return;
      default:
        return;
    }
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
      _trackHandledHardwareCursorKey(
        key,
        hasShortcutModifier: hasShortcutModifier,
      );
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // -- Public API --

  /// Whether a text input connection is currently active.
  bool get hasInputConnection => _connection != null && _connection!.attached;

  /// Shows the soft keyboard.
  void requestKeyboard() {
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
    // Always show — this is an explicit request (e.g. from a toolbar button).
    _openInputConnection();
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
        // Attach the input connection but only show the soft keyboard when
        // tap-to-show is enabled.  Explicit keyboard requests go through
        // requestKeyboard() which always passes show: true.
        _openInputConnection(show: widget.tapToShowKeyboard);
      }
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  // -- Input connection management --

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _invalidatePendingEditingUpdates() {
    _latestEditingValueRevision++;
    _queuedEditingValue = null;
  }

  /// Reconnects the IME text-input connection to clear the suggestion /
  /// prediction context while keeping the current buffer tracking intact.
  ///
  /// Creating a fresh [TextInputConnection] forces Android and iOS to
  /// discard their accumulated typing history, which clears the prediction
  /// bar. The keyboard stays visible because we re-attach and call `show()`
  /// without resigning first-responder status.
  void _reconnectInputToResetSuggestions() {
    if (!hasInputConnection) return;

    // Detach the current connection.
    _connection!.close();
    _connection = null;

    // Discard any queued editing values that were generated before the
    // reconnect — they reference the old connection's state.
    _invalidatePendingEditingUpdates();

    // Recreate the connection with the same configuration.
    final config = TextInputConfiguration(
      // ignore: avoid_redundant_argument_values
      autocorrect: false,
      inputAction: TextInputAction.newline,
      keyboardAppearance: widget.keyboardAppearance,
      // ignore: avoid_redundant_argument_values
      enableSuggestions: true,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      enableIMEPersonalizedLearning: false,
    );
    _connection = TextInput.attach(this, config);
    _connection!.show();

    // Convert the grapheme-based cursor offset to a code-unit offset so
    // the selection is placed correctly in the re-synced editing state.
    final cursorCodeUnitOffset = _lastSentText.characters
        .take(_lastSentCursorOffset)
        .join()
        .length;
    final resyncValue = _editingStateForUserText(
      userText: _lastSentText,
      userSelection: TextSelection.collapsed(offset: cursorCodeUnitOffset),
    );

    // Re-sync the IME with the current terminal buffer so delta
    // computation continues to work correctly.
    _sawImeComposition = false;
    _currentEditingState = resyncValue;
    if (_connection!.attached) {
      _connection!.setEditingState(resyncValue);
    }
  }

  void _openInputConnection({bool show = true}) {
    if (!_shouldCreateInputConnection) return;

    if (hasInputConnection) {
      if (show) _connection!.show();
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
      if (show) _connection!.show();
      _invalidatePendingEditingUpdates();
      _sawImeComposition = false;
      _lastProcessedUserSelectionWasValid = false;
      _lastProcessedSelectionWasCollapsed = true;
      _trimLeadingSuggestionSpaceAfterDelete = false;
      _trimLeadingSwipeSpaceAfterBufferClear = false;
      _resetNextInputAfterModifierChord = false;
      _lastSentText = '';
      _lastSentCursorOffset = 0;
      _pendingPerformedEnterText = null;
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
    _invalidatePendingEditingUpdates();
    _sawImeComposition = false;
    _lastProcessedUserSelectionWasValid = false;
    _lastProcessedSelectionWasCollapsed = true;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _resetNextInputAfterModifierChord = false;
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    _pendingPerformedEnterText = null;
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

  int _commonGraphemePrefixLength(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    int? maxLength,
  }) {
    final sharedLength = previousGraphemes.length < currentGraphemes.length
        ? previousGraphemes.length
        : currentGraphemes.length;
    final prefixLimit = maxLength == null || maxLength > sharedLength
        ? sharedLength
        : maxLength;
    var index = 0;
    while (index < prefixLimit &&
        previousGraphemes[index] == currentGraphemes[index]) {
      index++;
    }
    return index;
  }

  int _commonGraphemeSuffixLength(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    required int commonPrefixLength,
  }) {
    final previousRemainingLength =
        previousGraphemes.length - commonPrefixLength;
    final currentRemainingLength = currentGraphemes.length - commonPrefixLength;
    var index = 0;
    while (index < previousRemainingLength &&
        index < currentRemainingLength &&
        previousGraphemes[previousGraphemes.length - 1 - index] ==
            currentGraphemes[currentGraphemes.length - 1 - index]) {
      index++;
    }
    return index;
  }

  String _extractRawInputText(String text) =>
      text.substring(_editingPrefixLength(text));

  String _extractInputText(String text) {
    final extractedText = _extractRawInputText(text);
    final sanitizedText = extractedText.replaceFirst(
      _leadingSwipeNewlineArtifactPattern,
      '',
    );
    if ((_sawImeComposition ||
            _trimLeadingSuggestionSpaceAfterDelete ||
            _trimLeadingSwipeSpaceAfterBufferClear) &&
        sanitizedText.startsWith(' ') &&
        !sanitizedText.startsWith('  ') &&
        sanitizedText.trimLeft().isNotEmpty &&
        _shouldTrimLeadingSwipeSpace()) {
      return sanitizedText.substring(1);
    }
    return sanitizedText;
  }

  bool _shouldTrimLeadingSwipeSpace() {
    if (_trimLeadingSwipeSpaceAfterBufferClear) {
      return true;
    }

    final textBeforeCursor = widget.resolveTextBeforeCursor?.call();
    if (textBeforeCursor == null || textBeforeCursor.isEmpty) {
      return true;
    }

    final trailingCodeUnit = textBeforeCursor.codeUnitAt(
      textBeforeCursor.length - 1,
    );
    return trailingCodeUnit == 0x20 ||
        trailingCodeUnit == 0x09 ||
        trailingCodeUnit == 0x0A ||
        trailingCodeUnit == 0x0D;
  }

  int _sendInputDelta(
    String currentText,
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) {
    _moveTerminalCursorTo(delta.deleteCursorOffset);

    final deletedCount = delta.deletedCount;

    for (var i = 0; i < deletedCount; i++) {
      widget.terminal.keyInput(TerminalKey.backspace);
    }

    final appendedText = delta.appendedText;
    if (appendedText.isNotEmpty) {
      widget.terminal.textInput(appendedText);
    }

    _lastSentText = currentText;
    _lastSentCursorOffset =
        delta.deleteCursorOffset -
        deletedCount +
        appendedText.characters.length;
    return '\n'.allMatches(appendedText).length;
  }

  void _resetCommittedInputState({
    int pendingEnterSuppressions = 0,
    bool clearPendingPerformedEnterText = true,
  }) {
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    if (clearPendingPerformedEnterText) {
      _pendingPerformedEnterText = null;
    }
    _pendingEnterActionSuppressions = pendingEnterSuppressions;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _resetNextInputAfterModifierChord = false;
    _syncEditingStateWithUserText('');
  }

  ({String? currentText, bool strippedPendingEnter, bool ignored})
  _normalizePendingPerformedEnterText(String currentText) {
    final pendingPerformedEnterText = _pendingPerformedEnterText;
    if (pendingPerformedEnterText == null) {
      return (
        currentText: currentText,
        strippedPendingEnter: false,
        ignored: false,
      );
    }

    if (currentText.isEmpty || currentText == pendingPerformedEnterText) {
      return (currentText: null, strippedPendingEnter: false, ignored: true);
    }

    for (final newlineSequence in _enterCommitNewlineSequences) {
      final prefix = '$pendingPerformedEnterText$newlineSequence';
      if (currentText == prefix) {
        _pendingPerformedEnterText = null;
        return (currentText: null, strippedPendingEnter: false, ignored: false);
      }
      if (currentText.startsWith(prefix)) {
        _pendingPerformedEnterText = null;
        return (
          currentText: currentText.substring(prefix.length),
          strippedPendingEnter: true,
          ignored: false,
        );
      }
    }

    _pendingPerformedEnterText = null;
    return (
      currentText: currentText,
      strippedPendingEnter: false,
      ignored: false,
    );
  }

  int _textLengthInGraphemes(String text) => text.characters.length;

  int _graphemeOffsetForCodeUnitOffset(String text, int codeUnitOffset) => text
      .substring(0, _clampTextOffset(codeUnitOffset, text.length))
      .characters
      .length;

  TextSelection? _userSelectionForEditingValue(
    String userText,
    TextEditingValue value,
  ) {
    final rawPrefixLength = _editingPrefixLength(value.text);
    final rawUserText = _extractRawInputText(value.text);
    final trimmedLeadingCharacters = rawUserText.length - userText.length;
    return _normalizeSelectionForUserText(
      selection: value.selection,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: userText.length,
    );
  }

  int? _collapsedSelectionCursorOffset(
    String userText,
    TextEditingValue value,
  ) {
    final userSelection = _userSelectionForEditingValue(userText, value);
    if (userSelection == null || !userSelection.isCollapsed) {
      return null;
    }
    return _graphemeOffsetForCodeUnitOffset(
      userText,
      userSelection.extentOffset,
    );
  }

  void _moveTerminalCursorTo(int targetOffset) {
    final maxOffset = _textLengthInGraphemes(_lastSentText);
    final clampedTargetOffset = _clampTextOffset(targetOffset, maxOffset);
    final currentOffset = _lastSentCursorOffset;
    final isCurrentOffsetValid =
        currentOffset >= 0 && currentOffset <= maxOffset;
    if (!isCurrentOffsetValid) {
      _lastSentCursorOffset = clampedTargetOffset;
      return;
    }

    if (clampedTargetOffset == currentOffset) {
      return;
    }

    final key = clampedTargetOffset < currentOffset
        ? TerminalKey.arrowLeft
        : TerminalKey.arrowRight;
    final moveCount = (clampedTargetOffset - currentOffset).abs();
    for (var index = 0; index < moveCount; index++) {
      widget.terminal.keyInput(key);
    }
    _lastSentCursorOffset = clampedTargetOffset;
  }

  ({int deletedCount, String appendedText, int deleteCursorOffset})
  _computeTextDelta(String currentText, {int? cursorOffsetHint}) {
    final previousGraphemes = _lastSentText.characters.toList(growable: false);
    final currentGraphemes = currentText.characters.toList(growable: false);
    final defaultDelta = _computeTextDeltaCandidate(
      previousGraphemes,
      currentGraphemes,
    );
    if (cursorOffsetHint == null) {
      return defaultDelta;
    }

    final anchoredPrefixLimit = _lastSentCursorOffset < cursorOffsetHint
        ? _lastSentCursorOffset
        : cursorOffsetHint;
    final anchoredDelta = _computeTextDeltaCandidate(
      previousGraphemes,
      currentGraphemes,
      maxCommonPrefixLength: anchoredPrefixLimit,
    );
    return _selectPreferredTextDelta(
      defaultDelta: defaultDelta,
      anchoredDelta: anchoredDelta,
      cursorOffsetHint: cursorOffsetHint,
    );
  }

  ({int deletedCount, String appendedText, int deleteCursorOffset})
  _computeTextDeltaCandidate(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    int? maxCommonPrefixLength,
  }) {
    final commonPrefix = _commonGraphemePrefixLength(
      previousGraphemes,
      currentGraphemes,
      maxLength: maxCommonPrefixLength,
    );
    final commonSuffix = _commonGraphemeSuffixLength(
      previousGraphemes,
      currentGraphemes,
      commonPrefixLength: commonPrefix,
    );
    final deleteCursorOffset = previousGraphemes.length - commonSuffix;
    return (
      deletedCount: previousGraphemes.length - commonPrefix - commonSuffix,
      appendedText: currentGraphemes
          .sublist(commonPrefix, currentGraphemes.length - commonSuffix)
          .join(),
      deleteCursorOffset: deleteCursorOffset,
    );
  }

  int _deltaPostEditCursorOffset(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) =>
      delta.deleteCursorOffset -
      delta.deletedCount +
      delta.appendedText.characters.length;

  int _deltaCursorScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
    int cursorOffsetHint,
  ) => (_deltaPostEditCursorOffset(delta) - cursorOffsetHint).abs();

  int _deltaMovementScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) => (delta.deleteCursorOffset - _lastSentCursorOffset).abs();

  int _deltaRewriteScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) => delta.deletedCount + delta.appendedText.characters.length;

  ({int deletedCount, String appendedText, int deleteCursorOffset})
  _selectPreferredTextDelta({
    required ({int deletedCount, String appendedText, int deleteCursorOffset})
    defaultDelta,
    required ({int deletedCount, String appendedText, int deleteCursorOffset})
    anchoredDelta,
    required int cursorOffsetHint,
  }) {
    final defaultCursorScore = _deltaCursorScore(
      defaultDelta,
      cursorOffsetHint,
    );
    final anchoredCursorScore = _deltaCursorScore(
      anchoredDelta,
      cursorOffsetHint,
    );
    if (anchoredCursorScore != defaultCursorScore) {
      return anchoredCursorScore < defaultCursorScore
          ? anchoredDelta
          : defaultDelta;
    }

    final defaultMovementScore = _deltaMovementScore(defaultDelta);
    final anchoredMovementScore = _deltaMovementScore(anchoredDelta);
    if (anchoredMovementScore != defaultMovementScore) {
      return anchoredMovementScore < defaultMovementScore
          ? anchoredDelta
          : defaultDelta;
    }

    final defaultRewriteScore = _deltaRewriteScore(defaultDelta);
    final anchoredRewriteScore = _deltaRewriteScore(anchoredDelta);
    if (anchoredRewriteScore != defaultRewriteScore) {
      return anchoredRewriteScore < defaultRewriteScore
          ? anchoredDelta
          : defaultDelta;
    }

    return defaultDelta;
  }

  TerminalCommandReview? _reviewForInsertedText(
    String currentText,
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) {
    if (widget.onReviewInsertedText == null) {
      return null;
    }
    if (delta.appendedText.characters.length <= 1) {
      return null;
    }

    final reviewText =
        widget.buildReviewTextForInsertedText?.call((
          deletedCount: delta.deletedCount,
          appendedText: delta.appendedText,
        ), currentText) ??
        currentText;
    final review = assessClipboardPasteCommand(
      reviewText,
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
    bool forceResyncState = false,
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
    final hasActiveReplacementSelection =
        sourceValue != null &&
        sourceValue.selection.isValid &&
        !sourceValue.selection.isCollapsed;
    final shouldResyncText =
        forceResyncState ||
        sourceValue == null ||
        (sourceValue.text != nextState.text &&
            !(trimmedLeadingCharacters > 0 && hasActiveReplacementSelection));
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
    if (widget.readOnly) {
      return;
    }

    if (!value.composing.isCollapsed) {
      _sawImeComposition = true;
    }

    _currentEditingState = value;
    _queuedEditingValue = value;
    _latestEditingValueRevision++;

    if (_isProcessingEditingValue) {
      return;
    }

    _isProcessingEditingValue = true;
    unawaited(_drainEditingValueQueue());
  }

  Future<void> _drainEditingValueQueue() async {
    try {
      while (mounted && _queuedEditingValue != null) {
        final value = _queuedEditingValue!;
        final revision = _latestEditingValueRevision;
        _queuedEditingValue = null;
        await _updateEditingValue(value, revision);
      }
    } finally {
      _isProcessingEditingValue = false;
    }

    if (mounted && _queuedEditingValue != null && !_isProcessingEditingValue) {
      _isProcessingEditingValue = true;
      unawaited(_drainEditingValueQueue());
    }
  }

  Future<void> _updateEditingValue(TextEditingValue value, int revision) async {
    _currentEditingState = value;
    var processedUserSelectionWasValid = false;
    var processedUserSelection = const TextSelection.collapsed(offset: 0);
    try {
      // Handle composing (IME input in progress).
      if (!value.composing.isCollapsed) {
        _sawImeComposition = true;
        return;
      }

      if (_editingPrefixLength(value.text) < _initEditingState.text.length) {
        final deletedCount = _textLengthInGraphemes(_lastSentText);
        final clearedBufferedInput = deletedCount > 0;
        _notifyUserInput();
        _moveTerminalCursorTo(deletedCount);
        if (clearedBufferedInput) {
          for (var index = 0; index < deletedCount; index++) {
            widget.terminal.keyInput(TerminalKey.backspace);
          }
        } else {
          widget.terminal.keyInput(TerminalKey.backspace);
        }
        _sawImeComposition = false;
        _resetCommittedInputState();
        _trimLeadingSwipeSpaceAfterBufferClear = clearedBufferedInput;
        return;
      }

      final normalizedPendingEnter = _normalizePendingPerformedEnterText(
        _extractInputText(value.text),
      );
      if (normalizedPendingEnter.ignored) {
        _syncEditingStateWithUserText('');
        _sawImeComposition = false;
        return;
      }
      if (normalizedPendingEnter.currentText == null) {
        _resetCommittedInputState();
        _sawImeComposition = false;
        return;
      }

      final currentText = normalizedPendingEnter.currentText!;
      final userSelection = _userSelectionForEditingValue(currentText, value);
      processedUserSelectionWasValid = userSelection != null;
      processedUserSelection =
          userSelection ?? TextSelection.collapsed(offset: currentText.length);
      final targetCursorOffset = _collapsedSelectionCursorOffset(
        currentText,
        value,
      );
      if (currentText == _lastSentText) {
        final collapsedMoveAwayFromReplacement =
            !_lastProcessedSelectionWasCollapsed &&
            targetCursorOffset != null &&
            targetCursorOffset != _lastSentCursorOffset &&
            targetCursorOffset != _lastSentCursorOffset + 1;
        final movedCollapsedCursor =
            _lastProcessedUserSelectionWasValid &&
            (_lastProcessedSelectionWasCollapsed ||
                collapsedMoveAwayFromReplacement) &&
            targetCursorOffset != null &&
            targetCursorOffset != _lastSentCursorOffset;
        if (targetCursorOffset != null &&
            targetCursorOffset != _lastSentCursorOffset) {
          _notifyUserInput();
          _moveTerminalCursorTo(targetCursorOffset);
        }
        _syncEditingStateWithUserText(
          currentText,
          sourceValue: value,
          forceResyncState: movedCollapsedCursor,
        );
        _sawImeComposition = false;
        return;
      }

      final delta = _computeTextDelta(
        currentText,
        cursorOffsetHint: targetCursorOffset,
      );
      final review = _reviewForInsertedText(currentText, delta);
      if (review != null) {
        final shouldInsert = await widget.onReviewInsertedText!(review);
        if (!mounted || revision != _latestEditingValueRevision) {
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
      final previousText = _lastSentText;
      final newlineCount = _sendInputDelta(currentText, delta);
      if (newlineCount > 0) {
        _resetCommittedInputState(pendingEnterSuppressions: newlineCount);
        _sawImeComposition = false;
        return;
      }

      // Detect non-additive operations that should clear the IME suggestion
      // context: pure deletions (backspace with no replacement text) and
      // modifier chords (Ctrl/Alt + character) where the typed character
      // becomes a control code instead of visible text.
      //
      // IME replacements (e.g. autocorrect changing "teh" to "the") may
      // also shorten text but include appended replacement text, so they
      // are NOT treated as pure deletions.
      final wasPureDeletion =
          previousText.isNotEmpty &&
          delta.deletedCount > 0 &&
          delta.appendedText.isEmpty;
      final wasModifiedSingleChar =
          delta.deletedCount == 0 &&
          delta.appendedText.characters.length == 1 &&
          (widget.hasActiveToolbarModifier?.call() ?? false);

      // Also detect the second character of a two-part chord like tmux's
      // Ctrl+b, c. After the first modifier character resets, the follow-up
      // character is sent without a modifier but is still part of the chord
      // and should not accumulate in the IME suggestion context.
      final wasChordFollowUp =
          _resetNextInputAfterModifierChord &&
          delta.deletedCount == 0 &&
          delta.appendedText.characters.length == 1;

      if (wasModifiedSingleChar || wasChordFollowUp) {
        // The character was transformed into a control code by the toolbar
        // modifier (or is the follow-up of a two-part chord), so it does
        // not represent visible terminal text. Do a full reset — the
        // shell's response to a control code is unpredictable.
        _resetCommittedInputState();
        _trimLeadingSwipeSpaceAfterBufferClear = true;
        // Set the flag so the next single character is also reset (supports
        // multi-part chords like tmux's Ctrl+b, c).
        _resetNextInputAfterModifierChord = wasModifiedSingleChar;
        _sawImeComposition = false;
        return;
      }

      // Any non-chord input clears the chord follow-up flag.
      _resetNextInputAfterModifierChord = false;

      if (wasPureDeletion) {
        // Reconnect the IME to clear suggestion/prediction history while
        // keeping _lastSentText intact so delta computation stays correct.
        _reconnectInputToResetSuggestions();
        _trimLeadingSuggestionSpaceAfterDelete = currentText.isNotEmpty;
        _trimLeadingSwipeSpaceAfterBufferClear =
            previousText.isNotEmpty && currentText.isEmpty;
        _sawImeComposition = false;
        return;
      }

      // For IME replacements that shorten text (e.g. autocorrect), keep the
      // suggestion-space-trim flag since the IME may prepend a space to the
      // next swiped word.
      _trimLeadingSuggestionSpaceAfterDelete =
          previousText.isNotEmpty &&
          currentText.characters.length < previousText.characters.length;
      _trimLeadingSwipeSpaceAfterBufferClear =
          previousText.isNotEmpty && currentText.isEmpty;
      if (targetCursorOffset != null) {
        _moveTerminalCursorTo(targetCursorOffset);
      }
      _syncEditingStateWithUserText(
        currentText,
        sourceValue: normalizedPendingEnter.strippedPendingEnter ? null : value,
      );
      _sawImeComposition = false;
    } finally {
      _lastProcessedUserSelectionWasValid = processedUserSelectionWasValid;
      _lastProcessedSelectionWasCollapsed = processedUserSelection.isCollapsed;
    }
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
      _pendingPerformedEnterText = _lastSentText;
      _resetCommittedInputState(clearPendingPerformedEnterText: false);
      _sawImeComposition = false;
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
    _invalidatePendingEditingUpdates();
    _sawImeComposition = false;
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    _pendingPerformedEnterText = null;
    _lastProcessedUserSelectionWasValid = false;
    _lastProcessedSelectionWasCollapsed = true;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _resetNextInputAfterModifierChord = false;
    _pendingEnterActionSuppressions = 0;
    _currentEditingState = _initEditingState.copyWith();
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}
}
