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
import 'terminal_key_input.dart';

const _deleteDetectionMarker = '\u200B\u200B';
final _leadingSwipeNewlineArtifactPattern = RegExp(r'^[\r\n]+ ?(?=\S)');
final _splitLeadingTokenCandidatePattern = RegExp(r'^\s*\S\s+\S');
const _enterCommitNewlineSequences = <String>['\r\n', '\n', '\r'];

bool _isAsciiLetterOrDigitCodeUnit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

bool _isPromptWhitespaceCodeUnit(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

/// Maximum delay between a modifier chord and its follow-up character for the
/// follow-up to be treated as part of the chord (e.g. tmux's Ctrl+b, c).
@visibleForTesting
const modifierChordFollowUpWindow = Duration(milliseconds: 500);

/// Touch duration at which a terminal touch should be treated as selection
/// intent rather than a tap-to-focus keyboard request.
@visibleForTesting
const terminalKeyboardTapLongPressTimeout = kLongPressTimeout;

/// How long iOS keeps the IME buffer intact after a trailing backspace.
///
/// Held iOS backspace can briefly pause between native repeat phases, so keep
/// the buffer alive long enough that those pauses do not fall back to the slow
/// marker-deletion path.
@visibleForTesting
const terminalIosBackspaceRepeatSettleDelay = Duration(seconds: 2);

/// Delay before iOS hardware keys begin app-controlled repeat.
@visibleForTesting
const terminalIosHardwareKeyRepeatStartDelay = Duration(milliseconds: 250);

/// Repeat interval for iOS hardware terminal navigation/editing keys.
@visibleForTesting
const terminalIosHardwareKeyRepeatInterval = Duration(milliseconds: 35);

DateTime Function()? _modifierChordClockOverride;

DateTime _readModifierChordClock() =>
    (_modifierChordClockOverride ?? DateTime.now).call();

/// Overrides the modifier chord clock in tests.
@visibleForTesting
void debugSetModifierChordClock(DateTime Function()? clock) {
  _modifierChordClockOverride = clock;
}

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

/// Resolves active toolbar modifiers for non-text terminal key actions.
typedef TerminalKeyModifierResolver =
    ({bool ctrl, bool alt, bool shift}) Function();

/// Applies active toolbar modifiers to soft-keyboard terminal text.
typedef TerminalTextInputModifierApplier = String Function(String text);

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
  required bool pressedBeyondLongPressTimeout,
  required bool readOnly,
  Duration? touchPressDuration,
}) {
  if (readOnly) {
    return false;
  }

  if (pointerKind != PointerDeviceKind.touch) {
    return true;
  }

  return activeTouchPointers == 1 &&
      !hadMultipleTouchPointers &&
      !movedBeyondTapSlop &&
      !pressedBeyondLongPressTimeout &&
      (touchPressDuration == null ||
          touchPressDuration < terminalKeyboardTapLongPressTimeout);
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

  /// Clears the transient IME buffer after external terminal actions.
  ///
  /// This is used for toolbar-driven keys like arrows, Home/End, Enter, Tab,
  /// and escape sequences that bypass the regular text-input pipeline but
  /// should still reset keyboard suggestions.
  void clearImeBuffer() {
    _state?._clearImeBufferForFreshInput();
  }

  /// Resets stale IME context after remote terminal output returns to a prompt.
  void handleExternalTerminalOutput() {
    _state?._handleExternalTerminalOutput();
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
    this.resolveTerminalKeyModifiers,
    this.consumeTerminalKeyModifiers,
    this.applyTerminalTextInputModifiers,
    this.hasActiveToolbarModifier,
    this.readOnly = false,
    this.tapToShowKeyboard = true,
    this.showKeyboardOnFocus,
    this.manageFocus = true,
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

  /// Resolves active toolbar modifiers for terminal key actions like Enter.
  final TerminalKeyModifierResolver? resolveTerminalKeyModifiers;

  /// Consumes one-shot toolbar modifiers after a terminal key action.
  final VoidCallback? consumeTerminalKeyModifiers;

  /// Applies toolbar modifiers before text reaches the terminal output stream.
  final TerminalTextInputModifierApplier? applyTerminalTextInputModifiers;

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

  /// Whether focusing the terminal should show the keyboard.
  ///
  /// When omitted, focus follows [tapToShowKeyboard]. Set this to `false` when
  /// focus should attach an input connection without opening the keyboard until
  /// the user explicitly taps the terminal.
  final bool? showKeyboardOnFocus;

  /// Whether this widget should wrap [child] in a [Focus] using [focusNode].
  ///
  /// Set this to false when the child already owns the same [focusNode], for
  /// example a [SelectionArea] that must share focus with the input connection.
  final bool manageFocus;

  @override
  State<TerminalTextInputHandler> createState() =>
      _TerminalTextInputHandlerState();
}

class _TerminalTextInputHandlerState extends State<TerminalTextInputHandler>
    with TextInputClient {
  TextInputConnection? _connection;
  final Set<int> _activeTouchPointers = <int>{};
  final Map<int, Offset> _touchPointerDownPositions = <int, Offset>{};
  final Map<int, Duration> _touchPointerDownTimestamps = <int, Duration>{};
  final Map<int, Timer> _touchLongPressTimers = <int, Timer>{};
  final Set<int> _touchPointersMovedBeyondTapSlop = <int>{};
  final Set<int> _touchPointersPressedBeyondLongPressTimeout = <int>{};
  bool _touchSequenceHadMultiplePointers = false;
  bool _skipNextTouchKeyboardRequest = false;
  bool _sawImeComposition = false;
  bool _isProcessingEditingValue = false;
  bool _lastProcessedUserSelectionWasValid = false;
  bool _lastProcessedSelectionWasCollapsed = true;
  bool _trimLeadingSuggestionSpaceAfterDelete = false;
  bool _trimLeadingSwipeSpaceAfterBufferClear = false;
  bool _allowSplitLeadingTokenNormalization = false;
  bool _clearImeAfterNextTouchCursorMove = false;
  bool _hasPendingPromptOutputImeReset = false;
  Timer? _deferredTrailingBackspaceImeClearTimer;
  ({String baselineText, int baselineCursorOffset, String? deletedSuffixText})?
  _deferredTrailingBackspaceImeClear;
  Timer? _hardwareKeyRepeatStartTimer;
  Timer? _hardwareKeyRepeatTimer;
  LogicalKeyboardKey? _hardwareRepeatingLogicalKey;
  ({
    TerminalKey key,
    bool ctrl,
    bool alt,
    bool shift,
    bool hasShortcutModifier,
  })?
  _hardwareRepeatInput;
  DateTime? _modifierChordResetTime;
  String? _pendingDeleteResetBaselineText;
  int? _pendingDeleteResetBaselineCursorOffset;
  String? _pendingDeleteResetDeletedSuffixText;
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
    if (!widget.manageFocus) {
      HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    }
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
    if (widget.manageFocus != oldWidget.manageFocus) {
      if (widget.manageFocus) {
        HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
      } else {
        HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
      }
    }
    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else if (oldWidget.readOnly && widget.focusNode.hasFocus) {
      _openInputConnection(
        show: widget.showKeyboardOnFocus ?? widget.tapToShowKeyboard,
      );
    }
    if (widget.readOnly) {
      _stopHardwareKeyRepeat();
      _cancelDeferredTrailingBackspaceImeClear();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    if (!widget.manageFocus) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    }
    widget.focusNode.removeListener(_onFocusChange);
    _stopHardwareKeyRepeat();
    _cancelDeferredTrailingBackspaceImeClear();
    for (final timer in _touchLongPressTimers.values) {
      timer.cancel();
    }
    _activeTouchPointers.clear();
    _touchPointerDownPositions.clear();
    _touchPointerDownTimestamps.clear();
    _touchLongPressTimers.clear();
    _touchPointersMovedBeyondTapSlop.clear();
    _touchPointersPressedBeyondLongPressTimeout.clear();
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.manageFocus
        ? Focus(
            focusNode: widget.focusNode,
            autofocus: true,
            onKeyEvent: _onKeyEvent,
            child: widget.child,
          )
        : widget.child;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: child,
    );
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (widget.manageFocus || !widget.focusNode.hasFocus) {
      return false;
    }
    final result = _onKeyEvent(widget.focusNode, event);
    return result == KeyEventResult.handled ||
        result == KeyEventResult.skipRemainingHandlers;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouchPointers.add(event.pointer);
      _touchPointerDownPositions[event.pointer] = event.position;
      _touchPointerDownTimestamps[event.pointer] = event.timeStamp;
      _touchLongPressTimers[event.pointer]?.cancel();
      _touchLongPressTimers[event.pointer] = Timer(
        terminalKeyboardTapLongPressTimeout,
        () {
          if (!_isTouchSelectionIntentCandidate(event.pointer)) {
            return;
          }
          _touchPointersPressedBeyondLongPressTimeout.add(event.pointer);
        },
      );
      if (_activeTouchPointers.length > 1) {
        _touchSequenceHadMultiplePointers = true;
      }
    }
  }

  bool _isTouchSelectionIntentCandidate(int pointer) =>
      _activeTouchPointers.length == 1 &&
      _activeTouchPointers.contains(pointer) &&
      !_touchSequenceHadMultiplePointers &&
      !_touchPointersMovedBeyondTapSlop.contains(pointer);

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
      pressedBeyondLongPressTimeout:
          event.kind == PointerDeviceKind.touch &&
          _touchPointersPressedBeyondLongPressTimeout.contains(event.pointer),
      readOnly: widget.readOnly,
      touchPressDuration: event.kind == PointerDeviceKind.touch
          ? _touchPressDuration(event)
          : null,
    );
    if (event.kind == PointerDeviceKind.touch && shouldRequestKeyboard) {
      _clearImeAfterNextTouchCursorMove = true;
    }
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
    _touchPointerDownTimestamps.remove(event.pointer);
    _touchLongPressTimers.remove(event.pointer)?.cancel();
    _touchPointersMovedBeyondTapSlop.remove(event.pointer);
    _touchPointersPressedBeyondLongPressTimeout.remove(event.pointer);
    if (_activeTouchPointers.isEmpty) {
      _touchSequenceHadMultiplePointers = false;
    }
  }

  Duration? _touchPressDuration(PointerEvent event) {
    final startTimestamp = _touchPointerDownTimestamps[event.pointer];
    if (startTimestamp == null) {
      return null;
    }
    return event.timeStamp - startTimestamp;
  }

  void _notifyUserInput() {
    widget.onUserInput?.call();
  }

  bool get _shouldDeferTrailingBackspaceImeClear =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _shouldUseCustomHardwareKeyRepeat =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool _isRepeatableHardwareTerminalKey(TerminalKey key) => switch (key) {
    TerminalKey.backspace ||
    TerminalKey.delete ||
    TerminalKey.arrowLeft ||
    TerminalKey.arrowRight ||
    TerminalKey.arrowUp ||
    TerminalKey.arrowDown ||
    TerminalKey.home ||
    TerminalKey.end ||
    TerminalKey.pageUp ||
    TerminalKey.pageDown => true,
    _ => false,
  };

  void _cancelDeferredTrailingBackspaceImeClear() {
    _deferredTrailingBackspaceImeClearTimer?.cancel();
    _deferredTrailingBackspaceImeClearTimer = null;
    _deferredTrailingBackspaceImeClear = null;
  }

  void _scheduleDeferredTrailingBackspaceImeClear({
    required String baselineText,
    required int baselineCursorOffset,
    required String? deletedSuffixText,
  }) {
    _cancelDeferredTrailingBackspaceImeClear();
    _deferredTrailingBackspaceImeClear = (
      baselineText: baselineText,
      baselineCursorOffset: baselineCursorOffset,
      deletedSuffixText: deletedSuffixText,
    );
    _deferredTrailingBackspaceImeClearTimer = Timer(
      terminalIosBackspaceRepeatSettleDelay,
      () {
        if (!mounted) {
          return;
        }
        final pendingClear = _deferredTrailingBackspaceImeClear;
        if (pendingClear == null) {
          return;
        }
        _clearImeBufferForFreshInput(
          deleteResetBaselineText: pendingClear.baselineText,
          deleteResetBaselineCursorOffset: pendingClear.baselineCursorOffset,
          deleteResetDeletedSuffixText: pendingClear.deletedSuffixText,
        );
        _sawImeComposition = false;
      },
    );
  }

  bool _sendHardwareTerminalKey(
    TerminalKey key, {
    required bool ctrl,
    required bool alt,
    required bool shift,
    required bool hasShortcutModifier,
  }) {
    final handled = widget.terminal.keyInput(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );

    if (handled) {
      _notifyUserInput();
      _trackHandledHardwareCursorKey(
        key,
        hasShortcutModifier: hasShortcutModifier,
      );
    }

    return handled;
  }

  void _startHardwareKeyRepeat({
    required LogicalKeyboardKey logicalKey,
    required TerminalKey key,
    required bool ctrl,
    required bool alt,
    required bool shift,
    required bool hasShortcutModifier,
  }) {
    _stopHardwareKeyRepeat();
    _hardwareRepeatingLogicalKey = logicalKey;
    _hardwareRepeatInput = (
      key: key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      hasShortcutModifier: hasShortcutModifier,
    );
    _hardwareKeyRepeatStartTimer = Timer(
      terminalIosHardwareKeyRepeatStartDelay,
      () {
        if (!mounted) {
          _stopHardwareKeyRepeat();
          return;
        }
        final repeatInput = _hardwareRepeatInput;
        if (repeatInput == null) {
          return;
        }
        _sendHardwareTerminalKey(
          repeatInput.key,
          ctrl: repeatInput.ctrl,
          alt: repeatInput.alt,
          shift: repeatInput.shift,
          hasShortcutModifier: repeatInput.hasShortcutModifier,
        );
        _hardwareKeyRepeatTimer = Timer.periodic(
          terminalIosHardwareKeyRepeatInterval,
          (_) {
            if (!mounted) {
              _stopHardwareKeyRepeat();
              return;
            }
            final repeatInput = _hardwareRepeatInput;
            if (repeatInput == null) {
              return;
            }
            _sendHardwareTerminalKey(
              repeatInput.key,
              ctrl: repeatInput.ctrl,
              alt: repeatInput.alt,
              shift: repeatInput.shift,
              hasShortcutModifier: repeatInput.hasShortcutModifier,
            );
          },
        );
      },
    );
  }

  void _stopHardwareKeyRepeat({LogicalKeyboardKey? logicalKey}) {
    if (logicalKey != null && _hardwareRepeatingLogicalKey != logicalKey) {
      return;
    }
    _hardwareKeyRepeatStartTimer?.cancel();
    _hardwareKeyRepeatTimer?.cancel();
    _hardwareKeyRepeatStartTimer = null;
    _hardwareKeyRepeatTimer = null;
    _hardwareRepeatingLogicalKey = null;
    _hardwareRepeatInput = null;
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
      _stopHardwareKeyRepeat();
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
      _stopHardwareKeyRepeat(logicalKey: event.logicalKey);
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);
    if (key == null) {
      return KeyEventResult.ignored;
    }

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final useCustomRepeat =
        _shouldUseCustomHardwareKeyRepeat &&
        _isRepeatableHardwareTerminalKey(key);

    if (event is KeyRepeatEvent && useCustomRepeat) {
      return KeyEventResult.handled;
    }

    final handled = _sendHardwareTerminalKey(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      hasShortcutModifier: hasShortcutModifier,
    );

    if (handled && event is KeyDownEvent && useCustomRepeat) {
      _startHardwareKeyRepeat(
        logicalKey: event.logicalKey,
        key: key,
        ctrl: ctrl,
        alt: alt,
        shift: shift,
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

  void _clearImeBufferForFreshInput({
    bool armModifierChordWindow = false,
    bool armSplitLeadingTokenNormalization = false,
    String? deleteResetBaselineText,
    int? deleteResetBaselineCursorOffset,
    String? deleteResetDeletedSuffixText,
    bool flushPlatformContext = false,
  }) {
    _cancelDeferredTrailingBackspaceImeClear();
    if (flushPlatformContext && hasInputConnection) {
      // Reset the editing state in-place rather than closing/reopening
      // the input connection. Closing triggers a keyboard dismiss+reshow
      // flicker on iPad.
      _currentEditingState = _initEditingState.copyWith();
      _connection!.setEditingState(_currentEditingState);
    }
    _invalidatePendingEditingUpdates();
    _resetCommittedInputState(clearPendingDeleteResetBaseline: false);
    _sawImeComposition = false;
    _hasPendingPromptOutputImeReset = false;
    if (deleteResetBaselineText != null &&
        deleteResetBaselineCursorOffset != null) {
      _pendingDeleteResetBaselineText = deleteResetBaselineText;
      _pendingDeleteResetBaselineCursorOffset = deleteResetBaselineCursorOffset;
      _pendingDeleteResetDeletedSuffixText = deleteResetDeletedSuffixText;
    } else {
      _clearPendingDeleteResetBaseline();
    }
    _trimLeadingSuggestionSpaceAfterDelete = true;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _allowSplitLeadingTokenNormalization = armSplitLeadingTokenNormalization;
    _modifierChordResetTime = armModifierChordWindow
        ? _readModifierChordClock()
        : null;
  }

  void _handleExternalTerminalOutput() {
    if (widget.readOnly || !widget.focusNode.hasFocus || !hasInputConnection) {
      return;
    }
    if (!_hasPendingPromptOutputImeReset) {
      return;
    }
    if (_sawImeComposition || _lastSentText.isNotEmpty) {
      return;
    }
    if (_extractInputText(_currentEditingState.text).isNotEmpty) {
      return;
    }
    final textBeforeCursor = widget.resolveTextBeforeCursor?.call();
    if (textBeforeCursor == null ||
        !_currentLineLooksLikePromptPrefix(textBeforeCursor)) {
      return;
    }
    _clearImeBufferForFreshInput(
      flushPlatformContext: true,
      armSplitLeadingTokenNormalization: true,
    );
  }

  // -- Focus handling --

  void _onFocusChange() {
    if (widget.focusNode.hasFocus) {
      final consumedKeyboardToken = widget.focusNode.consumeKeyboardToken();
      if (!hasInputConnection || consumedKeyboardToken) {
        // Attach the input connection but only show the soft keyboard when
        // tap-to-show is enabled.  Explicit keyboard requests go through
        // requestKeyboard() which always passes show: true.
        _openInputConnection(
          show: widget.showKeyboardOnFocus ?? widget.tapToShowKeyboard,
        );
      }
    } else if (!widget.focusNode.hasFocus) {
      _stopHardwareKeyRepeat();
      _closeInputConnectionIfNeeded();
    }
  }

  // -- Input connection management --

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _invalidatePendingEditingUpdates() {
    _latestEditingValueRevision++;
    _queuedEditingValue = null;
  }

  bool _editingValueShowsImeInteraction(TextEditingValue value) =>
      value.text != _initEditingState.text ||
      value.selection != _initEditingState.selection ||
      !value.composing.isCollapsed;

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
      _allowSplitLeadingTokenNormalization = false;
      _hasPendingPromptOutputImeReset = false;
      _modifierChordResetTime = null;
      _clearPendingDeleteResetBaseline();
      _lastSentText = '';
      _lastSentCursorOffset = 0;
      _pendingPerformedEnterText = null;
      _pendingEnterActionSuppressions = 0;
      _currentEditingState = _initEditingState.copyWith();
      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    _stopHardwareKeyRepeat();
    _cancelDeferredTrailingBackspaceImeClear();
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
    _allowSplitLeadingTokenNormalization = false;
    _hasPendingPromptOutputImeReset = false;
    _modifierChordResetTime = null;
    _clearPendingDeleteResetBaseline();
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

  int _longestCommonCaseInsensitiveGraphemeSubsequenceLength(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    int? maxLength,
  }) {
    if (previousGraphemes.isEmpty || currentGraphemes.isEmpty) {
      return 0;
    }

    final cappedMaxLength = maxLength == null || maxLength < 1
        ? null
        : maxLength;
    if (cappedMaxLength != null && cappedMaxLength <= 2) {
      return _longestCommonCaseInsensitiveGraphemeSubsequenceLengthUpToTwo(
        previousGraphemes,
        currentGraphemes,
        maxLength: cappedMaxLength,
      );
    }
    final normalizedCurrentGraphemes = currentGraphemes
        .map((grapheme) => grapheme.toLowerCase())
        .toList(growable: false);
    var previousRow = List<int>.filled(currentGraphemes.length + 1, 0);
    for (final previousGrapheme in previousGraphemes) {
      final currentRow = List<int>.filled(currentGraphemes.length + 1, 0);
      final normalizedPreviousGrapheme = previousGrapheme.toLowerCase();
      for (var index = 0; index < currentGraphemes.length; index++) {
        final nextLength =
            normalizedPreviousGrapheme == normalizedCurrentGraphemes[index]
            ? previousRow[index] + 1
            : (previousRow[index + 1] > currentRow[index]
                  ? previousRow[index + 1]
                  : currentRow[index]);
        currentRow[index +
            1] = cappedMaxLength != null && nextLength > cappedMaxLength
            ? cappedMaxLength
            : nextLength;
      }
      previousRow = currentRow;
      if (cappedMaxLength != null && previousRow.last >= cappedMaxLength) {
        return cappedMaxLength;
      }
    }
    return previousRow.last;
  }

  int _longestCommonCaseInsensitiveGraphemeSubsequenceLengthUpToTwo(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    required int maxLength,
  }) {
    final currentPositionsByGrapheme = <String, List<int>>{};
    for (var index = 0; index < currentGraphemes.length; index++) {
      final normalizedCurrentGrapheme = currentGraphemes[index].toLowerCase();
      currentPositionsByGrapheme
          .putIfAbsent(normalizedCurrentGrapheme, () => <int>[])
          .add(index);
    }

    var hasLengthOneMatch = false;
    int? shortestLengthOneEndIndex;
    for (final previousGrapheme in previousGraphemes) {
      final positions =
          currentPositionsByGrapheme[previousGrapheme.toLowerCase()];
      if (positions == null || positions.isEmpty) {
        continue;
      }

      if (maxLength == 1) {
        return 1;
      }

      hasLengthOneMatch = true;
      if (shortestLengthOneEndIndex != null) {
        for (final position in positions) {
          if (position > shortestLengthOneEndIndex) {
            return 2;
          }
        }
      }

      final firstPosition = positions.first;
      if (shortestLengthOneEndIndex == null ||
          firstPosition < shortestLengthOneEndIndex) {
        shortestLengthOneEndIndex = firstPosition;
      }
    }

    return hasLengthOneMatch ? 1 : 0;
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
    if (trailingCodeUnit == 0x20 ||
        trailingCodeUnit == 0x09 ||
        trailingCodeUnit == 0x0A ||
        trailingCodeUnit == 0x0D) {
      return true;
    }

    return _currentLineLooksLikePromptPrefix(textBeforeCursor);
  }

  bool _currentLineLooksLikePromptPrefix(String textBeforeCursor) {
    var index = textBeforeCursor.length - 1;
    while (index >= 0) {
      final codeUnit = textBeforeCursor.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return true;
      }
      if (!_isPromptWhitespaceCodeUnit(codeUnit)) {
        break;
      }
      index--;
    }

    if (index < 0) {
      return true;
    }

    var visibleCodeUnitCount = 0;
    while (index >= 0) {
      final codeUnit = textBeforeCursor.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        break;
      }
      if (!_isPromptWhitespaceCodeUnit(codeUnit)) {
        visibleCodeUnitCount++;
        if (visibleCodeUnitCount > 4) {
          return false;
        }
        if (_isAsciiLetterOrDigitCodeUnit(codeUnit)) {
          return false;
        }
      }
      index--;
    }

    return true;
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
      widget.terminal.textInput(_applyTerminalTextInputModifiers(appendedText));
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
    bool clearPendingDeleteResetBaseline = true,
  }) {
    _cancelDeferredTrailingBackspaceImeClear();
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    if (clearPendingPerformedEnterText) {
      _pendingPerformedEnterText = null;
    }
    _pendingEnterActionSuppressions = pendingEnterSuppressions;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _clearImeAfterNextTouchCursorMove = false;
    _allowSplitLeadingTokenNormalization = false;
    _modifierChordResetTime = null;
    if (clearPendingDeleteResetBaseline) {
      _clearPendingDeleteResetBaseline();
    }
    _syncEditingStateWithUserText('');
  }

  void _clearPendingDeleteResetBaseline() {
    _pendingDeleteResetBaselineText = null;
    _pendingDeleteResetBaselineCursorOffset = null;
    _pendingDeleteResetDeletedSuffixText = null;
  }

  ({
    String baselineText,
    int baselineCursorOffset,
    String? deletedSuffixText,
    List<String> baselineGraphemes,
    int tokenStart,
    String baselineToken,
  })?
  _deleteResetBaselineState() {
    final baselineText = _pendingDeleteResetBaselineText;
    final baselineCursorOffset = _pendingDeleteResetBaselineCursorOffset;
    final deletedSuffixText = _pendingDeleteResetDeletedSuffixText;
    if (baselineText == null || baselineCursorOffset == null) {
      return null;
    }

    final baselineGraphemes = baselineText.characters.toList(growable: false);
    var trimmedBaselineLength = baselineGraphemes.length;
    while (trimmedBaselineLength > 0 &&
        _isWhitespaceGrapheme(baselineGraphemes[trimmedBaselineLength - 1])) {
      trimmedBaselineLength--;
    }
    if (trimmedBaselineLength == 0) {
      return null;
    }

    var tokenStart = trimmedBaselineLength;
    while (tokenStart > 0 &&
        !_isWhitespaceGrapheme(baselineGraphemes[tokenStart - 1])) {
      tokenStart--;
    }

    return (
      baselineText: baselineText,
      baselineCursorOffset: baselineCursorOffset,
      deletedSuffixText: deletedSuffixText,
      baselineGraphemes: baselineGraphemes,
      tokenStart: tokenStart,
      baselineToken: baselineGraphemes
          .sublist(tokenStart, trimmedBaselineLength)
          .join(),
    );
  }

  bool _isWhitespaceGrapheme(String grapheme) =>
      grapheme == ' ' ||
      grapheme == '\t' ||
      grapheme == '\n' ||
      grapheme == '\r';

  ({
    int firstTokenStart,
    int firstTokenEnd,
    List<String> firstTokenGraphemes,
    List<String> trailingGraphemes,
  })?
  _leadingTokenInfo(List<String> graphemes) {
    var firstTokenStart = 0;
    while (firstTokenStart < graphemes.length &&
        _isWhitespaceGrapheme(graphemes[firstTokenStart])) {
      firstTokenStart++;
    }

    var firstTokenEnd = firstTokenStart;
    while (firstTokenEnd < graphemes.length &&
        !_isWhitespaceGrapheme(graphemes[firstTokenEnd])) {
      firstTokenEnd++;
    }

    if (firstTokenEnd == firstTokenStart) {
      return null;
    }

    return (
      firstTokenStart: firstTokenStart,
      firstTokenEnd: firstTokenEnd,
      firstTokenGraphemes: graphemes.sublist(firstTokenStart, firstTokenEnd),
      trailingGraphemes: graphemes.sublist(firstTokenEnd),
    );
  }

  bool _tokenLooksRelatedToDeleteResetReplacement({
    required String currentToken,
    required String baselineToken,
    String? deletedSuffixText,
  }) {
    final currentTokenGraphemes = currentToken.characters.toList(
      growable: false,
    );
    if (currentTokenGraphemes.isEmpty) {
      return false;
    }

    final relatedReplacementTokenGraphemes = deletedSuffixText == null
        ? baselineToken.characters.toList(growable: false)
        : (baselineToken + deletedSuffixText).characters.toList(
            growable: false,
          );
    final replacementRelationThreshold =
        relatedReplacementTokenGraphemes.length < currentTokenGraphemes.length
        ? relatedReplacementTokenGraphemes.length
        : currentTokenGraphemes.length;
    final requiredReplacementRelationLength = replacementRelationThreshold < 2
        ? replacementRelationThreshold
        : 2;
    return _longestCommonCaseInsensitiveGraphemeSubsequenceLength(
          relatedReplacementTokenGraphemes,
          currentTokenGraphemes,
          maxLength: requiredReplacementRelationLength,
        ) >=
        requiredReplacementRelationLength;
  }

  ({String currentText, int? cursorOffset})?
  _normalizeDeleteResetLeadingFragment(
    String currentText, {
    int? cursorOffsetHint,
  }) {
    if (!_trimLeadingSuggestionSpaceAfterDelete || currentText.isEmpty) {
      return null;
    }

    final baselineState = _deleteResetBaselineState();
    if (baselineState == null) {
      return null;
    }

    final deletedSuffixText = baselineState.deletedSuffixText;
    if (deletedSuffixText == null || deletedSuffixText.characters.length < 2) {
      return null;
    }

    final currentGraphemes = currentText.characters.toList(growable: false);
    final tokenInfo = _leadingTokenInfo(currentGraphemes);
    if (tokenInfo == null ||
        tokenInfo.firstTokenGraphemes.length != 1 ||
        tokenInfo.trailingGraphemes.isEmpty ||
        !tokenInfo.trailingGraphemes.any(
          (grapheme) => !_isWhitespaceGrapheme(grapheme),
        )) {
      return null;
    }

    final firstToken = tokenInfo.firstTokenGraphemes.join();
    if (_tokenLooksRelatedToDeleteResetReplacement(
      currentToken: firstToken,
      baselineToken: baselineState.baselineToken,
      deletedSuffixText: deletedSuffixText,
    )) {
      return null;
    }

    final removedGraphemeCount = tokenInfo.firstTokenEnd;
    return (
      currentText: tokenInfo.trailingGraphemes.join(),
      cursorOffset: cursorOffsetHint == null
          ? null
          : cursorOffsetHint <= removedGraphemeCount
          ? 0
          : cursorOffsetHint - removedGraphemeCount,
    );
  }

  ({
    String previousText,
    int previousCursorOffset,
    String currentText,
    int? cursorOffset,
  })?
  _resolveDeleteResetContinuation(String currentText, {int? cursorOffsetHint}) {
    final baselineState = _deleteResetBaselineState();
    if (baselineState == null ||
        !_trimLeadingSuggestionSpaceAfterDelete ||
        currentText.isEmpty) {
      return null;
    }
    final baselineText = baselineState.baselineText;
    final baselineCursorOffset = baselineState.baselineCursorOffset;
    final deletedSuffixText = baselineState.deletedSuffixText;
    final baselineGraphemes = baselineState.baselineGraphemes;
    final tokenStart = baselineState.tokenStart;
    final baselineToken = baselineState.baselineToken;

    final currentGraphemes = currentText.characters.toList(growable: false);
    final hasLeadingReplacementSeparator =
        currentGraphemes.length > 1 &&
        _isWhitespaceGrapheme(currentGraphemes.first) &&
        !_isWhitespaceGrapheme(currentGraphemes[1]);
    final hasTrailingReplacementSeparator =
        currentGraphemes.isNotEmpty &&
        _isWhitespaceGrapheme(currentGraphemes.last);
    if (currentGraphemes.isEmpty ||
        (!hasLeadingReplacementSeparator && !hasTrailingReplacementSeparator)) {
      return null;
    }
    var mergedCurrentText = currentText;
    var mergedCursorOffsetHint = cursorOffsetHint;
    if (hasLeadingReplacementSeparator) {
      // After a delete-reset, the IME can prepend a separator to the
      // replacement token even though we're already replacing the current word.
      // Trim that separator before merging with the preserved baseline.
      mergedCurrentText = currentGraphemes.sublist(1).join();
      if (mergedCursorOffsetHint != null && mergedCursorOffsetHint > 0) {
        mergedCursorOffsetHint--;
      }
    }

    final mergedCurrentTokenGraphemes = mergedCurrentText.characters.toList(
      growable: false,
    );
    final mergedTokenInfo = _leadingTokenInfo(mergedCurrentTokenGraphemes);
    if (mergedTokenInfo == null) {
      return null;
    }
    final mergedCurrentToken = mergedTokenInfo.firstTokenGraphemes.join();
    final replacementLooksRelated = _tokenLooksRelatedToDeleteResetReplacement(
      currentToken: mergedCurrentToken,
      baselineToken: baselineToken,
      deletedSuffixText: deletedSuffixText,
    );

    final shouldAppendToBaseline =
        hasLeadingReplacementSeparator &&
        deletedSuffixText != null &&
        deletedSuffixText.isNotEmpty &&
        mergedCurrentToken.startsWith(deletedSuffixText);
    final shouldReplaceCurrentToken =
        !shouldAppendToBaseline &&
        ((hasTrailingReplacementSeparator && replacementLooksRelated) ||
            mergedCurrentToken.startsWith(baselineToken));
    if (!shouldReplaceCurrentToken && !shouldAppendToBaseline) {
      return null;
    }
    final mergedText = shouldReplaceCurrentToken
        ? baselineGraphemes.sublist(0, tokenStart).join() + mergedCurrentText
        : baselineText + mergedCurrentText;
    return (
      previousText: baselineText,
      previousCursorOffset: baselineCursorOffset,
      currentText: mergedText,
      cursorOffset: mergedCursorOffsetHint == null
          ? null
          : (shouldReplaceCurrentToken ? tokenStart : baselineCursorOffset) +
                mergedCursorOffsetHint,
    );
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

  String _trailingToken(String text) {
    final graphemes = text.characters.toList(growable: false);
    var tokenEnd = graphemes.length;
    while (tokenEnd > 0 && _isWhitespaceGrapheme(graphemes[tokenEnd - 1])) {
      tokenEnd--;
    }
    if (tokenEnd == 0) {
      return '';
    }

    var tokenStart = tokenEnd;
    while (tokenStart > 0 &&
        !_isWhitespaceGrapheme(graphemes[tokenStart - 1])) {
      tokenStart--;
    }
    return graphemes.sublist(tokenStart, tokenEnd).join();
  }

  ({String currentText, int? cursorOffset})? _normalizeSplitLeadingToken(
    String currentText, {
    int? cursorOffsetHint,
  }) {
    if (!_allowSplitLeadingTokenNormalization ||
        _lastSentText.isEmpty ||
        !_splitLeadingTokenCandidatePattern.hasMatch(currentText)) {
      return null;
    }

    final previousTrailingToken = _trailingToken(_lastSentText);
    if (previousTrailingToken.characters.length < 2) {
      return null;
    }

    final currentGraphemes = currentText.characters.toList(growable: false);
    final currentTextLength = currentGraphemes.length;
    final previousTextLength = _textLengthInGraphemes(_lastSentText);
    if (_lastSentCursorOffset != previousTextLength ||
        cursorOffsetHint == null ||
        cursorOffsetHint != currentTextLength) {
      return null;
    }
    final tokenInfo = _leadingTokenInfo(currentGraphemes);
    if (tokenInfo == null ||
        tokenInfo.firstTokenGraphemes.length != 1 ||
        tokenInfo.trailingGraphemes.isEmpty) {
      return null;
    }

    var separatorLength = 0;
    while (separatorLength < tokenInfo.trailingGraphemes.length &&
        _isWhitespaceGrapheme(tokenInfo.trailingGraphemes[separatorLength])) {
      separatorLength++;
    }
    if (separatorLength == 0 ||
        separatorLength == tokenInfo.trailingGraphemes.length) {
      return null;
    }

    var nextTokenEnd = separatorLength;
    while (nextTokenEnd < tokenInfo.trailingGraphemes.length &&
        !_isWhitespaceGrapheme(tokenInfo.trailingGraphemes[nextTokenEnd])) {
      nextTokenEnd++;
    }
    if (nextTokenEnd == separatorLength) {
      return null;
    }

    final mergedLeadingToken =
        tokenInfo.firstTokenGraphemes.join() +
        tokenInfo.trailingGraphemes
            .sublist(separatorLength, nextTokenEnd)
            .join();
    final continuesPreviousTrailingToken =
        mergedLeadingToken.startsWith(previousTrailingToken) ||
        previousTrailingToken.startsWith(mergedLeadingToken);
    if (!continuesPreviousTrailingToken) {
      return null;
    }

    _allowSplitLeadingTokenNormalization = false;
    final separatorStart = tokenInfo.firstTokenEnd;
    final separatorEnd = separatorStart + separatorLength;
    final leadingPrefix = currentGraphemes
        .sublist(0, tokenInfo.firstTokenStart)
        .join();
    final normalizedCursorOffset = cursorOffsetHint <= separatorStart
        ? cursorOffsetHint
        : cursorOffsetHint <= separatorEnd
        ? separatorStart
        : cursorOffsetHint - separatorLength;
    return (
      currentText:
          leadingPrefix +
          tokenInfo.firstTokenGraphemes.join() +
          tokenInfo.trailingGraphemes.sublist(separatorLength).join(),
      cursorOffset: normalizedCursorOffset,
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
  _computeTextDelta(
    String currentText, {
    int? cursorOffsetHint,
    String? previousTextOverride,
    int? lastCursorOffsetOverride,
  }) {
    final previousText = previousTextOverride ?? _lastSentText;
    final lastCursorOffset = lastCursorOffsetOverride ?? _lastSentCursorOffset;
    final previousGraphemes = previousText.characters.toList(growable: false);
    final currentGraphemes = currentText.characters.toList(growable: false);
    final defaultDelta = _computeTextDeltaCandidate(
      previousGraphemes,
      currentGraphemes,
    );
    if (cursorOffsetHint == null) {
      return defaultDelta;
    }

    final anchoredPrefixLimit = lastCursorOffset < cursorOffsetHint
        ? lastCursorOffset
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
      lastCursorOffset: lastCursorOffset,
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

  String _applyTerminalTextInputModifiers(String text) {
    final applyModifiers = widget.applyTerminalTextInputModifiers;
    if (applyModifiers == null) {
      return text;
    }

    final normalizedText = text == '\n' ? '\r' : text;
    return applyModifiers(normalizedText);
  }

  int _deltaCursorScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
    int cursorOffsetHint,
  ) => (_deltaPostEditCursorOffset(delta) - cursorOffsetHint).abs();

  int _deltaMovementScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
    int lastCursorOffset,
  ) => (delta.deleteCursorOffset - lastCursorOffset).abs();

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
    required int lastCursorOffset,
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

    final defaultMovementScore = _deltaMovementScore(
      defaultDelta,
      lastCursorOffset,
    );
    final anchoredMovementScore = _deltaMovementScore(
      anchoredDelta,
      lastCursorOffset,
    );
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

    if (_editingValueShowsImeInteraction(value)) {
      _hasPendingPromptOutputImeReset = true;
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
        _cancelDeferredTrailingBackspaceImeClear();
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
        _cancelDeferredTrailingBackspaceImeClear();
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
      final normalizedSplitLeadingToken = _normalizeSplitLeadingToken(
        currentText,
        cursorOffsetHint: targetCursorOffset,
      );
      final splitNormalizedCurrentText =
          normalizedSplitLeadingToken?.currentText ?? currentText;
      final splitNormalizedTargetCursorOffset =
          normalizedSplitLeadingToken?.cursorOffset ?? targetCursorOffset;
      final normalizedDeleteResetLeadingFragment =
          _normalizeDeleteResetLeadingFragment(
            splitNormalizedCurrentText,
            cursorOffsetHint: splitNormalizedTargetCursorOffset,
          );
      final normalizedCurrentText =
          normalizedDeleteResetLeadingFragment?.currentText ??
          splitNormalizedCurrentText;
      final normalizedTargetCursorOffset =
          normalizedDeleteResetLeadingFragment?.cursorOffset ??
          splitNormalizedTargetCursorOffset;
      if (normalizedCurrentText == _lastSentText) {
        final collapsedMoveAwayFromReplacement =
            !_lastProcessedSelectionWasCollapsed &&
            normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset &&
            normalizedTargetCursorOffset != _lastSentCursorOffset + 1;
        final movedCollapsedCursor =
            _lastProcessedUserSelectionWasValid &&
            (_lastProcessedSelectionWasCollapsed ||
                collapsedMoveAwayFromReplacement) &&
            normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset;
        final shouldClearAfterCollapsedCursorMove =
            _clearImeAfterNextTouchCursorMove &&
            normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset;
        if (normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset) {
          _notifyUserInput();
          _moveTerminalCursorTo(normalizedTargetCursorOffset);
        }
        _clearImeAfterNextTouchCursorMove = false;
        if (shouldClearAfterCollapsedCursorMove) {
          _clearImeBufferForFreshInput();
          _sawImeComposition = false;
          return;
        }
        _cancelDeferredTrailingBackspaceImeClear();
        _syncEditingStateWithUserText(
          normalizedCurrentText,
          sourceValue: value,
          forceResyncState: movedCollapsedCursor,
        );
        _sawImeComposition = false;
        return;
      }

      _clearImeAfterNextTouchCursorMove = false;
      final deleteResetContinuation = _resolveDeleteResetContinuation(
        normalizedCurrentText,
        cursorOffsetHint: normalizedTargetCursorOffset,
      );
      final effectiveCurrentText =
          deleteResetContinuation?.currentText ?? normalizedCurrentText;
      final effectiveTargetCursorOffset =
          deleteResetContinuation?.cursorOffset ?? normalizedTargetCursorOffset;
      final deltaPreviousText =
          deleteResetContinuation?.previousText ?? _lastSentText;
      final deltaPreviousCursorOffset =
          deleteResetContinuation?.previousCursorOffset ??
          _lastSentCursorOffset;
      final delta = _computeTextDelta(
        effectiveCurrentText,
        cursorOffsetHint: effectiveTargetCursorOffset,
        previousTextOverride: deleteResetContinuation?.previousText,
        lastCursorOffsetOverride: deleteResetContinuation?.previousCursorOffset,
      );
      final pendingInputIsTrailingPureDeletion =
          deltaPreviousText.isNotEmpty &&
          delta.deletedCount > 0 &&
          delta.appendedText.isEmpty &&
          delta.deleteCursorOffset == deltaPreviousText.characters.length;
      if (!pendingInputIsTrailingPureDeletion) {
        _cancelDeferredTrailingBackspaceImeClear();
      }
      final review = _reviewForInsertedText(effectiveCurrentText, delta);
      if (review != null) {
        final shouldInsert = await widget.onReviewInsertedText!(review);
        if (!mounted || revision != _latestEditingValueRevision) {
          return;
        }
        if (!shouldInsert) {
          _cancelDeferredTrailingBackspaceImeClear();
          _syncEditingStateWithUserText(_lastSentText);
          _sawImeComposition = false;
          return;
        }
      }

      if (effectiveCurrentText != _lastSentText) {
        _notifyUserInput();
      }
      final previousText = deltaPreviousText;

      // Capture modifier state BEFORE sending the delta. The send path
      // synchronously fires terminal.onOutput which may consume one-shot
      // toolbar modifiers (e.g. Ctrl). Checking after would always be false.
      final hadActiveToolbarModifier =
          widget.hasActiveToolbarModifier?.call() ?? false;

      if (deleteResetContinuation != null) {
        _lastSentText = deltaPreviousText;
        _lastSentCursorOffset = deltaPreviousCursorOffset;
      }
      final newlineCount = _sendInputDelta(effectiveCurrentText, delta);
      if (newlineCount > 0) {
        _resetCommittedInputState(pendingEnterSuppressions: newlineCount);
        _trimLeadingSuggestionSpaceAfterDelete = true;
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
      final wasTrailingPureDeletion =
          wasPureDeletion && pendingInputIsTrailingPureDeletion;
      final wasModifiedSingleChar =
          delta.deletedCount == 0 &&
          delta.appendedText.characters.length == 1 &&
          hadActiveToolbarModifier;

      // Also detect the second character of a two-part chord like tmux's
      // Ctrl+b, c. After the first modifier character resets, the follow-up
      // character is sent without a modifier but is still part of the chord
      // and should not accumulate in the IME suggestion context.
      //
      // A short time window (500 ms) distinguishes rapid chord follow-ups
      // from normal typing after a standalone modifier like Ctrl+C.
      final chordResetTime = _modifierChordResetTime;
      final chordElapsed = chordResetTime == null
          ? null
          : _readModifierChordClock().difference(chordResetTime);
      final wasChordFollowUp =
          chordElapsed != null &&
          !chordElapsed.isNegative &&
          chordElapsed < modifierChordFollowUpWindow &&
          delta.deletedCount == 0 &&
          delta.appendedText.characters.length == 1;

      if (wasModifiedSingleChar || wasChordFollowUp) {
        // The character was transformed into a control code by the toolbar
        // modifier (or is the follow-up of a two-part chord), so it does
        // not represent visible terminal text. Do a full reset — the
        // shell's response to a control code is unpredictable.
        _clearImeBufferForFreshInput(
          armModifierChordWindow: wasModifiedSingleChar,
          armSplitLeadingTokenNormalization: true,
        );
        _sawImeComposition = false;
        return;
      }

      // Any non-chord input clears the chord follow-up window.
      _modifierChordResetTime = null;

      if (wasTrailingPureDeletion) {
        final previousGraphemes = previousText.characters.toList(
          growable: false,
        );
        final currentGraphemes = effectiveCurrentText.characters.toList(
          growable: false,
        );
        final deletedSuffixText = previousGraphemes
            .sublist(currentGraphemes.length)
            .join();
        if (_shouldDeferTrailingBackspaceImeClear) {
          _trimLeadingSuggestionSpaceAfterDelete = true;
          _scheduleDeferredTrailingBackspaceImeClear(
            baselineText: effectiveCurrentText,
            baselineCursorOffset: _lastSentCursorOffset,
            deletedSuffixText: deletedSuffixText,
          );
        } else {
          _clearImeBufferForFreshInput(
            deleteResetBaselineText: effectiveCurrentText,
            deleteResetBaselineCursorOffset: _lastSentCursorOffset,
            deleteResetDeletedSuffixText: deletedSuffixText,
          );
        }
        _sawImeComposition = false;
        return;
      }

      _cancelDeferredTrailingBackspaceImeClear();
      _clearPendingDeleteResetBaseline();

      // For IME replacements that shorten text (e.g. autocorrect), keep the
      // suggestion-space-trim flag since the IME may prepend a space to the
      // next swiped word.
      _trimLeadingSuggestionSpaceAfterDelete =
          previousText.isNotEmpty &&
          effectiveCurrentText.characters.length <
              previousText.characters.length;
      _trimLeadingSwipeSpaceAfterBufferClear =
          previousText.isNotEmpty && effectiveCurrentText.isEmpty;
      if (effectiveTargetCursorOffset != null) {
        _moveTerminalCursorTo(effectiveTargetCursorOffset);
      }
      _syncEditingStateWithUserText(
        effectiveCurrentText,
        sourceValue:
            normalizedPendingEnter.strippedPendingEnter ||
                normalizedSplitLeadingToken != null ||
                normalizedDeleteResetLeadingFragment != null ||
                effectiveCurrentText != normalizedCurrentText
            ? null
            : value,
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
      final modifiers = widget.resolveTerminalKeyModifiers?.call();
      _hasPendingPromptOutputImeReset = true;
      _notifyUserInput();
      sendTerminalEnterInput(
        widget.terminal,
        shiftActive: modifiers?.shift ?? false,
        altActive: modifiers?.alt ?? false,
        ctrlActive: modifiers?.ctrl ?? false,
      );
      widget.consumeTerminalKeyModifiers?.call();
      _pendingPerformedEnterText = _lastSentText;
      _resetCommittedInputState(clearPendingPerformedEnterText: false);
      _trimLeadingSuggestionSpaceAfterDelete = true;
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
    _stopHardwareKeyRepeat();
    _cancelDeferredTrailingBackspaceImeClear();
    _invalidatePendingEditingUpdates();
    _sawImeComposition = false;
    _hasPendingPromptOutputImeReset = false;
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    _pendingPerformedEnterText = null;
    _lastProcessedUserSelectionWasValid = false;
    _lastProcessedSelectionWasCollapsed = true;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _allowSplitLeadingTokenNormalization = false;
    _modifierChordResetTime = null;
    _pendingEnterActionSuppressions = 0;
    _currentEditingState = _initEditingState.copyWith();
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}
}
