import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../app/routes.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/remote_file_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_hyperlink_tracker.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/keyboard_toolbar.dart';
import '../widgets/monkey_terminal_view.dart';
import '../widgets/terminal_pinch_zoom_gesture_handler.dart';
import '../widgets/terminal_text_input_handler.dart';
import '../widgets/terminal_theme_picker.dart';

const _minTerminalFontSize = 8.0;
const _maxTerminalFontSize = 32.0;
const _terminalFollowOutputTolerance = 1.0;
const _selectionActionsBottomPadding = 12.0;
final _trailingTerminalPaddingPattern = RegExp(r' +$');
const _clipboardContentChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/clipboard_content',
);
final _terminalLinkPattern = RegExp(
  r'''(?:(?:https?:\/\/)|(?:mailto:)|(?:tel:)|(?:www\.))[^\s<>"']+''',
  caseSensitive: false,
);

enum _AutoConnectReviewDecision { skip, runOnce, trustAndRun }

/// Padding around the terminal viewport.
///
/// Keep the terminal flush with the bottom edge so status lines from tools like
/// tmux use the full available height in every keyboard and toolbar state.
const terminalViewportPadding = EdgeInsets.fromLTRB(8, 8, 8, 0);

/// Clamps a terminal font size into the supported zoom range.
@visibleForTesting
double clampTerminalFontSize(num size) =>
    size.clamp(_minTerminalFontSize, _maxTerminalFontSize).toDouble();

/// Scales a terminal font size while keeping it within the supported range.
@visibleForTesting
double scaleTerminalFontSize(double baseSize, double scale) =>
    clampTerminalFontSize(baseSize * scale);

/// Applies an incremental pinch delta to the currently displayed font size.
@visibleForTesting
double applyTerminalScaleDelta(
  double currentFontSize,
  double previousScale,
  double nextScale,
) {
  final safePreviousScale = previousScale <= 0 ? 1.0 : previousScale;
  return scaleTerminalFontSize(currentFontSize, nextScale / safePreviousScale);
}

/// Resolves the currently displayed terminal font size.
@visibleForTesting
double resolveTerminalFontSize({
  required double globalFontSize,
  double? sessionFontSize,
  double? pinchFontSize,
}) => pinchFontSize ?? sessionFontSize ?? globalFontSize;

/// Trims terminal cell padding from the end of a rendered line.
@visibleForTesting
String trimTerminalLinePadding(String line) =>
    line.replaceFirst(_trailingTerminalPaddingPattern, '');

/// Trims per-line terminal padding from copied or overlaid terminal text.
@visibleForTesting
String trimTerminalSelectionText(String text) =>
    text.split('\n').map(trimTerminalLinePadding).join('\n');

/// Keeps floating selection actions above the bottom safe area.
@visibleForTesting
double selectionActionsBottomOffset(MediaQueryData mediaQuery) =>
    _selectionActionsBottomPadding + mediaQuery.padding.bottom;

/// Resolves a readable display name for a picked upload file.
@visibleForTesting
String resolvePickedTerminalUploadFileName(PlatformFile file, {int index = 0}) {
  final name = file.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  final filePath = file.path;
  if (filePath != null && filePath.isNotEmpty) {
    return path.basename(filePath);
  }
  return 'selected-file-${index + 1}';
}

/// Resolves a readable stream for a picked upload file when available.
@visibleForTesting
Stream<List<int>>? resolvePickedTerminalUploadReadStream(PlatformFile file) =>
    file.readStream ?? (file.path == null ? null : File(file.path!).openRead());

/// Trims punctuation that terminals commonly render immediately after a link.
@visibleForTesting
String trimTerminalLinkCandidate(String text) {
  var result = text;
  while (result.isNotEmpty) {
    if (result.endsWith(')')) {
      final openCount = '('.allMatches(result).length;
      final closeCount = ')'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    } else if (result.endsWith(']')) {
      final openCount = '['.allMatches(result).length;
      final closeCount = ']'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    } else if (result.endsWith('}')) {
      final openCount = '{'.allMatches(result).length;
      final closeCount = '}'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    }

    final lastCharacter = result[result.length - 1];
    if ('.!,?:;'.contains(lastCharacter)) {
      result = result.substring(0, result.length - 1);
      continue;
    }

    break;
  }
  return result;
}

/// Normalizes terminal-rendered link text before URI parsing.
@visibleForTesting
String normalizeTerminalLinkCandidate(String text) {
  final candidate = trimTerminalLinkCandidate(text.trim());
  if (candidate.toLowerCase().startsWith('www.')) {
    return 'https://$candidate';
  }
  return candidate;
}

/// Resolves a tappable terminal link at the given text offset, if present.
@visibleForTesting
({Uri uri, int start, int end})? detectTerminalLinkAtTextOffset(
  String text,
  int offset,
) {
  for (final match in _terminalLinkPattern.allMatches(text)) {
    final candidate = trimTerminalLinkCandidate(match.group(0)!);
    if (candidate.isEmpty) {
      continue;
    }

    final normalizedCandidate = normalizeTerminalLinkCandidate(candidate);
    final uri = Uri.tryParse(normalizedCandidate);
    if (uri == null || !isLaunchableTerminalUri(uri)) {
      continue;
    }

    final end = match.start + candidate.length;
    if (offset >= match.start && offset < end) {
      return (uri: uri, start: match.start, end: end);
    }
  }

  return null;
}

/// Whether a parsed terminal URI is safe to open externally.
@visibleForTesting
bool isLaunchableTerminalUri(Uri uri) =>
    uri.hasScheme &&
    <String>{
      'http',
      'https',
      'mailto',
      'tel',
    }.contains(uri.scheme.toLowerCase());

/// Extracts the currently selected text from the native selection overlay.
@visibleForTesting
String selectedNativeOverlayText(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed) {
    return '';
  }

  return selection.textInside(value.text);
}

/// Applies pasted or rendered text at the terminal cursor within a wrapped line.
@visibleForTesting
String applyTerminalCursorInsertion({
  required String currentText,
  required int cursorOffset,
  required String insertedText,
}) => currentText.replaceRange(cursorOffset, cursorOffset, insertedText);

/// Applies terminal-style backspaces before inserting newly committed text.
@visibleForTesting
String applyTerminalInputDelta({
  required String currentText,
  required int cursorOffset,
  required int deletedCount,
  required String appendedText,
}) {
  final deleteStart = cursorOffset > deletedCount
      ? cursorOffset - deletedCount
      : 0;
  return currentText.replaceRange(deleteStart, cursorOffset, appendedText);
}

@visibleForTesting
/// Resolves how much of a terminal row snapshot should remain after trimming.
int resolveTerminalLineSnapshotTextLength({
  required String text,
  required int preserveOffset,
  required bool preserveTrailingPadding,
}) {
  if (preserveTrailingPadding) {
    return text.length;
  }

  final trimmedLength = trimTerminalLinePadding(text).length;
  var clampedPreserveOffset = preserveOffset;
  if (clampedPreserveOffset < 0) {
    clampedPreserveOffset = 0;
  } else if (clampedPreserveOffset > text.length) {
    clampedPreserveOffset = text.length;
  }
  return trimmedLength >= clampedPreserveOffset
      ? trimmedLength
      : clampedPreserveOffset;
}

/// Whether to let xterm synthesize Up/Down keys for alt-buffer scroll.
///
/// We prefer explicit mouse-wheel reporting from terminal applications like
/// tmux, but still need the synthetic fallback whenever the active alt-buffer
/// app has not enabled wheel reporting yet.
@visibleForTesting
bool shouldUseSyntheticAltBufferScrollFallback({
  required bool isUsingAltBuffer,
  required bool preferExplicitMouseReporting,
  required bool terminalReportsMouseWheel,
}) {
  if (!isUsingAltBuffer) {
    return false;
  }

  if (!preferExplicitMouseReporting) {
    return true;
  }

  return !terminalReportsMouseWheel;
}

/// Whether mobile touch drags should be routed into terminal scroll input.
///
/// Full-screen apps like tmux or Copilot CLI need direct wheel or synthetic
/// arrow events instead of letting the Flutter viewport absorb the gesture.
@visibleForTesting
bool shouldRouteTouchScrollToTerminal({
  required bool isMobile,
  required bool isUsingAltBuffer,
  required bool terminalReportsMouseWheel,
}) => isMobile && (isUsingAltBuffer || terminalReportsMouseWheel);

/// Whether the native selection overlay should be visible for terminal content.
@visibleForTesting
bool shouldShowNativeSelectionOverlay({
  required bool isNativeSelectionMode,
  required bool routesTouchScrollToTerminal,
  required bool revealOverlayInTouchScrollMode,
}) =>
    isNativeSelectionMode &&
    (!routesTouchScrollToTerminal || revealOverlayInTouchScrollMode);

/// How a native selection change should update the mobile overlay state.
@visibleForTesting
enum NativeSelectionOverlayChange {
  /// Leaves the current overlay and selection mode state unchanged.
  none,

  /// Hides only the temporary overlay used during tmux touch-selection flows.
  hideTemporaryOverlay,

  /// Leaves native selection mode entirely so terminal input becomes editable.
  exitSelectionMode,
}

/// Resolves how collapsed mobile selections should unwind overlay state.
@visibleForTesting
NativeSelectionOverlayChange resolveNativeSelectionOverlayChange({
  required bool isMobilePlatform,
  required bool isNativeSelectionMode,
  required bool revealOverlayInTouchScrollMode,
  required TextSelection selection,
}) {
  if (!isNativeSelectionMode || !selection.isCollapsed) {
    return NativeSelectionOverlayChange.none;
  }

  if (revealOverlayInTouchScrollMode) {
    return NativeSelectionOverlayChange.hideTemporaryOverlay;
  }

  if (isMobilePlatform) {
    return NativeSelectionOverlayChange.exitSelectionMode;
  }

  return NativeSelectionOverlayChange.none;
}

String? _describeMouseMode(
  MouseMode mouseMode,
  MouseReportMode mouseReportMode,
) => switch (mouseMode) {
  MouseMode.none => null,
  MouseMode.clickOnly => 'Mouse clicks',
  MouseMode.upDownScroll => 'Mouse scroll (${mouseReportMode.name})',
  MouseMode.upDownScrollDrag => 'Mouse drag (${mouseReportMode.name})',
  MouseMode.upDownScrollMove => 'Mouse motion (${mouseReportMode.name})',
};

/// Whether live terminal output should keep following the current viewport.
@visibleForTesting
bool shouldFollowTerminalOutput({
  required bool hasScrollClients,
  required double currentOffset,
  required double maxScrollExtent,
  double tolerance = _terminalFollowOutputTolerance,
}) {
  if (!hasScrollClients) {
    return true;
  }

  return currentOffset >= maxScrollExtent - tolerance;
}

/// Whether terminal scroll policy state changed enough to require a rebuild.
@visibleForTesting
bool didTerminalScrollPolicyChange({
  required bool previousIsUsingAltBuffer,
  required bool nextIsUsingAltBuffer,
  required bool previousReportsMouseWheel,
  required bool nextReportsMouseWheel,
}) =>
    previousIsUsingAltBuffer != nextIsUsingAltBuffer ||
    previousReportsMouseWheel != nextReportsMouseWheel;

/// Terminal screen for SSH sessions.
class TerminalScreen extends ConsumerStatefulWidget {
  /// Creates a new [TerminalScreen].
  const TerminalScreen({required this.hostId, this.connectionId, super.key});

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  late Terminal _terminal;
  late final TerminalController _terminalController;
  late final ScrollController _terminalScrollController;
  late final ScrollController _nativeSelectionScrollController;
  late final TextEditingController _nativeSelectionController;
  late FocusNode _terminalFocusNode;
  final _terminalTextInputController = TerminalTextInputHandlerController();
  final _toolbarController = KeyboardToolbarController();
  SSHSession? _shell;
  StreamSubscription<void>? _doneSubscription;
  bool _isConnecting = true;
  String? _error;
  bool _showKeyboard = true;
  bool _isUsingAltBuffer = false;
  bool _terminalReportsMouseWheel = false;
  bool _hasTerminalSelection = false;
  bool _isNativeSelectionMode = false;
  bool _revealsNativeSelectionOverlayInTouchScrollMode = false;
  bool _isSyncingNativeScroll = false;
  int? _connectionId;
  double? _pinchFontSize;
  double? _lastPinchScale;
  double? _sessionFontSizeOverride;
  bool _isPinchZooming = false;
  bool _shouldFollowLiveOutput = true;
  bool _isTerminalScrollToBottomQueued = false;
  TerminalHyperlinkTracker? _terminalHyperlinkTracker;
  SshSession? _observedSession;
  bool _showsTerminalMetadata = false;

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

  bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isAndroidPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _routesTouchScrollToTerminal => shouldRouteTouchScrollToTerminal(
    isMobile: _isMobilePlatform,
    isUsingAltBuffer: _isUsingAltBuffer,
    terminalReportsMouseWheel: _terminalReportsMouseWheel,
  );

  bool get _showsNativeSelectionOverlay => shouldShowNativeSelectionOverlay(
    isNativeSelectionMode: _isNativeSelectionMode,
    routesTouchScrollToTerminal: _routesTouchScrollToTerminal,
    revealOverlayInTouchScrollMode:
        _revealsNativeSelectionOverlayInTouchScrollMode,
  );

  String? get _windowTitle => _observedSession?.windowTitle;

  String? get _iconName => _observedSession?.iconName;

  Uri? get _workingDirectory => _observedSession?.workingDirectory;

  String? get _workingDirectoryLabel =>
      formatTerminalWorkingDirectoryLabel(_workingDirectory);

  String? get _workingDirectoryPath =>
      resolveTerminalWorkingDirectoryPath(_workingDirectory);

  TerminalShellStatus? get _shellStatus => _observedSession?.shellStatus;

  int? get _lastExitCode => _observedSession?.lastExitCode;

  String _terminalCommandAfterInsertion(String insertedText) {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return insertedText;
    }
    return applyTerminalCursorInsertion(
      currentText: snapshot.text,
      cursorOffset: snapshot.cursorOffset,
      insertedText: insertedText,
    );
  }

  String _terminalCommandAfterInputDelta(
    ({int deletedCount, String appendedText}) delta,
    String fallbackText,
  ) {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return fallbackText;
    }

    return applyTerminalInputDelta(
      currentText: snapshot.text,
      cursorOffset: snapshot.cursorOffset,
      deletedCount: delta.deletedCount,
      appendedText: delta.appendedText,
    );
  }

  bool _sameTerminalCommandReview(
    TerminalCommandReview previous,
    TerminalCommandReview next,
  ) =>
      previous.command == next.command &&
      previous.bracketedPasteModeEnabled == next.bracketedPasteModeEnabled &&
      listEquals(previous.reasons, next.reasons);

  Future<bool> _confirmTerminalInsertionIfNeeded({
    required String insertedText,
    required TerminalCommandReview Function(String commandText) buildReview,
    required String title,
    required String Function(TerminalCommandReview review) messageBuilder,
    required String confirmLabel,
  }) async {
    while (mounted) {
      final review = buildReview(_terminalCommandAfterInsertion(insertedText));
      if (!review.requiresReview) {
        return true;
      }

      final shouldInsert = await _confirmCommandInsertion(
        title: title,
        message: messageBuilder(review),
        confirmLabel: confirmLabel,
        review: review,
      );
      if (!mounted || !shouldInsert) {
        return false;
      }

      final latestReview = buildReview(
        _terminalCommandAfterInsertion(insertedText),
      );
      if (_sameTerminalCommandReview(review, latestReview)) {
        return true;
      }
    }

    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminalScrollController = ScrollController()
      ..addListener(_handleTerminalScroll);
    _nativeSelectionScrollController = ScrollController()
      ..addListener(_syncTerminalScrollFromNative);
    _nativeSelectionController = TextEditingController();
    _isUsingAltBuffer = _terminal.isUsingAltBuffer;
    _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    _terminal.addListener(_onTerminalStateChanged);
    _terminalController.addListener(_onSelectionChanged);
    _terminalFocusNode = FocusNode();
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_loadHostAndConnect);
  }

  void _onTerminalStateChanged() {
    if (_isNativeSelectionMode) {
      _refreshNativeOverlayText(preserveSelection: true);
    }

    if (_shouldFollowLiveOutput) {
      _queueTerminalScrollToBottom();
    }

    final isUsingAltBuffer = _terminal.isUsingAltBuffer;
    final terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    if (!mounted ||
        !didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: _isUsingAltBuffer,
          nextIsUsingAltBuffer: isUsingAltBuffer,
          previousReportsMouseWheel: _terminalReportsMouseWheel,
          nextReportsMouseWheel: terminalReportsMouseWheel,
        )) {
      return;
    }

    setState(() {
      _isUsingAltBuffer = isUsingAltBuffer;
      _terminalReportsMouseWheel = terminalReportsMouseWheel;
    });
  }

  void _observeSessionMetadata(SshSession session) {
    if (identical(_observedSession, session)) {
      return;
    }

    _observedSession?.removeMetadataListener(_handleSessionMetadataChanged);
    _observedSession = session
      ..removeMetadataListener(_handleSessionMetadataChanged)
      ..addMetadataListener(_handleSessionMetadataChanged);
  }

  void _handleSessionMetadataChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _handleTerminalScroll() {
    _shouldFollowLiveOutput = shouldFollowTerminalOutput(
      hasScrollClients: _terminalScrollController.hasClients,
      currentOffset: _terminalScrollController.hasClients
          ? _terminalScrollController.offset
          : 0,
      maxScrollExtent: _terminalScrollController.hasClients
          ? _terminalScrollController.position.maxScrollExtent
          : 0,
    );
    _syncNativeScrollFromTerminal();
  }

  void _followLiveOutput() {
    _shouldFollowLiveOutput = true;
    _queueTerminalScrollToBottom();
  }

  void _queueTerminalScrollToBottom() {
    if (_isTerminalScrollToBottomQueued) {
      return;
    }

    _isTerminalScrollToBottomQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalScrollToBottomQueued = false;
      if (!mounted ||
          !_shouldFollowLiveOutput ||
          !_terminalScrollController.hasClients) {
        return;
      }

      final position = _terminalScrollController.position;
      if (shouldFollowTerminalOutput(
        hasScrollClients: true,
        currentOffset: _terminalScrollController.offset,
        maxScrollExtent: position.maxScrollExtent,
      )) {
        return;
      }

      _terminalScrollController.jumpTo(position.maxScrollExtent);
    });
  }

  void _onSelectionChanged() {
    if (!mounted) {
      return;
    }

    final selection = _terminalController.selection;
    final hasSelection = selection != null;
    if (_isMobilePlatform && hasSelection) {
      _enterNativeSelectionMode(
        initialRange: selection,
        revealOverlayInTouchScrollMode: _routesTouchScrollToTerminal,
      );
      return;
    }

    if (_hasTerminalSelection == hasSelection) {
      return;
    }

    setState(() {
      _hasTerminalSelection = hasSelection;
    });
  }

  void _syncNativeScrollFromTerminal() {
    if (!_showsNativeSelectionOverlay ||
        _isSyncingNativeScroll ||
        !_terminalScrollController.hasClients ||
        !_nativeSelectionScrollController.hasClients) {
      return;
    }

    _isSyncingNativeScroll = true;
    final targetOffset = _terminalScrollController.offset.clamp(
      0.0,
      _nativeSelectionScrollController.position.maxScrollExtent,
    );
    _nativeSelectionScrollController.jumpTo(targetOffset);
    _isSyncingNativeScroll = false;
  }

  void _syncTerminalScrollFromNative() {
    if (!_showsNativeSelectionOverlay ||
        _isSyncingNativeScroll ||
        !_nativeSelectionScrollController.hasClients ||
        !_terminalScrollController.hasClients) {
      return;
    }

    _isSyncingNativeScroll = true;
    final targetOffset = _nativeSelectionScrollController.offset.clamp(
      0.0,
      _terminalScrollController.position.maxScrollExtent,
    );
    _terminalScrollController.jumpTo(targetOffset);
    _isSyncingNativeScroll = false;
  }

  Future<void> _loadHostAndConnect() async {
    // Load host data first for theme
    final hostRepo = ref.read(hostRepositoryProvider);
    _host = await hostRepo.getById(widget.hostId);
    await _loadTheme();
    await _connect(preferredConnectionId: widget.connectionId);
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

  Future<bool> _restoreSessionThemeOverride(SshSession session) async {
    final brightness = Theme.of(context).brightness;
    final themeId = brightness == Brightness.dark
        ? session.terminalThemeDarkId
        : session.terminalThemeLightId;

    if (themeId == null) {
      if (mounted) {
        setState(() => _sessionThemeOverride = null);
      }
      return false;
    }

    final themeService = ref.read(terminalThemeServiceProvider);
    final resolvedTheme = await themeService.getThemeById(themeId);
    if (!mounted) {
      return false;
    }
    setState(() => _sessionThemeOverride = resolvedTheme);
    return resolvedTheme != null;
  }

  Future<void> _connect({
    int? preferredConnectionId,
    bool forceNew = false,
  }) async {
    if (!mounted) return;

    // Clean up any previous connection state before reconnecting.
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    _shell = null;

    setState(() {
      _isConnecting = true;
      _error = null;
    });

    _sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    var shouldForceNew = forceNew;
    if (preferredConnectionId != null) {
      _connectionId = preferredConnectionId;
      final existingSession = _sessionsNotifier!.getSession(
        preferredConnectionId,
      );
      if (existingSession != null) {
        await _sessionsNotifier!.syncBackgroundStatus();
        await _openShell(existingSession);
        return;
      }
      shouldForceNew = true;
    }

    final result = await _sessionsNotifier!.connect(
      widget.hostId,
      forceNew: shouldForceNew,
    );

    if (!mounted) return;

    if (!result.success || result.connectionId == null) {
      setState(() {
        _isConnecting = false;
        _error = result.error ?? 'Connection failed';
      });
      return;
    }

    _connectionId = result.connectionId;
    final session = _sessionsNotifier!.getSession(_connectionId!);
    if (session == null) {
      setState(() {
        _isConnecting = false;
        _error = 'Session not found';
      });
      return;
    }

    await _openShell(session);
  }

  Future<void> _openShell(SshSession session) async {
    if (!mounted) {
      return;
    }

    try {
      // Reuse the session's persistent terminal if it exists (preserves
      // scrollback and screen buffer across screen navigations).
      final existingTerminal = session.terminal;
      if (existingTerminal != null) {
        _terminal.removeListener(_onTerminalStateChanged);
        _terminal = existingTerminal;
        _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
        _observeSessionMetadata(session);
        _isUsingAltBuffer = _terminal.isUsingAltBuffer;
        _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
        _terminal.addListener(_onTerminalStateChanged);
        _shell = await session.getShell();
        _wireTerminalCallbacks(session);
        await _restoreSessionThemeOverride(session);
        setState(() {
          _sessionFontSizeOverride = session.terminalFontSize;
          _isConnecting = false;
        });
        _restoreTerminalFocus();
        return;
      }

      // First time opening shell for this session — create terminal in session.
      final sessionTerminal = session.getOrCreateTerminal();
      _terminal.removeListener(_onTerminalStateChanged);
      _terminal = sessionTerminal;
      _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
      _observeSessionMetadata(session);
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      _terminal.addListener(_onTerminalStateChanged);

      _shell = await session.getShell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      _wireTerminalCallbacks(session);

      if (!mounted) return;

      await _restoreSessionThemeOverride(session);
      setState(() {
        _sessionFontSizeOverride = session.terminalFontSize;
        _isConnecting = false;
      });
      _restoreTerminalFocus();

      // Start port forwards
      await _startPortForwards(session);
      await _runAutoConnectCommand();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _error = 'Failed to start shell: $e';
      });
    }
  }

  /// Wire terminal onOutput/onResize callbacks for this screen instance.
  void _wireTerminalCallbacks(SshSession session) {
    // Listen for shell close events.
    _doneSubscription = session.shellDoneStream.listen((_) {
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
      output = _toolbarController.applySystemKeyboardModifiers(output);

      _shell?.write(utf8.encode(output));
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _shell?.resizeTerminal(width, height);
    };
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
      } else if (forward.forwardType == 'remote') {
        final success = await session.startRemoteForward(
          portForwardId: forward.id,
          remoteHost: forward.remoteHost,
          remotePort: forward.remotePort,
          localHost: forward.localHost,
          localPort: forward.localPort,
        );
        if (success) {
          startedCount++;
        } else {
          failedNames.add(forward.name);
        }
      }
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

  Future<void> _runAutoConnectCommand() async {
    final host = _host;
    final shell = _shell;
    if (host == null || shell == null) {
      return;
    }

    final mode = resolveAutoConnectCommandMode(
      command: host.autoConnectCommand,
      snippetId: host.autoConnectSnippetId,
    );
    if (mode == AutoConnectCommandMode.none) {
      return;
    }

    String? snippetCommand;
    int? resolvedSnippetId;
    final snippetId = host.autoConnectSnippetId;
    if (snippetId != null) {
      final snippetRepo = ref.read(snippetRepositoryProvider);
      final snippet = await snippetRepo.getById(snippetId);
      if (snippet == null) {
        debugPrint(
          'Auto-connect snippet $snippetId is unavailable; using cached command.',
        );
      } else {
        snippetCommand = snippet.command;
        resolvedSnippetId = snippet.id;
      }
    }

    final command = resolveAutoConnectCommandText(
      mode: mode,
      storedCommand: host.autoConnectCommand,
      snippetCommand: snippetCommand,
    );
    if (command == null) {
      return;
    }

    final review = assessAutoConnectCommandExecution(
      command,
      importedNeedsReview: host.autoConnectRequiresConfirmation,
    );
    if (review.requiresReview) {
      final decision = await _reviewImportedAutoConnectCommand(review);
      if (!mounted || decision == _AutoConnectReviewDecision.skip) {
        return;
      }
      if (decision == _AutoConnectReviewDecision.trustAndRun) {
        final updatedHost = host.copyWith(
          autoConnectRequiresConfirmation: false,
        );
        await ref.read(hostRepositoryProvider).update(updatedHost);
        _host = updatedHost;
      }
    }

    shell.write(utf8.encode(formatAutoConnectCommandForShell(command)));
    if (resolvedSnippetId != null) {
      unawaited(
        ref.read(snippetRepositoryProvider).incrementUsage(resolvedSnippetId),
      );
    }
  }

  void _handleTrackedConnectionStateChange(
    Map<int, SshConnectionState>? previous,
    Map<int, SshConnectionState> next,
  ) {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }

    final previousState =
        previous?[connectionId] ?? SshConnectionState.disconnected;
    final nextState = next[connectionId] ?? SshConnectionState.disconnected;
    if (previousState == nextState ||
        nextState != SshConnectionState.disconnected) {
      return;
    }

    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = true;
      return;
    }
    if (!mounted) {
      return;
    }

    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    _terminalFocusNode.unfocus();
    setState(() {
      _isConnecting = false;
      _error ??= 'Connection closed';
    });
  }

  void _handleShellClosed() {
    final connectionId = _connectionId;
    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    if (!mounted) {
      if (connectionId != null) {
        unawaited(
          _sessionsNotifier?.handleUnexpectedDisconnect(
            connectionId,
            message: 'Connection closed',
          ),
        );
      }
      return;
    }
    // If the app is in the background, don't show the error screen
    // immediately — defer it so we can auto-reconnect on resume.
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = true;
    } else {
      setState(() {
        _isConnecting = false;
        _error = 'Connection closed';
      });
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    }
    // Clean up the session state regardless of background/foreground.
    if (connectionId != null) {
      unawaited(
        _sessionsNotifier?.handleUnexpectedDisconnect(
          connectionId,
          message: 'Connection closed',
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    final connectionId = _connectionId;
    _connectionId = null;
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    _shell = null;
    if (connectionId != null) {
      await _sessionsNotifier?.disconnect(connectionId);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _reconnect() async {
    if (_isConnecting) {
      return;
    }
    if (mounted) {
      setState(() {
        _isConnecting = true;
        _error = null;
      });
    } else {
      _isConnecting = true;
      _error = null;
    }

    final previousConnectionId = _connectionId;
    _connectionId = null;
    _connectionLostWhileBackgrounded = false;
    try {
      await _doneSubscription?.cancel();
      _doneSubscription = null;
      _shell = null;
      if (previousConnectionId != null) {
        await _sessionsNotifier?.disconnect(previousConnectionId);
      }
      if (!mounted) {
        return;
      }
      await _connect(forceNew: true);
    } finally {
      if (!mounted) {
        _isConnecting = false;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _observedSession?.removeMetadataListener(_handleSessionMetadataChanged);
    _terminal.removeListener(_onTerminalStateChanged);
    _terminalController
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _terminalScrollController
      ..removeListener(_handleTerminalScroll)
      ..dispose();
    _nativeSelectionScrollController
      ..removeListener(_syncTerminalScrollFromNative)
      ..dispose();
    _nativeSelectionController.dispose();
    _doneSubscription?.cancel();
    _terminalFocusNode.dispose();
    _toolbarController.dispose();
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
        _reconnect();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload theme when system brightness changes
    if (_currentTheme == null) {
      return;
    }

    final session = _connectionId == null
        ? null
        : _sessionsNotifier?.getSession(_connectionId!);
    if (session != null) {
      unawaited(
        _restoreSessionThemeOverride(session).then((restored) {
          if (!restored) {
            return _loadTheme();
          }
        }),
      );
      return;
    }

    if (_sessionThemeOverride == null) {
      _loadTheme();
    }
  }

  List<Widget> _buildTerminalStatusChips(ThemeData theme) {
    final chipLabels = <({IconData icon, String label, String tooltip})>[
      if (_workingDirectoryLabel case final workingDirectory?
          when workingDirectory.isNotEmpty)
        (
          icon: Icons.folder_outlined,
          label: workingDirectory,
          tooltip: 'Current working directory reported by the shell session.',
        ),
      if (describeTerminalShellStatus(_shellStatus, lastExitCode: _lastExitCode)
          case final shellStatusLabel? when shellStatusLabel.isNotEmpty)
        (
          icon: Icons.play_circle_outline,
          label: shellStatusLabel,
          tooltip:
              'Shell integration status for the current prompt or command.',
        ),
      if (_isUsingAltBuffer)
        (
          icon: Icons.aspect_ratio,
          label: 'Alt buffer',
          tooltip:
              'A full-screen terminal app is using the alternate screen buffer.',
        ),
      if (_describeMouseMode(_terminal.mouseMode, _terminal.mouseReportMode)
          case final mouseModeLabel? when mouseModeLabel.isNotEmpty)
        (
          icon: Icons.mouse_outlined,
          label: mouseModeLabel,
          tooltip:
              'Terminal apps like tmux are actively receiving mouse input events.',
        ),
      if (_terminal.reportFocusMode)
        (
          icon: Icons.center_focus_strong,
          label: 'Focus reports',
          tooltip:
              'The terminal is reporting focus gained and lost events to the shell.',
        ),
      if (_terminal.bracketedPasteMode)
        (
          icon: Icons.content_paste,
          label: 'Bracketed paste',
          tooltip:
              'Paste operations are wrapped so terminal apps can handle them safely.',
        ),
    ];

    return chipLabels
        .map(
          (chip) => _TerminalStatusChip(
            icon: chip.icon,
            label: chip.label,
            tooltip: chip.tooltip,
            colorScheme: theme.colorScheme,
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<int, SshConnectionState>>(
      activeSessionsProvider,
      _handleTrackedConnectionStateChange,
    );
    final theme = Theme.of(context);
    final connectionStates = ref.watch(activeSessionsProvider);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final systemKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final connectionState = _connectionId == null
        ? SshConnectionState.disconnected
        : connectionStates[_connectionId!] ?? SshConnectionState.disconnected;
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;

    // Use session override, or loaded theme, or fallback
    final terminalTheme =
        _sessionThemeOverride ??
        _currentTheme ??
        (isDark ? TerminalThemes.midnightPurple : TerminalThemes.cleanWhite);
    final titleSubtitleSegments = <String>[];
    if ((_iconName ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_iconName!);
    }
    if ((_windowTitle ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_windowTitle!);
    }
    final titleSubtitle = titleSubtitleSegments.join(' • ');
    final statusChips = _buildTerminalStatusChips(theme);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_host?.label ?? 'Terminal'),
            if (titleSubtitle.isNotEmpty)
              Text(
                titleSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        bottom: !_showsTerminalMetadata || statusChips.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: Container(
                  alignment: Alignment.centerLeft,
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: statusChips
                          .map(
                            (chip) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: chip,
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                ),
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            onPressed:
                _connectionId == null ||
                    connectionState != SshConnectionState.connected
                ? null
                : _openConnectionFileBrowser,
            tooltip: 'Browse files',
          ),
          if (isMobile)
            IconButton(
              icon: Icon(
                systemKeyboardVisible
                    ? Icons.keyboard_hide
                    : Icons.keyboard_alt_outlined,
              ),
              onPressed: () => _toggleSystemKeyboard(systemKeyboardVisible),
              tooltip: systemKeyboardVisible
                  ? 'Hide system keyboard'
                  : 'Show system keyboard',
            ),
          IconButton(
            icon: Icon(
              _showKeyboard ? Icons.space_bar : Icons.keyboard_outlined,
            ),
            onPressed: () => setState(() => _showKeyboard = !_showKeyboard),
            tooltip: _showKeyboard ? 'Hide toolbar' : 'Show toolbar',
          ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'snippets', child: Text('Snippets')),
              const PopupMenuItem(
                value: 'change_theme',
                child: Text('Change Theme'),
              ),
              if (statusChips.isNotEmpty)
                PopupMenuItem(
                  value: 'toggle_terminal_info',
                  child: Text(
                    _showsTerminalMetadata
                        ? 'Hide Terminal Info'
                        : 'Show Terminal Info',
                  ),
                ),
              const PopupMenuDivider(),
              if (!isMobile)
                PopupMenuItem(
                  value: 'native_select',
                  child: Text(
                    _isNativeSelectionMode
                        ? 'Exit Native Selection'
                        : 'Native Selection',
                  ),
                ),
              if (_workingDirectoryPath != null)
                const PopupMenuItem(
                  value: 'copy_working_directory',
                  child: Text('Copy Current Directory'),
                ),
              const PopupMenuItem(value: 'copy', child: Text('Copy')),
              const PopupMenuItem(value: 'paste', child: Text('Paste')),
              const PopupMenuItem(
                value: 'paste_image',
                child: Text('Paste Image'),
              ),
              const PopupMenuItem(
                value: 'paste_file',
                child: Text('Paste File'),
              ),
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
          if (_showKeyboard &&
              !showsDisconnectedOverlay &&
              (!_isNativeSelectionMode || _isMobilePlatform))
            KeyboardToolbar(
              controller: _toolbarController,
              terminal: _terminal,
              onKeyPressed: _followLiveOutput,
              terminalFocusNode: _terminalFocusNode,
            ),
        ],
      ),
    );
  }

  /// Toggles the system keyboard visibility on mobile platforms.
  void _toggleSystemKeyboard(bool isVisible) {
    if (isVisible) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    } else {
      _restoreTerminalFocus(showSystemKeyboard: true);
    }
  }

  void _restoreTerminalFocus({bool showSystemKeyboard = false}) {
    if (!mounted) {
      return;
    }
    _dismissNativeSelectionOverlayForEditing();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _terminalFocusNode.requestFocus();
      if (showSystemKeyboard && _isMobilePlatform) {
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
        );
      }
    });
  }

  void _handleTerminalScaleStart(double currentFontSize) {
    _pinchFontSize = currentFontSize;
    _lastPinchScale = 1;
    _isPinchZooming = false;
  }

  void _handleTerminalScaleUpdate(double scale, double currentFontSize) {
    final displayedFontSize = _pinchFontSize ?? currentFontSize;
    final previousScale = _lastPinchScale ?? 1;
    final nextFontSize = applyTerminalScaleDelta(
      displayedFontSize,
      previousScale,
      scale,
    );
    if (_isPinchZooming && _pinchFontSize == nextFontSize) {
      return;
    }

    setState(() {
      _isPinchZooming = true;
      _pinchFontSize = nextFontSize;
      _lastPinchScale = scale;
    });
  }

  void _handleTerminalScaleEnd() {
    final nextFontSize = _pinchFontSize;
    final connectionId = _connectionId;
    final shouldPersist =
        _isPinchZooming && nextFontSize != null && connectionId != null;
    setState(() {
      if (shouldPersist) {
        _sessionFontSizeOverride = nextFontSize;
      }
      _isPinchZooming = false;
      _lastPinchScale = null;
      _pinchFontSize = null;
    });

    if (!shouldPersist) {
      return;
    }

    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionFontSize(connectionId, nextFontSize);
  }

  Future<void> _showThemePicker() async {
    final currentId = _sessionThemeOverride?.id ?? _currentTheme?.id;
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );

    if (theme != null && mounted) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      if (_connectionId != null) {
        ref
            .read(activeSessionsProvider.notifier)
            .updateSessionTheme(_connectionId!, theme.id, isDark: isDark);
      }
      setState(() => _sessionThemeOverride = theme);

      // Show option to save to host
      if (_host != null) {
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

  Widget _buildConnectionIssueOverlay({
    required ThemeData theme,
    required Widget child,
    required String message,
    required bool showsDisconnectedOverlay,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      AbsorbPointer(child: child),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      showsDisconnectedOverlay
                          ? 'Disconnected'
                          : 'Connection Error',
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _isConnecting ? null : _reconnect,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reconnect'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildTerminalView(TerminalThemeData terminalTheme, bool isMobile) {
    final theme = Theme.of(context);
    final connectionStates = ref.watch(activeSessionsProvider);
    final connectionAttempt = ref
        .read(activeSessionsProvider.notifier)
        .getConnectionAttempt(widget.hostId);
    final connectionState = _connectionId == null
        ? SshConnectionState.disconnected
        : connectionStates[_connectionId!] ?? SshConnectionState.disconnected;
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;
    final overlayMessage = showsDisconnectedOverlay
        ? connectionAttempt?.latestMessage ?? _error ?? 'Connection closed'
        : _error;

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

    if (overlayMessage != null && _connectionId == null) {
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
                overlayMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isConnecting ? null : _reconnect,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Use a session override when pinch-zoom has customized this connection.
    final globalFontSize = ref.watch(fontSizeNotifierProvider);
    final storedFontSize = _sessionFontSizeOverride ?? globalFontSize;
    final fontSize = resolveTerminalFontSize(
      globalFontSize: globalFontSize,
      sessionFontSize: _sessionFontSizeOverride,
      pinchFontSize: _pinchFontSize,
    );

    // Get font family from host (if set) or global settings
    final hostFont = _host?.terminalFontFamily;
    final globalFont = ref.watch(fontFamilyNotifierProvider);
    final fontFamily = hostFont ?? globalFont;
    final terminalTextStyle = _getTerminalTextStyle(fontFamily, fontSize);
    final nativeSelectionTextStyle = _getNativeSelectionTextStyle(
      terminalTextStyle,
    );
    final routeTouchScrollToTerminal = _routesTouchScrollToTerminal;

    final terminalView = MonkeyTerminalView(
      _terminal,
      controller: _terminalController,
      scrollController: _terminalScrollController,
      resolveLinkTap: _resolveTerminalLinkTap,
      onLinkTapDown:
          _terminalTextInputController.suppressNextTouchKeyboardRequest,
      onLinkTap: _handleTerminalLinkTap,
      focusNode: isMobile ? null : _terminalFocusNode,
      theme: terminalTheme.toXtermTheme(),
      textStyle: terminalTextStyle,
      padding: terminalViewportPadding,
      deleteDetection: !isMobile,
      autofocus: !isMobile,
      hardwareKeyboardOnly: isMobile,
      // Let alt-buffer apps keep raw wheel events when they explicitly enable
      // mouse reporting, but fall back to synthetic arrows when they do not.
      simulateScroll: shouldUseSyntheticAltBufferScrollFallback(
        isUsingAltBuffer: _isUsingAltBuffer,
        preferExplicitMouseReporting: true,
        terminalReportsMouseWheel: _terminalReportsMouseWheel,
      ),
      touchScrollToTerminal: routeTouchScrollToTerminal,
      onInsertText: isMobile ? null : _confirmDesktopInsertedText,
      onPasteText: isMobile ? null : _pasteClipboard,
    );

    if (!isMobile) {
      return overlayMessage == null
          ? terminalView
          : _buildConnectionIssueOverlay(
              theme: theme,
              child: terminalView,
              message: overlayMessage,
              showsDisconnectedOverlay: showsDisconnectedOverlay,
            );
    }

    Widget mobileTerminalView = terminalView;

    // On mobile, wrap with our own text input handler that enables
    // IME suggestions so swipe typing correctly inserts spaces.
    if (_showsNativeSelectionOverlay) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          _nativeSelectionOverlay(nativeSelectionTextStyle),
        ],
      );
    } else if (_hasTerminalSelection) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          Positioned(
            left: 12,
            right: 12,
            bottom: selectionActionsBottomOffset(MediaQuery.of(context)),
            child: _selectionActions,
          ),
        ],
      );
    }

    if (_isPinchZooming) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          Positioned(
            top: 12,
            right: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withAlpha(220),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  '${fontSize.toStringAsFixed(0)} pt',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget terminalViewWithInput = TerminalTextInputHandler(
      terminal: _terminal,
      focusNode: _terminalFocusNode,
      controller: _terminalTextInputController,
      deleteDetection: true,
      onUserInput: _followLiveOutput,
      onReviewInsertedText: _confirmKeyboardInsertion,
      buildReviewTextForInsertedText: _terminalCommandAfterInputDelta,
      resolveTextBeforeCursor: _terminalTextBeforeCursor,
      readOnly: _showsNativeSelectionOverlay || overlayMessage != null,
      child: TerminalPinchZoomGestureHandler(
        onPinchStart: () => _handleTerminalScaleStart(storedFontSize),
        onPinchUpdate: (scale) =>
            _handleTerminalScaleUpdate(scale, storedFontSize),
        onPinchEnd: _handleTerminalScaleEnd,
        child: mobileTerminalView,
      ),
    );

    if (overlayMessage != null) {
      terminalViewWithInput = _buildConnectionIssueOverlay(
        theme: theme,
        child: terminalViewWithInput,
        message: overlayMessage,
        showsDisconnectedOverlay: showsDisconnectedOverlay,
      );
    }

    return terminalViewWithInput;
  }

  Widget _nativeSelectionOverlay(TextStyle textStyle) => Positioned.fill(
    child: Padding(
      padding: terminalViewportPadding,
      child: SingleChildScrollView(
        controller: _nativeSelectionScrollController,
        physics: const ClampingScrollPhysics(),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _nativeSelectionController,
          builder: (context, value, _) => SelectableText(
            value.text,
            style: textStyle,
            onSelectionChanged: _handleNativeOverlaySelectionChanged,
            strutStyle: StrutStyle.fromTextStyle(
              textStyle,
              forceStrutHeight: true,
            ),
          ),
        ),
      ),
    ),
  );

  /// Gets the terminal text style for the given font family using Google Fonts.
  TerminalStyle _getTerminalTextStyle(String fontFamily, double fontSize) {
    final textStyle = _resolveTerminalTextStyle(fontFamily, fontSize);
    if (textStyle != null) {
      return TerminalStyle.fromTextStyle(textStyle);
    }
    return TerminalStyle(fontSize: fontSize);
  }

  TextStyle _getNativeSelectionTextStyle(TerminalStyle terminalTextStyle) =>
      terminalTextStyle
          .toTextStyle(color: Colors.transparent)
          .copyWith(
            letterSpacing: 0,
            fontFeatures: const [
              FontFeature.disable('liga'),
              FontFeature.disable('calt'),
            ],
          );

  TextStyle? _resolveTerminalTextStyle(String fontFamily, double fontSize) =>
      switch (fontFamily) {
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

  void _openConnectionFileBrowser() {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }
    context.pushNamed(
      Routes.sftp,
      pathParameters: {'hostId': widget.hostId.toString()},
      queryParameters: {'connectionId': connectionId.toString()},
    );
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'snippets':
        await _showSnippetPicker();
        break;
      case 'change_theme':
        unawaited(_showThemePicker());
        break;
      case 'toggle_terminal_info':
        setState(() => _showsTerminalMetadata = !_showsTerminalMetadata);
        break;
      case 'native_select':
        _toggleNativeSelectionMode();
        break;
      case 'copy_working_directory':
        await _copyWorkingDirectory();
        break;
      case 'copy':
        await _copySelection();
        break;
      case 'paste':
        await _pasteClipboard();
        break;
      case 'paste_image':
        await _pastePickedImage();
        break;
      case 'paste_file':
        await _pastePickedFiles();
        break;
      case 'clear':
        _terminal.buffer.clear();
        _terminalController.clearSelection();
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        break;
      case 'disconnect':
        await _disconnect();
        break;
    }
  }

  void _toggleNativeSelectionMode() {
    if (_isMobilePlatform) {
      return;
    }
    if (_isNativeSelectionMode) {
      _exitNativeSelectionMode();
      return;
    }

    _enterNativeSelectionMode(initialRange: _terminalController.selection);
  }

  void _enterNativeSelectionMode({
    BufferRange? initialRange,
    bool revealOverlayInTouchScrollMode = false,
  }) {
    if (_isNativeSelectionMode && initialRange == null) {
      return;
    }

    _terminalFocusNode.unfocus();
    final snapshot = _buildNativeSelectionSnapshotData();
    final selection = initialRange == null
        ? const TextSelection.collapsed(offset: 0)
        : _bufferRangeToTextSelection(
            initialRange,
            viewWidth: _terminal.buffer.viewWidth,
            lineCount: _terminal.buffer.height,
            lineStarts: snapshot.lineStarts,
            columnOffsets: snapshot.columnOffsets,
            textLength: snapshot.text.length,
          );
    _nativeSelectionController.value = TextEditingValue(
      text: snapshot.text,
      selection: selection,
    );
    setState(() {
      _isNativeSelectionMode = true;
      _hasTerminalSelection = false;
      _revealsNativeSelectionOverlayInTouchScrollMode =
          _revealsNativeSelectionOverlayInTouchScrollMode ||
          revealOverlayInTouchScrollMode;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncNativeScrollFromTerminal();
    });
    if (_terminalController.selection != null) {
      _terminalController.clearSelection();
    }
  }

  void _exitNativeSelectionMode() {
    if (_isMobilePlatform) {
      return;
    }
    setState(() {
      _isNativeSelectionMode = false;
      _hasTerminalSelection = false;
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    _terminalFocusNode.requestFocus();
  }

  void _refreshNativeOverlayText({required bool preserveSelection}) {
    if (!_isNativeSelectionMode) {
      return;
    }
    final snapshot = _buildNativeSelectionSnapshotData();
    final previousSelection = _nativeSelectionController.selection;
    final maxOffset = snapshot.text.length;
    final nextSelection = preserveSelection
        ? TextSelection(
            baseOffset: previousSelection.baseOffset.clamp(0, maxOffset),
            extentOffset: previousSelection.extentOffset.clamp(0, maxOffset),
          )
        : const TextSelection.collapsed(offset: 0);
    _nativeSelectionController.value = TextEditingValue(
      text: snapshot.text,
      selection: nextSelection,
    );
  }

  ({String text, List<int> lineStarts, List<List<int>> columnOffsets})
  _buildNativeSelectionSnapshotData() {
    final buffer = _terminal.buffer;
    final builder = StringBuffer();
    final lineStarts = <int>[];
    final lineColumnOffsets = <List<int>>[];

    for (var i = 0; i < buffer.height; i++) {
      lineStarts.add(builder.length);
      final lineSnapshot = _buildNativeSelectionLineSnapshot(
        buffer.lines[i],
        buffer.viewWidth,
      );
      builder.write(lineSnapshot.text);
      lineColumnOffsets.add(lineSnapshot.columnOffsets);
      if (i < buffer.height - 1) {
        builder.write('\n');
      }
    }

    return (
      text: builder.toString(),
      lineStarts: lineStarts,
      columnOffsets: lineColumnOffsets,
    );
  }

  ({String text, List<int> columnOffsets}) _buildTerminalLineSnapshot(
    BufferLine line,
    int viewWidth, {
    required bool preserveTrailingPadding,
    int preserveOffset = 0,
  }) {
    final builder = StringBuffer();
    final columnOffsets = List<int>.filled(viewWidth + 1, 0);
    var col = 0;

    while (col < viewWidth) {
      final startOffset = builder.length;
      columnOffsets[col] = startOffset;
      final codePoint = line.getCodePoint(col);
      final width = line.getWidth(col);

      if (codePoint == 0) {
        builder.writeCharCode(0x20);
        columnOffsets[col + 1] = builder.length;
        col++;
        continue;
      }

      builder.writeCharCode(codePoint);
      final step = (width <= 0 ? 1 : width).clamp(1, viewWidth - col);
      for (var i = col + 1; i < col + step; i++) {
        columnOffsets[i] = startOffset;
      }
      columnOffsets[col + step] = builder.length;
      col += step;
    }

    final rawText = builder.toString();
    final resolvedLength = resolveTerminalLineSnapshotTextLength(
      text: rawText,
      preserveOffset: preserveOffset,
      preserveTrailingPadding: preserveTrailingPadding,
    );
    if (resolvedLength == rawText.length) {
      return (text: rawText, columnOffsets: columnOffsets);
    }

    for (var i = 0; i < columnOffsets.length; i++) {
      if (columnOffsets[i] > resolvedLength) {
        columnOffsets[i] = resolvedLength;
      }
    }
    return (
      text: rawText.substring(0, resolvedLength),
      columnOffsets: columnOffsets,
    );
  }

  ({String text, List<int> columnOffsets}) _buildNativeSelectionLineSnapshot(
    BufferLine line,
    int viewWidth,
  ) => _buildTerminalLineSnapshot(
    line,
    viewWidth,
    preserveTrailingPadding: false,
  );

  TextSelection _bufferRangeToTextSelection(
    BufferRange range, {
    required int viewWidth,
    required int lineCount,
    required List<int> lineStarts,
    required List<List<int>> columnOffsets,
    required int textLength,
  }) {
    final normalized = range.normalized;

    int toOffset(CellOffset position) {
      final y = position.y.clamp(0, lineCount - 1);
      final x = position.x.clamp(0, viewWidth);
      final lineStart = lineStarts[y];
      final lineOffset = columnOffsets[y][x];
      return (lineStart + lineOffset).clamp(0, textLength);
    }

    final start = toOffset(normalized.begin);
    final end = toOffset(normalized.end);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  void _handleNativeOverlaySelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    if (!mounted) {
      return;
    }

    switch (resolveNativeSelectionOverlayChange(
      isMobilePlatform: _isMobilePlatform,
      isNativeSelectionMode: _isNativeSelectionMode,
      revealOverlayInTouchScrollMode:
          _revealsNativeSelectionOverlayInTouchScrollMode,
      selection: selection,
    )) {
      case NativeSelectionOverlayChange.none:
        return;
      case NativeSelectionOverlayChange.hideTemporaryOverlay:
        setState(() {
          _revealsNativeSelectionOverlayInTouchScrollMode = false;
        });
        return;
      case NativeSelectionOverlayChange.exitSelectionMode:
        _dismissNativeSelectionOverlayForEditing();
        return;
    }
  }

  void _dismissTemporaryNativeSelectionOverlay() {
    if (!_revealsNativeSelectionOverlayInTouchScrollMode) {
      return;
    }

    final textLength = _nativeSelectionController.text.length;
    final collapsedOffset = _nativeSelectionController.selection.extentOffset
        .clamp(0, textLength);
    _nativeSelectionController.value = _nativeSelectionController.value
        .copyWith(selection: TextSelection.collapsed(offset: collapsedOffset));
    if (!mounted) {
      return;
    }
    setState(() {
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
  }

  void _dismissNativeSelectionOverlayForEditing() {
    if (!mounted) {
      return;
    }

    if (!_isNativeSelectionMode) {
      return;
    }

    if (_revealsNativeSelectionOverlayInTouchScrollMode) {
      _dismissTemporaryNativeSelectionOverlay();
      return;
    }

    if (!_isMobilePlatform) {
      return;
    }

    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    setState(() {
      _isNativeSelectionMode = false;
      _hasTerminalSelection = false;
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
  }

  String? _resolveTerminalLinkTap(CellOffset offset) {
    if (!_routesTouchScrollToTerminal || _showsNativeSelectionOverlay) {
      return null;
    }

    final trackedHyperlink = _terminalHyperlinkTracker?.resolveLinkAt(offset);
    if (trackedHyperlink != null) {
      return trackedHyperlink;
    }

    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    final line = _terminal.buffer.lines[row];
    if (line.getCodePoint(column) == 0) {
      return null;
    }

    final snapshot = _buildWrappedTerminalLinkSnapshot(row);
    if (snapshot == null) {
      return null;
    }

    final rowIndex = row - snapshot.startRow;
    final textOffset =
        snapshot.rowStarts[rowIndex] + snapshot.columnOffsets[rowIndex][column];
    return detectTerminalLinkAtTextOffset(
      snapshot.text,
      textOffset,
    )?.uri.toString();
  }

  ({
    String text,
    int startRow,
    List<int> rowStarts,
    List<List<int>> columnOffsets,
  })?
  _buildWrappedTerminalLinkSnapshot(int row) {
    final buffer = _terminal.buffer;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = _buildNativeSelectionLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
      );
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
    }

    return (
      text: builder.toString(),
      startRow: startRow,
      rowStarts: rowStarts,
      columnOffsets: columnOffsets,
    );
  }

  ({String text, int cursorOffset})? _buildWrappedTerminalCommandSnapshot() {
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = _buildTerminalLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
        preserveTrailingPadding: lineIndex < endRow,
        preserveOffset: lineIndex == row
            ? buffer.cursorX.clamp(0, buffer.viewWidth)
            : 0,
      );
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
    }

    final rowIndex = row - startRow;
    final cursorColumn = buffer.cursorX.clamp(0, buffer.viewWidth);
    final cursorOffset =
        rowStarts[rowIndex] + columnOffsets[rowIndex][cursorColumn];
    return (text: builder.toString(), cursorOffset: cursorOffset);
  }

  String? _terminalTextBeforeCursor() {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return null;
    }
    return snapshot.text.substring(0, snapshot.cursorOffset);
  }

  void _handleTerminalLinkTap(String link) {
    unawaited(_openTerminalLink(link));
  }

  void _showTerminalLinkMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTerminalLink(String link) async {
    final normalizedLink = normalizeTerminalLinkCandidate(link);
    final uri = Uri.tryParse(normalizedLink);
    if (uri == null) {
      _showTerminalLinkMessage('Could not open $link');
      return;
    }

    if (!isLaunchableTerminalUri(uri)) {
      _showTerminalLinkMessage('Blocked unsupported link scheme: $link');
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      launched = false;
    }
    if (launched || !mounted) {
      return;
    }

    _showTerminalLinkMessage('Could not open $link');
  }

  Widget get _selectionActions => Material(
    elevation: 2,
    borderRadius: BorderRadius.circular(12),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () => unawaited(_copySelection()),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copy'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () => unawaited(_pasteClipboard()),
              icon: const Icon(Icons.paste_outlined),
              label: const Text('Paste'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () {
                _terminalController.clearSelection();
                _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
              },
              icon: const Icon(Icons.close),
              label: const Text('Clear'),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _copySelection() async {
    if (_isNativeSelectionMode) {
      final text = selectedNativeOverlayText(_nativeSelectionController.value);
      if (text.isEmpty) {
        return;
      }

      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied')));
      return;
    }

    final selection = _terminalController.selection;
    if (selection == null) {
      return;
    }
    final text = trimTerminalSelectionText(_terminal.buffer.getText(selection));
    if (text.isEmpty) {
      _restoreTerminalFocus();
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    _terminalController.clearSelection();
    _restoreTerminalFocus();

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  void _showClipboardMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyWorkingDirectory() async {
    final path = _workingDirectoryPath;
    if (path == null || path.isEmpty) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    await Clipboard.setData(ClipboardData(text: path));
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied current directory')));
  }

  SshSession? _activeSession() {
    final connectionId = _connectionId;
    final sessionsNotifier = _sessionsNotifier;
    if (connectionId == null || sessionsNotifier == null) {
      return null;
    }
    return sessionsNotifier.getSession(connectionId);
  }

  Future<void> _pasteClipboard() async {
    try {
      if (_isAndroidPlatform) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes);
          return;
        }
      }

      final clipboardFiles = await Pasteboard.files();
      if (clipboardFiles.isNotEmpty) {
        await _pasteClipboardFiles(clipboardFiles);
        return;
      }

      if (!_isAndroidPlatform) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes);
          return;
        }
      }

      final text = await Pasteboard.text;
      if (text == null || text.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        _showClipboardMessage('Clipboard is empty');
        return;
      }

      final shouldPaste = await _confirmTerminalInsertionIfNeeded(
        insertedText: text,
        buildReview: (commandText) => assessClipboardPasteCommand(
          commandText,
          bracketedPasteModeEnabled: _terminal.bracketedPasteMode,
        ),
        title: 'Review clipboard paste',
        messageBuilder: (review) => review.bracketedPasteModeEnabled
            ? 'This clipboard content looks risky even with bracketed paste enabled.'
            : 'This clipboard content could execute multiple or reshaped commands.',
        confirmLabel: 'Paste anyway',
      );
      if (!shouldPaste) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      _followLiveOutput();
      _terminal.paste(text);
      _terminalController.clearSelection();
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    } on PlatformException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        'Clipboard access failed: ${error.message ?? error.code}',
      );
    } on FileSystemException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        error.message.isEmpty
            ? 'Clipboard file upload failed'
            : 'Clipboard file upload failed: ${error.message}',
      );
    } on SftpError catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Remote upload failed: ${error.message}');
    } on Object catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard upload failed: $error');
    }
  }

  Future<void> _pastePickedImage() async {
    await _pickAndPasteFiles(
      dialogTitle: 'Select image to upload',
      pickerType: FileType.image,
      itemLabelSingular: 'image',
      itemLabelPlural: 'images',
      allowMultiple: false,
      failureContext: 'Image picker upload',
    );
  }

  Future<void> _pastePickedFiles() async {
    await _pickAndPasteFiles(
      dialogTitle: 'Select file to upload',
      pickerType: FileType.any,
      itemLabelSingular: 'file',
      itemLabelPlural: 'files',
      allowMultiple: true,
      failureContext: 'File picker upload',
    );
  }

  Future<void> _pickAndPasteFiles({
    required String dialogTitle,
    required FileType pickerType,
    required String itemLabelSingular,
    required String itemLabelPlural,
    required bool allowMultiple,
    required String failureContext,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: dialogTitle,
        type: pickerType,
        allowMultiple: allowMultiple,
        withData: kIsWeb,
        withReadStream: !kIsWeb,
      );
      if (result == null || result.files.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      await _pasteSelectedFiles(
        result.files,
        itemLabelSingular: itemLabelSingular,
        itemLabelPlural: itemLabelPlural,
      );
    } on PlatformException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        '$failureContext failed: ${error.message ?? error.code}',
      );
    } on FileSystemException catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        error.message.isEmpty
            ? '$failureContext failed'
            : '$failureContext failed: ${error.message}',
      );
    } on SftpError catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Remote upload failed: ${error.message}');
    } on Object catch (error) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('$failureContext failed: $error');
    }
  }

  Future<T> _withClipboardSftp<T>(
    Future<T> Function(SftpClient sftp, RemoteFileService remoteFileService)
    action,
  ) async {
    final session = _activeSession();
    if (session == null) {
      throw StateError('Connection is not ready yet');
    }

    final remoteFileService = ref.read(remoteFileServiceProvider);
    final sftp = await session.sftp();
    try {
      await remoteFileService.ensureDirectoryExists(
        sftp,
        remoteClipboardUploadDirectory,
      );
      return await action(sftp, remoteFileService);
    } finally {
      sftp.close();
    }
  }

  Future<({String name, Uint8List bytes})> _readAndroidClipboardContentUri(
    String uri,
  ) async {
    final response = await _clipboardContentChannel.invokeMethod<Object>(
      'readContentUri',
      {'uri': uri},
    );
    if (response is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Unexpected clipboard content response',
      );
    }

    final name = response['name'];
    final bytes = response['bytes'];
    if (name is! String || bytes is! Uint8List) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Clipboard content response was incomplete',
      );
    }

    return (name: name, bytes: bytes);
  }

  Future<bool> _confirmClipboardUpload({
    required String title,
    required String message,
    required String confirmLabel,
    List<String> details = const [],
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final detail in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('\u2022 $detail'),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _pasteClipboardFiles(List<String> clipboardFiles) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard files?',
      message:
          'This will upload ${clipboardFiles.length} clipboard file${clipboardFiles.length == 1 ? '' : 's'} to $remoteClipboardUploadDirectory on the connected host and paste their remote paths into the terminal.',
      confirmLabel: 'Upload and paste',
      details: [
        for (var index = 0; index < clipboardFiles.length; index++)
          clipboardFiles[index].startsWith('content://')
              ? 'Clipboard file ${index + 1}'
              : path.basename(clipboardFiles[index]),
      ],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final timestamp = DateTime.now();
    final remotePaths = await _withClipboardSftp((
      sftp,
      remoteFileService,
    ) async {
      final remotePaths = <String>[];
      for (var index = 0; index < clipboardFiles.length; index++) {
        final localPath = clipboardFiles[index];
        final isContentUri = localPath.startsWith('content://');
        late final String sourceName;
        late final String remotePath;

        if (isContentUri) {
          if (!_isAndroidPlatform) {
            throw const FileSystemException(
              'Clipboard file URIs are not supported on this platform yet',
            );
          }
          final clipboardFile = await _readAndroidClipboardContentUri(
            localPath,
          );
          sourceName = clipboardFile.name;
          remotePath = joinRemotePath(
            remoteClipboardUploadDirectory,
            buildClipboardUploadFileName(
              sourceName,
              timestamp,
              sequence: index,
            ),
          );
          await remoteFileService.uploadBytes(
            sftp: sftp,
            remotePath: remotePath,
            bytes: clipboardFile.bytes,
          );
        } else {
          sourceName = path.basename(localPath);
          remotePath = joinRemotePath(
            remoteClipboardUploadDirectory,
            buildClipboardUploadFileName(
              sourceName,
              timestamp,
              sequence: index,
            ),
          );
          await remoteFileService.uploadStream(
            sftp: sftp,
            remotePath: remotePath,
            stream: File(localPath).openRead(),
          );
        }
        remotePaths.add(remotePath);
      }
      return remotePaths;
    });

    _followLiveOutput();
    _terminal.paste('${buildTerminalUploadInsertion(remotePaths)} ');
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage(
      'Uploaded ${remotePaths.length} file${remotePaths.length == 1 ? '' : 's'} to $remoteClipboardUploadDirectory',
    );
  }

  Future<void> _pasteClipboardImage(Uint8List imageBytes) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard image?',
      message:
          'This will upload the clipboard image to $remoteClipboardUploadDirectory on the connected host and paste its remote path into the terminal.',
      confirmLabel: 'Upload and paste',
      details: const ['image.png'],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final remotePath = await _withClipboardSftp((
      sftp,
      remoteFileService,
    ) async {
      final remotePath = joinRemotePath(
        remoteClipboardUploadDirectory,
        buildClipboardImageFileName(DateTime.now()),
      );
      await remoteFileService.uploadBytes(
        sftp: sftp,
        remotePath: remotePath,
        bytes: imageBytes,
      );
      return remotePath;
    });
    _followLiveOutput();
    _terminal.paste('${shellEscapePosix(remotePath)} ');
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage('Uploaded clipboard image to $remotePath');
  }

  Future<void> _pasteSelectedFiles(
    List<PlatformFile> selectedFiles, {
    required String itemLabelSingular,
    required String itemLabelPlural,
  }) async {
    final itemLabel = selectedFiles.length == 1
        ? itemLabelSingular
        : itemLabelPlural;
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload selected $itemLabel?',
      message:
          'This will upload ${selectedFiles.length == 1 ? 'the selected $itemLabelSingular' : '${selectedFiles.length} selected $itemLabelPlural'} to $remoteClipboardUploadDirectory on the connected host and paste ${selectedFiles.length == 1 ? 'its remote path' : 'their remote paths'} into the terminal.',
      confirmLabel: 'Upload and paste',
      details: [
        for (var index = 0; index < selectedFiles.length; index++)
          resolvePickedTerminalUploadFileName(
            selectedFiles[index],
            index: index,
          ),
      ],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final timestamp = DateTime.now();
    final remotePaths = await _withClipboardSftp((
      sftp,
      remoteFileService,
    ) async {
      final remotePaths = <String>[];
      for (var index = 0; index < selectedFiles.length; index++) {
        final file = selectedFiles[index];
        final sourceName = resolvePickedTerminalUploadFileName(
          file,
          index: index,
        );
        final remotePath = joinRemotePath(
          remoteClipboardUploadDirectory,
          buildClipboardUploadFileName(sourceName, timestamp, sequence: index),
        );
        final readStream = resolvePickedTerminalUploadReadStream(file);
        if (readStream != null) {
          await remoteFileService.uploadStream(
            sftp: sftp,
            remotePath: remotePath,
            stream: readStream,
          );
        } else {
          final bytes = file.bytes;
          if (bytes == null || bytes.isEmpty) {
            throw const FileSystemException('Unable to read selected file');
          }
          await remoteFileService.uploadBytes(
            sftp: sftp,
            remotePath: remotePath,
            bytes: bytes,
          );
        }
        remotePaths.add(remotePath);
      }
      return remotePaths;
    });

    _followLiveOutput();
    _terminal.paste('${buildTerminalUploadInsertion(remotePaths)} ');
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage(
      'Uploaded ${selectedFiles.length == 1 ? 'selected $itemLabelSingular' : '${remotePaths.length} $itemLabelPlural'} to $remoteClipboardUploadDirectory',
    );
  }

  Future<bool> _confirmKeyboardInsertion(TerminalCommandReview review) async {
    final shouldInsert = await _confirmCommandInsertion(
      title: 'Review keyboard paste',
      message:
          'This text inserted from your keyboard could execute multiple or reshaped commands.',
      confirmLabel: 'Insert anyway',
      review: review,
    );
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    return shouldInsert;
  }

  Future<bool> _confirmDesktopInsertedText(String text) async {
    if (text.length <= 1) {
      return true;
    }

    return _confirmTerminalInsertionIfNeeded(
      insertedText: text,
      buildReview: (commandText) => assessClipboardPasteCommand(
        commandText,
        bracketedPasteModeEnabled: false,
      ),
      title: 'Review keyboard paste',
      messageBuilder: (_) =>
          'This text inserted from your keyboard could execute multiple or reshaped commands.',
      confirmLabel: 'Insert anyway',
    );
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
        await showModalBottomSheet<
          ({String command, bool hadVariableSubstitution, int snippetId})
        >(
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
                              command: command.command,
                              hadVariableSubstitution:
                                  command.hadVariableSubstitution,
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

    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    if (result != null && result.command.isNotEmpty) {
      final shouldInsert = await _confirmTerminalInsertionIfNeeded(
        insertedText: result.command,
        buildReview: (commandText) => assessSnippetCommandInsertion(
          commandText,
          hadVariableSubstitution: result.hadVariableSubstitution,
        ),
        title: 'Review snippet command',
        messageBuilder: (_) =>
            'Confirm the rendered command before inserting it.',
        confirmLabel: 'Insert command',
      );
      if (!shouldInsert) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }
      _followLiveOutput();
      // Insert the command into terminal
      _terminal.paste(result.command);
      // Track usage
      unawaited(snippetRepo.incrementUsage(result.snippetId));
    }
  }

  /// Shows dialog for variable substitution if snippet has variables.
  Future<({String command, bool hadVariableSubstitution})?>
  _substituteVariables(BuildContext context, Snippet snippet) async {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(snippet.command);
    final variables = matches.map((m) => m.group(1)!).toSet().toList();

    if (variables.isEmpty) {
      return (command: snippet.command, hadVariableSubstitution: false);
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

    return (command: command, hadVariableSubstitution: true);
  }

  Future<_AutoConnectReviewDecision> _reviewImportedAutoConnectCommand(
    TerminalCommandReview review,
  ) async {
    final decision = await showDialog<_AutoConnectReviewDecision>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review imported auto-connect command'),
        content: _buildCommandReviewContent(
          review: review,
          message:
              'Imported auto-connect commands never run silently. Review this one before letting it execute.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.skip),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.runOnce),
            child: const Text('Run once'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.trustAndRun),
            child: const Text('Always run'),
          ),
        ],
      ),
    );
    return decision ?? _AutoConnectReviewDecision.skip;
  }

  Future<bool> _confirmCommandInsertion({
    required String title,
    required String message,
    required String confirmLabel,
    required TerminalCommandReview review,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: _buildCommandReviewContent(review: review, message: message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Widget _buildCommandReviewContent({
    required TerminalCommandReview review,
    required String message,
  }) {
    final reasons = describeTerminalCommandReview(review);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber_rounded, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(reason)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              review.command,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalStatusChip extends StatelessWidget {
  const _TerminalStatusChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.colorScheme,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
