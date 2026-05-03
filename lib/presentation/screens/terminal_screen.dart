import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../app/routes.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/clipboard_content_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/remote_clipboard_sync_service.dart';
import '../../domain/services/remote_file_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_exec_queue.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_hyperlink_tracker.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../../domain/services/terminal_wake_lock_service.dart';
import '../../domain/services/tmux_service.dart';
import '../controllers/terminal_session_controller.dart';
import '../widgets/agent_tool_icon.dart';
import '../widgets/ai_session_picker.dart';
import '../widgets/keyboard_toolbar.dart';
import '../widgets/monkey_terminal_view.dart';
import '../widgets/premium_access.dart';
import '../widgets/terminal_pinch_zoom_gesture_handler.dart';
import '../widgets/terminal_selection_text.dart' as terminal_selection_text;
import '../widgets/terminal_text_input_handler.dart';
import '../widgets/terminal_text_style.dart';
import '../widgets/terminal_theme_picker.dart';
import '../widgets/tmux_window_navigator.dart';
import '../widgets/tmux_window_status_badge.dart';
import 'sftp_screen.dart';

part '../widgets/tmux_expandable_bar.dart';

bool _isPromptReturnWhitespaceCodeUnit(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

const _redactStoreScreenshotIdentities = bool.fromEnvironment(
  'STORE_SCREENSHOT_REDACT_IDENTITIES',
);
const _hideStoreScreenshotKeyboardToolbar = bool.fromEnvironment(
  'STORE_SCREENSHOT_HIDE_KEYBOARD_TOOLBAR',
);

bool _isPromptReturnAsciiLetterOrDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

/// Minimum tmux handle touch target used by the collapsed window bar.
@visibleForTesting
const double tmuxHandleMinTouchExtent = 44;

/// Returns a short, user-facing label for the terminal connection state.
@visibleForTesting
String describeTerminalConnectionState(
  SshConnectionState state, {
  required bool isConnecting,
}) {
  if (isConnecting &&
      (state == SshConnectionState.disconnected ||
          state == SshConnectionState.connecting)) {
    return 'Connecting';
  }

  switch (state) {
    case SshConnectionState.connected:
      return 'Connected';
    case SshConnectionState.connecting:
      return 'Connecting';
    case SshConnectionState.authenticating:
      return 'Authenticating';
    case SshConnectionState.reconnecting:
      return 'Reconnecting';
    case SshConnectionState.error:
      return 'Connection error';
    case SshConnectionState.disconnected:
      return 'Disconnected';
  }
}

/// Formats the remote host and session identity shown in the terminal title.
@visibleForTesting
String? formatTerminalConnectionIdentity({
  required String? username,
  required String? hostname,
  required int? port,
  required int? connectionId,
}) {
  final trimmedUsername = username?.trim();
  final trimmedHostname = hostname?.trim();
  final hasUsername = trimmedUsername != null && trimmedUsername.isNotEmpty;
  final hasHostname = trimmedHostname != null && trimmedHostname.isNotEmpty;
  final hostIdentity = hasHostname
      ? '${hasUsername ? '$trimmedUsername@' : ''}$trimmedHostname'
      : null;
  final hostWithPort = hostIdentity == null
      ? null
      : port == null || port == 22
      ? hostIdentity
      : '$hostIdentity:$port';
  final sessionLabel = connectionId == null ? null : 'session #$connectionId';

  if (hostWithPort == null) {
    return sessionLabel;
  }
  if (sessionLabel == null) {
    return hostWithPort;
  }
  return '$hostWithPort · $sessionLabel';
}

/// Resolves the user-visible text for a tmux alert notification.
@visibleForTesting
({String title, String body}) resolveTmuxAlertNotificationContent({
  required String tmuxSessionName,
  required TmuxWindow window,
  required Iterable<TmuxWindow> windows,
}) {
  final sessionName = _tmuxAlertNotificationLabel(tmuxSessionName);
  final title = sessionName.isEmpty
      ? 'tmux alert'
      : 'tmux alert · $sessionName';
  final windowTitle = _tmuxAlertNotificationLabel(window.displayTitle);
  if (windowTitle.isEmpty) {
    return (title: title, body: 'Window #${window.index} needs attention');
  }

  final normalizedWindowTitle = windowTitle.toLowerCase();
  var matchingTitleCount = 0;
  for (final candidate in windows) {
    final candidateTitle = _tmuxAlertNotificationLabel(
      candidate.displayTitle,
    ).toLowerCase();
    if (candidateTitle != normalizedWindowTitle) {
      continue;
    }
    matchingTitleCount += 1;
    if (matchingTitleCount > 1) {
      return (title: title, body: '$windowTitle (window #${window.index})');
    }
  }

  return (title: title, body: windowTitle);
}

String _tmuxAlertNotificationLabel(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Resolves how much vertical space the tmux bar can safely expand into.
@visibleForTesting
double resolveTmuxBarMaxContentHeight(
  double availableHeight, {
  double handleHeight = tmuxHandleMinTouchExtent,
  double reservedPadding = 8,
  double fallbackAvailableHeight = 0,
}) {
  const maxHeightFactor = 0.68;
  const maxHeightCap = 400.0;
  final minimumExpandableHeight = handleHeight + reservedPadding;
  final effectiveAvailableHeight = availableHeight > minimumExpandableHeight
      ? availableHeight
      : fallbackAvailableHeight;
  final rawHeight = max(
    0,
    effectiveAvailableHeight - handleHeight - reservedPadding,
  ).toDouble();
  return min(
    rawHeight,
    min(effectiveAvailableHeight * maxHeightFactor, maxHeightCap),
  );
}

const _tmuxBarRevealDuration = Duration(milliseconds: 300);
const _tmuxDetectionRetrySchedule = <Duration>[
  Duration.zero,
  Duration(milliseconds: 150),
  Duration(milliseconds: 350),
  Duration(milliseconds: 700),
  Duration(milliseconds: 1400),
];

/// Resolves the retry schedule used for tmux detection after connect.
@visibleForTesting
List<Duration> resolveTmuxDetectionRetrySchedule({bool skipDelay = false}) =>
    skipDelay ? const <Duration>[Duration.zero] : _tmuxDetectionRetrySchedule;

/// Returns whether tmux detection should keep the terminal's current tmux UI.
///
/// A clean inactive result can clear the bar, but transient detection failures
/// should not hide a bar that was already visible or primed from host settings.
@visibleForTesting
bool shouldPreserveTerminalTmuxStateAfterDetectionFailure({
  required bool preserveExistingTmuxState,
  required bool hadVisibleOrPrimedTmuxState,
  required bool confirmedTmuxActive,
  required bool hadDetectionFailure,
}) {
  if (preserveExistingTmuxState || confirmedTmuxActive) {
    return true;
  }
  return hadVisibleOrPrimedTmuxState && hadDetectionFailure;
}

/// Returns whether detection should show the expected tmux UI before exec
/// probes complete.
@visibleForTesting
bool shouldPrimeTerminalTmuxStateWhileDetecting({
  required String? candidateSessionName,
  required bool hasExistingVisibleTmuxState,
  required bool mayPreserveExistingTmuxState,
  required bool isReopeningExistingTerminal,
}) =>
    candidateSessionName != null &&
    !hasExistingVisibleTmuxState &&
    !mayPreserveExistingTmuxState &&
    isReopeningExistingTerminal;

/// Chooses the tmux session name to verify during detection.
///
/// Prefer explicit route/host configuration, but keep verifying the existing
/// visible tmux session when no configured session name is available.
@visibleForTesting
String? resolveTmuxDetectionCandidateSessionName({
  String? preferredSessionName,
  String? existingSessionName,
}) {
  final preferred = preferredSessionName?.trim();
  if (preferred != null && preferred.isNotEmpty) {
    return preferred;
  }
  final existing = existingSessionName?.trim();
  if (existing != null && existing.isNotEmpty) {
    return existing;
  }
  return null;
}

/// Keeps an existing tmux session candidate scoped to the SSH connection that
/// created it.
@visibleForTesting
String? resolveOwnedTmuxDetectionExistingSessionName({
  required int sessionConnectionId,
  required int? tmuxStateConnectionId,
  String? existingSessionName,
}) {
  if (tmuxStateConnectionId != sessionConnectionId) {
    return null;
  }
  return resolveTmuxDetectionCandidateSessionName(
    existingSessionName: existingSessionName,
  );
}

/// Returns whether a tmux bar widget update should keep its last window list.
///
/// Recovery updates re-run subscriptions and queries after transient failures,
/// but should not throw away the last good snapshot for the same tmux session.
@visibleForTesting
bool shouldPreserveTmuxBarSnapshotOnUpdate({
  required bool sessionChanged,
  required bool recoveryChanged,
}) => recoveryChanged && !sessionChanged;

/// Resolves the working directory to use when creating a new tmux window.
@visibleForTesting
String? resolveTmuxWindowWorkingDirectory({
  String? explicitWorkingDirectory,
  String? currentPaneWorkingDirectory,
  String? observedWorkingDirectory,
  String? launchWorkingDirectory,
  String? hostWorkingDirectory,
}) {
  for (final candidate in <String?>[
    explicitWorkingDirectory,
    currentPaneWorkingDirectory,
    observedWorkingDirectory,
    launchWorkingDirectory,
    hostWorkingDirectory,
  ]) {
    final trimmed = candidate?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

/// Returns whether a tmux window action should reattach the visible terminal.
@visibleForTesting
bool shouldReattachTmuxAfterWindowAction({
  required bool hasForegroundClient,
  required TerminalShellStatus? shellStatus,
}) {
  if (hasForegroundClient) {
    return false;
  }
  return shellStatus == TerminalShellStatus.prompt;
}

/// Returns whether shell-command review warnings should be shown for text
/// inserted into the active terminal context.
///
/// These warnings are most useful when input is likely targeting a shell
/// prompt. When a full-screen app owns the alternate buffer, or shell
/// integration reports that a command is still running, the input is more
/// likely to be consumed by that program than by the shell itself.
@visibleForTesting
bool shouldReviewTerminalCommandInsertion({
  required TerminalShellStatus? shellStatus,
  required bool isUsingAltBuffer,
}) {
  if (isUsingAltBuffer) {
    return false;
  }
  return shellStatus != TerminalShellStatus.runningCommand;
}

/// Resolves the safe-area insets the tmux bar should stay within.
@visibleForTesting
EdgeInsets resolveTmuxBarSafeInsets(MediaQueryData mediaQuery) {
  final horizontalInsets = resolveTerminalRenderPadding(mediaQuery);
  return EdgeInsets.only(
    left: horizontalInsets.left,
    right: horizontalInsets.right,
    bottom: mediaQuery.padding.bottom,
  );
}

/// Resolves the tmux bar's vertical offset from the animated bottom padding.
@visibleForTesting
double resolveTmuxBarRevealBottomOffset(
  double terminalBottomPadding, {
  double handleHeight = tmuxHandleMinTouchExtent,
}) => terminalBottomPadding - handleHeight;

/// Resolves the tmux bar's reveal opacity from the animated bottom padding.
@visibleForTesting
double resolveTmuxBarRevealOpacity(
  double terminalBottomPadding, {
  double handleHeight = tmuxHandleMinTouchExtent,
}) {
  if (handleHeight <= 0) {
    return terminalBottomPadding > 0 ? 1 : 0;
  }

  return (terminalBottomPadding / handleHeight).clamp(0.0, 1.0);
}

/// Resolves the active tmux window title to show in the collapsed bar handle.
@visibleForTesting
String? resolveTmuxBarActiveWindowTitle(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  final title = activeWindow?.handleTitle.trim();
  if (title == null || title.isEmpty) {
    return null;
  }
  return title;
}

/// Resolves the supported foreground agent running in the active tmux window.
@visibleForTesting
AgentLaunchTool? resolveTmuxBarActiveWindowTool(
  Iterable<TmuxWindow>? windows,
) => windows
    ?.where((window) => window.isActive)
    .firstOrNull
    ?.foregroundAgentTool;

/// Resolves the tmux windows the bar should display, including any local
/// optimistic selection while the tmux snapshot is still catching up.
@visibleForTesting
List<TmuxWindow>? resolveTmuxBarDisplayedWindows(
  Iterable<TmuxWindow>? windows, {
  int? pendingSelectedWindowIndex,
}) {
  final windowList = windows?.toList(growable: false);
  if (windowList == null || pendingSelectedWindowIndex == null) {
    return windowList;
  }
  if (!windowList.any((window) => window.index == pendingSelectedWindowIndex)) {
    return windowList;
  }

  var didChangeActiveWindow = false;
  final displayedWindows = <TmuxWindow>[];
  for (final window in windowList) {
    final shouldBeActive = window.index == pendingSelectedWindowIndex;
    if (window.isActive != shouldBeActive) {
      didChangeActiveWindow = true;
      displayedWindows.add(window.copyWith(isActive: shouldBeActive));
      continue;
    }
    displayedWindows.add(window);
  }
  return didChangeActiveWindow ? displayedWindows : windowList;
}

/// Resolves whether the tmux bar should keep or clear its optimistic selection
/// after tmux reports a new window list.
@visibleForTesting
int? resolveTmuxBarPendingSelectedWindowIndex(
  Iterable<TmuxWindow>? windows, {
  int? pendingSelectedWindowIndex,
}) {
  if (pendingSelectedWindowIndex == null || windows == null) {
    return pendingSelectedWindowIndex;
  }
  final windowList = windows.toList(growable: false);
  if (!windowList.any((window) => window.index == pendingSelectedWindowIndex)) {
    return null;
  }
  final activeWindow = windowList
      .where((window) => window.isActive)
      .firstOrNull;
  if (activeWindow?.index == pendingSelectedWindowIndex) {
    return null;
  }
  return pendingSelectedWindowIndex;
}

/// Resolves the compact label shown in the tmux bar handle.
@visibleForTesting
String resolveTmuxBarHandleLabel(
  String tmuxSessionName, {
  String? activeWindowTitle,
}) {
  final sessionName = tmuxSessionName.trim();
  final title = activeWindowTitle?.trim();
  if (title == null || title.isEmpty || title == sessionName) {
    return sessionName;
  }
  if (sessionName.isEmpty) {
    return title;
  }
  return '$sessionName · $title';
}

final _oscEscapeSequencePattern = RegExp(
  '\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)',
  dotAll: true,
);
final _csiEscapeSequencePattern = RegExp('\x1B\\[[0-?]*[ -/]*[@-~]');
final _singleCharEscapeSequencePattern = RegExp('\x1B[@-_]');

String _stripTerminalPromptEscapeSequences(String text) => text
    .replaceAll(_oscEscapeSequencePattern, '')
    .replaceAll(_csiEscapeSequencePattern, '')
    .replaceAll(_singleCharEscapeSequencePattern, '');

const _minTerminalFontSize = 8.0;
const _maxTerminalFontSize = 32.0;
const _terminalFollowOutputTolerance = 1.0;
const _maxVerifiedTerminalPathCacheEntries = 128;
const _terminalPathTouchHorizontalPadding = 10.0;
const _terminalPathTouchVerticalPadding = 8.0;
const _terminalSelectionNearbySearchColumns = 4;
const _recentLocalClipboardProtection = Duration(seconds: 5);
const _maxTerminalFilePathVerificationCandidates = 12;
const _terminalFilePathVerificationExtensions = <String>[
  'properties',
  'gradle',
  'sqlite',
  'jpeg',
  'plist',
  'swift',
  'tar',
  'yaml',
  'dart',
  'html',
  'json',
  'lock',
  'scss',
  'toml',
  'tsx',
  'webp',
  'bash',
  'conf',
  'cpp',
  'css',
  'csv',
  'gif',
  'ini',
  'jpg',
  'log',
  'png',
  'sql',
  'svg',
  'txt',
  'xml',
  'yml',
  'zsh',
  'cc',
  'db',
  'go',
  'gz',
  'js',
  'kt',
  'md',
  'mm',
  'py',
  'rb',
  'rs',
  'sh',
  'ts',
  'c',
  'h',
  'm',
];

class _ExtraKeysToggleKeycap extends StatelessWidget {
  const _ExtraKeysToggleKeycap({required this.isActive, super.key});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor =
        IconTheme.of(context).color ?? theme.colorScheme.onSurface;

    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          width: 22,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive ? iconColor.withAlpha(56) : Colors.transparent,
            border: Border.all(
              color: isActive ? iconColor : iconColor.withAlpha(190),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Fn',
            style: theme.textTheme.labelSmall?.copyWith(
              color: iconColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

final _terminalFilePathVerificationExtensionSet =
    _terminalFilePathVerificationExtensions.toSet();
final _terminalLinkPattern = RegExp(
  r'''(?:(?:https?:\/\/)|(?:mailto:)|(?:tel:)|(?:www\.))[^\s<>"']+''',
  caseSensitive: false,
);
final _terminalFilePathPattern = RegExp(
  r'''(?:~(?:/[^\s<>"'$#&|;]+)?|/(?:[^\s<>"'$#&|;]+)|\.\.?/(?:[^\s<>"'$#&|;]+)|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)''',
);
final _terminalFilePathLineSuffixPattern = RegExp(
  r'''(?:~(?:/[^\s<>"'$#&|;]+)?/?|/(?:[^\s<>"'$#&|;]+)?|\.\.?/(?:[^\s<>"'$#&|;]+)?|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+/?)$''',
);
final _terminalFilePathStackTraceSuffixPattern = RegExp(
  r'(?:L\d+(?::\d+)?|:\d+(?::\d+)?)$',
);
final _terminalFilePathShellOperatorSuffixPattern = RegExp(
  r'(?:&&|\|\||[&;|])+$',
);
final _terminalWrappedCountSuffixPattern = RegExp(r'\d+$');
final _terminalStandalonePathMetadataPattern = RegExp(
  r'^(?:L\d+(?::\d+)?|:\d+(?::\d+)?)(?:\s|\(|$)',
);
const _terminalSftpPathPrefix = 'monkeyssh-sftp-path:';
const _terminalPathVerificationTimeout = Duration(seconds: 5);

typedef _TerminalPathMatch = ({
  String path,
  int start,
  int end,
  int hitTestEnd,
  int normalizedStart,
  int normalizedEnd,
});
typedef _NormalizedTerminalPathSnapshot = ({
  String text,
  List<int> originalToNormalizedOffsets,
  List<int> normalizedToOriginalStarts,
  List<int> normalizedToOriginalEnds,
});
typedef _TerminalPathTapSnapshot = ({
  String text,
  int startRow,
  List<int> rowStarts,
  List<List<int>> columnOffsets,
});
typedef _TerminalPathSnapshotAnalysis = ({
  List<_TerminalPathMatch> detectedPaths,
  _NormalizedTerminalPathSnapshot normalizedSnapshot,
});
typedef _VerifiedTerminalPath = ({String terminalPath, String resolvedPath});

enum _AutoConnectReviewDecision { skip, runOnce, trustAndRun }

/// Padding around the terminal viewport.
///
/// Keep the terminal flush with the viewport edges so status lines from tools
/// like tmux can use the full available width and height.
const terminalViewportPadding = EdgeInsets.zero;

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
    terminal_selection_text.trimTerminalLinePadding(line);

/// Trims per-line terminal padding from copied or overlaid terminal text.
@visibleForTesting
String trimTerminalSelectionText(String text) =>
    terminal_selection_text.trimTerminalSelectionText(text);

/// Keeps the Pro upsell snackbar tucked just above the visible bottom chrome.
///
/// Flutter's floating [SnackBar] already anchors itself above the keyboard
/// inset and the bottom safe area (see `Scaffold`'s snack bar layout, which
/// uses `min(contentBottom, size.height - viewPadding.bottom)`). The only
/// bottom chrome the scaffold does not know about is the in-body keyboard
/// toolbar that sits inside the body `Column`, so the margin only needs to
/// clear that toolbar with a small visual gap.
@visibleForTesting
double upgradeSnackBarBottomMargin(
  MediaQueryData mediaQuery, {
  bool showKeyboardToolbar = false,
  double keyboardToolbarHeight = 84,
  double baseSpacing = 16,
}) => (showKeyboardToolbar ? keyboardToolbarHeight : 0) + baseSpacing;

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

/// Resolves the picker request used for terminal uploads.
@visibleForTesting
({
  String dialogTitle,
  FileType pickerType,
  String itemLabelSingular,
  String itemLabelPlural,
  bool allowMultiple,
  String failureContext,
})
resolveTerminalUploadPickerRequest({required bool images}) => (
  dialogTitle: images ? 'Select images to upload' : 'Select files to upload',
  pickerType: images ? FileType.image : FileType.any,
  itemLabelSingular: images ? 'image' : 'file',
  itemLabelPlural: images ? 'images' : 'files',
  allowMultiple: true,
  failureContext: images ? 'Image picker upload' : 'File picker upload',
);

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

/// Trims terminal-rendered file paths before SFTP navigation.
@visibleForTesting
String trimTerminalFilePathCandidate(String text) {
  var candidate = trimTerminalLinkCandidate(text.trim());
  candidate = candidate.replaceFirst(
    _terminalFilePathStackTraceSuffixPattern,
    '',
  );
  candidate = candidate.replaceFirst(
    _terminalFilePathShellOperatorSuffixPattern,
    '',
  );
  candidate = _trimWrappedTerminalFilePathCountSuffix(candidate);
  return trimTerminalLinkCandidate(candidate);
}

String _trimWrappedTerminalFilePathCountSuffix(String text) {
  final match = _terminalWrappedCountSuffixPattern.firstMatch(text);
  if (match == null || match.start == 0) {
    return text;
  }

  final prefix = text.substring(0, match.start);
  if (!prefix.endsWith(')')) {
    return text;
  }

  final openParenCount = '('.allMatches(prefix).length;
  final closeParenCount = ')'.allMatches(prefix).length;
  if (closeParenCount <= openParenCount) {
    return text;
  }

  final trimmedPrefix = trimTerminalLinkCandidate(prefix);
  if (trimmedPrefix == prefix) {
    return text;
  }

  if (isSupportedTerminalFilePath(trimmedPrefix)) {
    return trimmedPrefix;
  }

  return text;
}

/// Whether a character can safely appear before a supported terminal path.
@visibleForTesting
bool isTerminalFilePathBoundary(String? character) =>
    character == null ||
    character.trim().isEmpty ||
    '([{"\'`=:,'.contains(character);

/// Whether a terminal path can be opened in the remote SFTP browser.
@visibleForTesting
bool isSupportedTerminalFilePath(String path) {
  if (path.isEmpty || path == '.' || path == '..' || path.startsWith('//')) {
    return false;
  }
  return isExplicitTerminalFilePath(path) ||
      isRelativeTerminalFilePathCandidate(path);
}

/// Whether a detected terminal path must be verified before becoming tappable.
@visibleForTesting
bool requiresTerminalFilePathVerification(String path) {
  if (isRelativeTerminalFilePathCandidate(path)) {
    return true;
  }

  if (hasAmbiguousTerminalFilePathParsing(path)) {
    return true;
  }

  if (!path.startsWith('/')) {
    return false;
  }

  final rootSegment = path.substring(1);
  return rootSegment.isNotEmpty &&
      !rootSegment.contains('/') &&
      !rootSegment.contains('.');
}

/// Whether a detected terminal path should currently behave like a link.
@visibleForTesting
bool shouldActivateTerminalFilePath(
  String path, {
  required bool hasVerifiedPath,
}) {
  if (requiresTerminalFilePathVerification(path)) {
    return hasVerifiedPath;
  }

  return isExplicitTerminalFilePath(path);
}

/// Whether a supported terminal path has multiple plausible parse boundaries.
@visibleForTesting
bool hasAmbiguousTerminalFilePathParsing(String path) {
  final lastSlashIndex = path.lastIndexOf('/');
  final basename = lastSlashIndex >= 0
      ? path.substring(lastSlashIndex + 1)
      : path;
  final lowercaseBasename = basename.toLowerCase();
  if (!lowercaseBasename.contains('.')) {
    return false;
  }

  final lastDotIndex = lowercaseBasename.lastIndexOf('.');
  if (lastDotIndex > 0 && lastDotIndex < lowercaseBasename.length - 1) {
    final extension = lowercaseBasename.substring(lastDotIndex + 1);
    if (_terminalFilePathVerificationExtensionSet.contains(extension)) {
      final marker = '.$extension';
      if (lowercaseBasename.indexOf(marker) == lastDotIndex &&
          lowercaseBasename.lastIndexOf(marker) == lastDotIndex) {
        return false;
      }
    }
  }

  return resolveTerminalFilePathVerificationCandidates(path).length > 1;
}

bool _isTerminalFilePathVerificationSuffixCharacter(String character) {
  if (character.isEmpty) {
    return false;
  }

  final codeUnit = character.codeUnitAt(0);
  return (codeUnit >= 48 && codeUnit <= 57) ||
      (codeUnit >= 65 && codeUnit <= 90) ||
      (codeUnit >= 97 && codeUnit <= 122) ||
      codeUnit == 45 ||
      codeUnit == 95;
}

bool _startsWithKnownTerminalFilePathExtensionAndMore(String suffix) {
  if (!suffix.startsWith('.')) {
    return false;
  }

  final lowercaseSuffix = suffix.toLowerCase();
  for (final extension in _terminalFilePathVerificationExtensions) {
    final extensionMarker = '.$extension';
    if (lowercaseSuffix.startsWith(extensionMarker) &&
        suffix.length > extensionMarker.length) {
      return true;
    }
  }
  return false;
}

bool _hasExcessClosingTerminalFilePathBrackets(String value) {
  var openParens = 0;
  var closeParens = 0;
  var openBrackets = 0;
  var closeBrackets = 0;
  var openBraces = 0;
  var closeBraces = 0;

  for (var index = 0; index < value.length; index++) {
    switch (value[index]) {
      case '(':
        openParens++;
        break;
      case ')':
        closeParens++;
        break;
      case '[':
        openBrackets++;
        break;
      case ']':
        closeBrackets++;
        break;
      case '{':
        openBraces++;
        break;
      case '}':
        closeBraces++;
        break;
      default:
        break;
    }
  }

  return closeParens > openParens ||
      closeBrackets > openBrackets ||
      closeBraces > openBraces;
}

/// Alternative terminal-path parses to check when a candidate looks ambiguous.
@visibleForTesting
List<String> resolveTerminalFilePathVerificationCandidates(String path) {
  final candidates = <String>[];
  final seen = <String>{};
  final seedCandidates = <String>[];

  void addCandidate(String candidate) {
    if (candidates.length >= _maxTerminalFilePathVerificationCandidates) {
      return;
    }
    final normalizedCandidate = trimTerminalFilePathCandidate(candidate);
    if (normalizedCandidate.isEmpty ||
        !isSupportedTerminalFilePath(normalizedCandidate) ||
        !seen.add(normalizedCandidate)) {
      return;
    }
    candidates.add(normalizedCandidate);
  }

  void addSeedCandidate(String candidate) {
    final beforeCount = candidates.length;
    addCandidate(candidate);
    if (candidates.length > beforeCount) {
      seedCandidates.add(candidates.last);
    }
  }

  addSeedCandidate(path);

  var trailingBracketCandidate = trimTerminalFilePathCandidate(path);
  if (_hasExcessClosingTerminalFilePathBrackets(trailingBracketCandidate)) {
    while (trailingBracketCandidate.isNotEmpty &&
        ')]}'.contains(
          trailingBracketCandidate[trailingBracketCandidate.length - 1],
        )) {
      trailingBracketCandidate = trailingBracketCandidate.substring(
        0,
        trailingBracketCandidate.length - 1,
      );
      addSeedCandidate(trailingBracketCandidate);
    }
  }

  for (final seed in seedCandidates) {
    final lastSlashIndex = seed.lastIndexOf('/');
    final basename = lastSlashIndex >= 0
        ? seed.substring(lastSlashIndex + 1)
        : seed;
    final basenamePrefix = lastSlashIndex >= 0
        ? seed.substring(0, lastSlashIndex + 1)
        : '';
    final lowercaseBasename = basename.toLowerCase();
    for (final extension in _terminalFilePathVerificationExtensions) {
      final extensionMarker = '.$extension';
      var markerIndex = lowercaseBasename.indexOf(extensionMarker);
      while (markerIndex >= 0) {
        final candidateEnd = markerIndex + extensionMarker.length;
        if (candidateEnd < basename.length) {
          final remainder = basename.substring(candidateEnd);
          if (_isTerminalFilePathVerificationSuffixCharacter(
                basename[candidateEnd],
              ) ||
              _startsWithKnownTerminalFilePathExtensionAndMore(remainder)) {
            addCandidate(
              '$basenamePrefix${basename.substring(0, candidateEnd)}',
            );
          }
        }
        markerIndex = lowercaseBasename.indexOf(
          extensionMarker,
          markerIndex + 1,
        );
      }
    }
  }

  if (candidates.length > 2) {
    final primaryCandidate = candidates.first;
    final alternativeCandidates = candidates.sublist(1)
      ..sort((left, right) => right.length.compareTo(left.length));
    return [primaryCandidate, ...alternativeCandidates];
  }

  return candidates;
}

/// Candidate terminal cells to probe for a touch-friendly path hit test.
@visibleForTesting
List<CellOffset> resolveForgivingTerminalTapOffsets(CellOffset offset) {
  final offsets = <CellOffset>[];
  final seen = <String>{};

  void addOffset(int dx, int dy) {
    final candidate = CellOffset(offset.x + dx, offset.y + dy);
    final key = '${candidate.x}:${candidate.y}';
    if (seen.add(key)) {
      offsets.add(candidate);
    }
  }

  addOffset(0, 0);
  for (var dx = 1; dx <= 4; dx++) {
    addOffset(-dx, 0);
    addOffset(dx, 0);
  }
  for (final dy in const [-1, 1]) {
    addOffset(0, dy);
    for (var dx = 1; dx <= 2; dx++) {
      addOffset(-dx, dy);
      addOffset(dx, dy);
    }
  }

  return offsets;
}

/// Visible terminal rows for the current scroll offset and rendered viewport.
@visibleForTesting
({int topRow, int bottomRow})? resolveVisibleTerminalRowRange({
  required double scrollOffset,
  required double lineHeight,
  required double viewportHeight,
  required int bufferHeight,
}) {
  if (lineHeight <= 0 || viewportHeight <= 0 || bufferHeight <= 0) {
    return null;
  }

  final maxRow = bufferHeight - 1;
  final topRow = (scrollOffset / lineHeight).floor().clamp(0, maxRow);
  final visibleRows = (viewportHeight / lineHeight).ceil().clamp(
    1,
    bufferHeight,
  );
  final bottomRow = (topRow + visibleRows - 1).clamp(0, maxRow);
  return (topRow: topRow, bottomRow: bottomRow);
}

/// Builds a terminal cell range for inline path underline painting.
@visibleForTesting
TerminalTextUnderline? resolveTerminalPathInlineUnderline({
  required int row,
  required int startColumn,
  required int endColumn,
  required int rowCount,
  required int columnCount,
}) {
  if (row < 0 || row >= rowCount || columnCount <= 0) {
    return null;
  }

  final normalizedStart = startColumn.clamp(0, columnCount - 1);
  final normalizedEnd = endColumn.clamp(0, columnCount - 1);
  if (normalizedStart > normalizedEnd) {
    return null;
  }
  return (row: row, startColumn: normalizedStart, endColumn: normalizedEnd);
}

/// Builds a forgiving touch target around a terminal path segment.
@visibleForTesting
Rect? resolveTerminalPathTouchTargetRect({
  required Offset lineTopLeft,
  required Offset lineEndOffset,
  required double lineHeight,
  required double viewportHeight,
  double horizontalPadding = _terminalPathTouchHorizontalPadding,
  double verticalPadding = _terminalPathTouchVerticalPadding,
}) {
  final width = lineEndOffset.dx - lineTopLeft.dx;
  if (width <= 0 || lineHeight <= 0 || viewportHeight <= 0) {
    return null;
  }

  final left = (lineTopLeft.dx - horizontalPadding).clamp(0.0, double.infinity);
  final top = (lineTopLeft.dy - verticalPadding).clamp(0.0, viewportHeight);
  final right = lineEndOffset.dx + horizontalPadding;
  final bottom = (lineTopLeft.dy + lineHeight + verticalPadding).clamp(
    top,
    viewportHeight,
  );
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Resolves which visible terminal path touch target, if any, a tap landed on.
@visibleForTesting
String? resolveTerminalPathTouchTargetTap(
  Offset localPosition,
  List<({String path, Rect touchRect})> targets,
) {
  for (final target in targets.reversed) {
    if (target.touchRect.contains(localPosition)) {
      return target.path;
    }
  }
  return null;
}

/// Whether a terminal path is anchored to `/` or `~`.
@visibleForTesting
bool isExplicitTerminalFilePath(String path) =>
    path.startsWith('/') || path == '~' || path.startsWith('~/');

/// Whether a relative terminal path looks file-like enough to probe safely.
@visibleForTesting
bool isRelativeTerminalFilePathCandidate(String path) {
  if (isExplicitTerminalFilePath(path) ||
      path.isEmpty ||
      path == '.' ||
      path == '..' ||
      path.startsWith('//') ||
      !path.contains('/')) {
    return false;
  }

  if (path.startsWith('./') || path.startsWith('../')) {
    return true;
  }

  final basename = path.split('/').last;
  return basename.contains('.');
}

bool _isTerminalFilePathBodyCharacter(String character) =>
    character.isNotEmpty &&
    !RegExp(r'''[\s<>"'$#]''').hasMatch(character) &&
    !_isTerminalPathContinuationDecorationCharacter(character);

bool _isTerminalPathContinuationDecorationCharacter(String character) =>
    character == ' ' ||
    character == '\t' ||
    '│┃║╎┆┊|├┤┬┴┼└┘┌┐╭╮╯╰─━═'.contains(character);

String _trimTerminalPathContinuationPrefix(String text) {
  var index = 0;
  while (index < text.length &&
      _isTerminalPathContinuationDecorationCharacter(text[index])) {
    index++;
  }
  return text.substring(index);
}

bool _startsFreshTerminalFilePathLine(String text) =>
    text == '~' ||
    text.startsWith('~/') ||
    text.startsWith('/') ||
    text.startsWith('./') ||
    text.startsWith('../');

String? _leadingTerminalFilePathCandidate(String text) {
  final match = _terminalFilePathPattern.matchAsPrefix(text);
  if (match == null) {
    return null;
  }

  final candidate = trimTerminalFilePathCandidate(match.group(0)!);
  return isSupportedTerminalFilePath(candidate) ? candidate : null;
}

bool _hasMeaningfulTextBeforeTrailingTerminalPath(
  String text,
  Match trailingPathMatch,
) => _trimTerminalPathContinuationPrefix(
  text.substring(0, trailingPathMatch.start),
).trim().isNotEmpty;

bool _endsWithTerminalPathContinuationBoundary(String path) =>
    path == '~' || path.endsWith('/');

bool _hasLeadingTerminalPathFragment(String text) =>
    text.isNotEmpty && _isTerminalFilePathBodyCharacter(text[0]);

bool _looksLikeTerminalPathContinuationAcrossRenderedLines({
  required String previousText,
  required String nextText,
}) {
  final trimmedPreviousText = trimTerminalLinePadding(previousText);
  final trimmedNextText = trimTerminalLinePadding(nextText);
  if (trimmedPreviousText.isEmpty || trimmedNextText.isEmpty) {
    return false;
  }
  if (_terminalStandalonePathMetadataPattern.hasMatch(trimmedNextText)) {
    return false;
  }

  final previousPathMatch = _terminalFilePathLineSuffixPattern.firstMatch(
    trimmedPreviousText,
  );
  if (previousPathMatch == null) {
    return false;
  }

  final previousPath = trimTerminalFilePathCandidate(
    previousPathMatch.group(0)!,
  );
  final previousHasLeadingContext =
      _hasMeaningfulTextBeforeTrailingTerminalPath(
        trimmedPreviousText,
        previousPathMatch,
      );
  final previousEndsWithBoundary = _endsWithTerminalPathContinuationBoundary(
    previousPath,
  );
  final nextLeadingPath = _leadingTerminalFilePathCandidate(trimmedNextText);

  if (_startsFreshTerminalFilePathLine(trimmedNextText)) {
    return previousHasLeadingContext || previousEndsWithBoundary;
  }

  if (nextLeadingPath != null && !isExplicitTerminalFilePath(nextLeadingPath)) {
    if (!previousHasLeadingContext &&
        !previousEndsWithBoundary &&
        !isExplicitTerminalFilePath(previousPath)) {
      return false;
    }
    return true;
  }

  return _hasLeadingTerminalPathFragment(trimmedNextText);
}

/// Whether adjacent rendered lines should be treated as one file-path span.
@visibleForTesting
bool isTerminalPathContinuationAcrossLines({
  required String previousLineText,
  required String nextLineText,
}) => _looksLikeTerminalPathContinuationAcrossRenderedLines(
  previousText: previousLineText,
  nextText: _trimTerminalPathContinuationPrefix(nextLineText),
);

/// Whether a terminal buffer row may contain path-like content.
///
/// Performs a quick scan of raw codepoints to filter rows that are unlikely
/// to contain file paths, avoiding the more expensive snapshot-building work.
/// Returns `true` if any column contains `/` (0x2F) or `~` (0x7E), both of
/// which are necessary for any detectable absolute, home-relative, or
/// relative path.
///
/// Only intended as a fast pre-filter; rows that return `true` are not
/// guaranteed to actually contain a valid path.
@visibleForTesting
bool terminalRowMayContainPath(BufferLine line, int viewWidth) {
  for (var col = 0; col < viewWidth; col++) {
    final cp = line.getCodePoint(col);
    if (cp == 0x2f /* '/' */ || cp == 0x7e /* '~' */ ) return true;
  }
  return false;
}

_NormalizedTerminalPathSnapshot _normalizeTerminalFilePathDetectionText(
  String text,
) {
  final normalizedCharacters = <String>[];
  final originalToNormalizedOffsets = List<int>.filled(text.length + 1, 0);
  final normalizedToOriginalStarts = <int>[];
  final normalizedToOriginalEnds = <int>[];
  var index = 0;
  var lineStart = 0;

  while (index < text.length) {
    final character = text[index];
    if (character == '\r' || character == '\n') {
      var lineBreakEnd = index + 1;
      if (character == '\r' &&
          lineBreakEnd < text.length &&
          text[lineBreakEnd] == '\n') {
        lineBreakEnd++;
      }

      var continuationEnd = lineBreakEnd;
      while (continuationEnd < text.length &&
          _isTerminalPathContinuationDecorationCharacter(
            text[continuationEnd],
          )) {
        continuationEnd++;
      }

      var nextLineEnd = continuationEnd;
      while (nextLineEnd < text.length &&
          text[nextLineEnd] != '\r' &&
          text[nextLineEnd] != '\n') {
        nextLineEnd++;
      }

      final isPathContinuation =
          continuationEnd < text.length &&
          _looksLikeTerminalPathContinuationAcrossRenderedLines(
            previousText: text.substring(lineStart, index),
            nextText: text.substring(continuationEnd, nextLineEnd),
          );
      if (isPathContinuation) {
        for (
          var skippedIndex = index;
          skippedIndex < continuationEnd;
          skippedIndex++
        ) {
          originalToNormalizedOffsets[skippedIndex] =
              normalizedCharacters.length;
        }
        lineStart = lineBreakEnd;
        index = continuationEnd;
        continue;
      }

      final normalizedIndex = normalizedCharacters.length;
      for (var sourceIndex = index; sourceIndex < lineBreakEnd; sourceIndex++) {
        originalToNormalizedOffsets[sourceIndex] = normalizedIndex;
      }
      normalizedCharacters.add('\n');
      normalizedToOriginalStarts.add(index);
      normalizedToOriginalEnds.add(lineBreakEnd);
      lineStart = lineBreakEnd;
      index = lineBreakEnd;
      continue;
    }

    final normalizedIndex = normalizedCharacters.length;
    originalToNormalizedOffsets[index] = normalizedIndex;
    normalizedCharacters.add(character);
    normalizedToOriginalStarts.add(index);
    normalizedToOriginalEnds.add(index + 1);
    index++;
  }

  originalToNormalizedOffsets[text.length] = normalizedCharacters.length;
  return (
    text: normalizedCharacters.join(),
    originalToNormalizedOffsets: originalToNormalizedOffsets,
    normalizedToOriginalStarts: normalizedToOriginalStarts,
    normalizedToOriginalEnds: normalizedToOriginalEnds,
  );
}

List<_TerminalPathMatch> _detectTerminalFilePathMatches(String text) {
  final normalizedText = _normalizeTerminalFilePathDetectionText(text);
  final detectedPaths = <_TerminalPathMatch>[];

  for (final match in _terminalFilePathPattern.allMatches(
    normalizedText.text,
  )) {
    final previousCharacter = match.start == 0
        ? null
        : normalizedText.text.substring(match.start - 1, match.start);
    if (!isTerminalFilePathBoundary(previousCharacter)) {
      continue;
    }

    final candidate = trimTerminalFilePathCandidate(match.group(0)!);
    if (!isSupportedTerminalFilePath(candidate)) {
      continue;
    }

    final visualEnd = match.start + candidate.length;
    final originalStart =
        normalizedText.normalizedToOriginalStarts[match.start];
    final originalEnd = normalizedText.normalizedToOriginalEnds[visualEnd - 1];
    final originalHitTestEnd =
        normalizedText.normalizedToOriginalEnds[match.end - 1];
    detectedPaths.add((
      path: candidate,
      start: originalStart,
      end: originalEnd,
      hitTestEnd: originalHitTestEnd,
      normalizedStart: match.start,
      normalizedEnd: visualEnd,
    ));
  }

  return detectedPaths;
}

/// Resolves the visible row segment for the first matching path on a row.
@visibleForTesting
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRowForPath({
  required String snapshotText,
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required String path,
}) {
  final normalizedSnapshot = _normalizeTerminalFilePathDetectionText(
    snapshotText,
  );
  for (final match in _detectTerminalFilePathMatches(snapshotText)) {
    if (match.path != path) {
      continue;
    }
    final segment = resolveTerminalFilePathSegmentOnRow(
      rowText: rowText,
      rowStartOffset: rowStartOffset,
      rowColumnOffsets: rowColumnOffsets,
      originalToNormalizedOffsets:
          normalizedSnapshot.originalToNormalizedOffsets,
      normalizedPathStart: match.normalizedStart,
      normalizedPathEnd: match.normalizedEnd,
    );
    if (segment != null) {
      return segment;
    }
  }
  return null;
}

/// Resolves the visible path-only segment for a specific rendered row.
@visibleForTesting
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRow({
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required List<int> originalToNormalizedOffsets,
  required int normalizedPathStart,
  required int normalizedPathEnd,
}) {
  if (rowText.isEmpty || rowColumnOffsets.length < 2) {
    return null;
  }

  int? startColumn;
  int? endColumn;
  for (var column = 0; column < rowColumnOffsets.length - 1; column++) {
    final textStart = rowColumnOffsets[column];
    if (textStart < 0 || textStart >= rowText.length) {
      if (startColumn != null) {
        break;
      }
      continue;
    }
    final textEnd = rowColumnOffsets[column + 1].clamp(
      textStart + 1,
      rowText.length,
    );
    final character = rowText.substring(textStart, textEnd);
    if (!_isTerminalFilePathBodyCharacter(character)) {
      if (startColumn != null) {
        break;
      }
      continue;
    }

    final normalizedOffset =
        originalToNormalizedOffsets[rowStartOffset + textStart];
    if (normalizedOffset < normalizedPathStart ||
        normalizedOffset >= normalizedPathEnd) {
      if (startColumn != null) {
        break;
      }
      continue;
    }
    startColumn ??= column;
    endColumn = column;
  }

  if (startColumn == null || endColumn == null) {
    return null;
  }

  final segmentStart = rowColumnOffsets[startColumn];
  final segmentEnd = rowColumnOffsets[endColumn + 1].clamp(
    segmentStart + 1,
    rowText.length,
  );
  return (
    text: rowText.substring(segmentStart, segmentEnd),
    startColumn: startColumn,
    endColumn: endColumn,
  );
}

/// Resolves all tappable terminal file paths within the given text.
@visibleForTesting
List<({String path, int start, int end})> detectTerminalFilePaths(
  String text,
) => [
  for (final path in _detectTerminalFilePathMatches(text))
    (path: path.path, start: path.start, end: path.end),
];

/// Resolves a tappable terminal file path at the given text offset, if present.
@visibleForTesting
({String path, int start, int end})? detectTerminalFilePathAtTextOffset(
  String text,
  int offset,
) {
  final clampedOffset = offset.clamp(0, text.length);
  for (final detectedPath in _detectTerminalFilePathMatches(text)) {
    if (clampedOffset >= detectedPath.start &&
        clampedOffset < detectedPath.hitTestEnd) {
      return (
        path: detectedPath.path,
        start: detectedPath.start,
        end: detectedPath.end,
      );
    }
  }

  return null;
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

/// Chooses the platform keyboard appearance that best matches a terminal theme.
@visibleForTesting
Brightness resolveTerminalKeyboardAppearance(TerminalThemeData theme) =>
    theme.isDark ? Brightness.dark : Brightness.light;

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
}) => isNativeSelectionMode;

/// Whether the native overlay currently holds an expanded text selection.
@visibleForTesting
bool hasActiveNativeOverlaySelection(TextSelection selection) =>
    selection.isValid && !selection.isCollapsed;

/// Resolves the terminal range to select for a touch long-press.
///
/// xterm's word selection returns null on separators and blank cells. Mobile
/// touch selection should still start when the finger lands on punctuation in a
/// path/URL or slightly misses a word, so this falls back to separator runs and
/// nearby selectable cells on the same row.
@visibleForTesting
BufferRange? resolveNativeTouchSelectionRange({
  required Buffer buffer,
  required CellOffset cellOffset,
  int nearbySearchColumns = _terminalSelectionNearbySearchColumns,
}) {
  if (buffer.height <= 0 || buffer.viewWidth <= 0) {
    return null;
  }

  final row = cellOffset.y.clamp(0, buffer.height - 1);
  final column = cellOffset.x.clamp(0, buffer.viewWidth - 1);
  final exactOffset = CellOffset(column, row);
  final exactSeparatorRange = _resolveTerminalSeparatorSelectionRange(
    buffer: buffer,
    row: row,
    column: column,
  );
  if (exactSeparatorRange != null) {
    return exactSeparatorRange;
  }

  if (!_isTerminalSelectionBlank(buffer, row, column)) {
    final exactWordRange = buffer.getWordBoundary(exactOffset);
    if (exactWordRange != null) {
      return exactWordRange;
    }
  }

  final searchLimit = nearbySearchColumns.clamp(0, buffer.viewWidth);
  for (var distance = 1; distance <= searchLimit; distance++) {
    final leftColumn = column - distance;
    if (leftColumn >= 0) {
      final leftRange = _resolveNativeTouchSelectionRangeAtColumn(
        buffer: buffer,
        row: row,
        column: leftColumn,
      );
      if (leftRange != null) {
        return leftRange;
      }
    }

    final rightColumn = column + distance;
    if (rightColumn < buffer.viewWidth) {
      final rightRange = _resolveNativeTouchSelectionRangeAtColumn(
        buffer: buffer,
        row: row,
        column: rightColumn,
      );
      if (rightRange != null) {
        return rightRange;
      }
    }
  }

  return null;
}

BufferRange? _resolveNativeTouchSelectionRangeAtColumn({
  required Buffer buffer,
  required int row,
  required int column,
}) {
  final separatorRange = _resolveTerminalSeparatorSelectionRange(
    buffer: buffer,
    row: row,
    column: column,
  );
  if (separatorRange != null) {
    return separatorRange;
  }
  if (_isTerminalSelectionBlank(buffer, row, column)) {
    return null;
  }
  final offset = CellOffset(column, row);
  return buffer.getWordBoundary(offset);
}

BufferRangeLine? _resolveTerminalSeparatorSelectionRange({
  required Buffer buffer,
  required int row,
  required int column,
}) {
  if (!_isTerminalSelectableSeparator(buffer, row, column)) {
    return null;
  }

  var start = column;
  while (start > 0 && _isTerminalSelectableSeparator(buffer, row, start - 1)) {
    start--;
  }

  var end = column + 1;
  while (end < buffer.viewWidth &&
      _isTerminalSelectableSeparator(buffer, row, end)) {
    end++;
  }

  return BufferRangeLine(CellOffset(start, row), CellOffset(end, row));
}

bool _isTerminalSelectableSeparator(Buffer buffer, int row, int column) {
  if (_isTerminalSelectionBlank(buffer, row, column)) {
    return false;
  }
  final separators = buffer.wordSeparators ?? Buffer.defaultWordSeparators;
  return separators.contains(buffer.lines[row].getCodePoint(column));
}

bool _isTerminalSelectionBlank(Buffer buffer, int row, int column) {
  final codePoint = buffer.lines[row].getCodePoint(column);
  return codePoint == 0 || codePoint == 0x20 || codePoint == 0x09;
}

/// Builds native selection context menu items with paste routed to the terminal.
@visibleForTesting
List<ContextMenuButtonItem> buildNativeSelectionContextMenuButtonItems({
  required List<ContextMenuButtonItem> defaultItems,
  required VoidCallback onPaste,
}) {
  final buttonItems = <ContextMenuButtonItem>[];
  for (final item in defaultItems) {
    switch (item.type) {
      case ContextMenuButtonType.cut:
      case ContextMenuButtonType.delete:
      case ContextMenuButtonType.selectAll:
        // These actions do not have a meaningful terminal selection behavior.
        continue;
      case ContextMenuButtonType.paste:
        // Replaced below with terminal-aware paste.
        continue;
      default:
        buttonItems.add(item);
    }
  }
  buttonItems.add(
    ContextMenuButtonItem(
      type: ContextMenuButtonType.paste,
      onPressed: onPaste,
    ),
  );
  return buttonItems;
}

/// Builds a menu callback that lets the action read selection before hiding.
@visibleForTesting
VoidCallback buildTerminalSelectionContextMenuAction({
  required VoidCallback action,
  required VoidCallback hideToolbar,
}) => () {
  try {
    action();
  } finally {
    hideToolbar();
  }
};

/// Whether a polled remote clipboard value should replace the local clipboard.
@visibleForTesting
bool shouldApplyRemoteClipboardTextToLocal({
  required String? remoteText,
  required String? lastObservedRemoteText,
  required String? lastObservedLocalText,
  required String? lastAppliedRemoteText,
  required String? recentLocalClipboardText,
  required DateTime? recentLocalClipboardAt,
  required DateTime now,
  Duration recentLocalClipboardProtection = _recentLocalClipboardProtection,
}) {
  if (remoteText == null || remoteText.isEmpty) {
    return false;
  }
  if (remoteText == lastObservedRemoteText ||
      remoteText == lastObservedLocalText ||
      remoteText == lastAppliedRemoteText) {
    return false;
  }
  if (recentLocalClipboardText != null && recentLocalClipboardAt != null) {
    final isProtectedRecentLocalWrite =
        now.difference(recentLocalClipboardAt) < recentLocalClipboardProtection;
    if (remoteText == recentLocalClipboardText || isProtectedRecentLocalWrite) {
      return false;
    }
  }
  return true;
}

/// Whether terminal tap links should be resolved for the current overlay state.
@visibleForTesting
bool shouldResolveTerminalTapLinks({
  required bool showsNativeSelectionOverlay,
}) => !showsNativeSelectionOverlay;

typedef _NativeSelectionSnapshotData = ({
  String text,
  List<int> lineStarts,
  List<List<int>> columnOffsets,
  int lineCount,
  int viewWidth,
  int textLength,
});

typedef _PendingTouchSelectionSnapshot = ({
  CellOffset originCellOffset,
  String text,
  TextSelection selection,
  List<int> lineStarts,
  List<List<int>> columnOffsets,
  int lineCount,
  int viewWidth,
  int textLength,
  bool revealOverlayInTouchScrollMode,
});

/// How a native selection change should update the mobile overlay state.
@visibleForTesting
enum NativeSelectionOverlayChange {
  /// Leaves the current overlay and selection mode state unchanged.
  none,

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
  const TerminalScreen({
    required this.hostId,
    this.connectionId,
    this.initialTmuxSessionName,
    this.initialTmuxWindowIndex,
    this.initialTmuxWindowId,
    this.initialTmuxWindowRequiresVisibleSession = false,
    this.initiallyExpandTmuxWindows = false,
    super.key,
  });

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

  /// Optional tmux session to focus after opening the terminal.
  final String? initialTmuxSessionName;

  /// Optional tmux window to focus after opening the terminal.
  final int? initialTmuxWindowIndex;

  /// Optional stable tmux window ID to focus after opening the terminal.
  final String? initialTmuxWindowId;

  /// Whether focusing the initial tmux window must also make tmux visible.
  final bool initialTmuxWindowRequiresVisibleSession;

  /// Whether the tmux window selector should start expanded.
  final bool initiallyExpandTmuxWindows;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _InitialTmuxWindowTarget {
  const _InitialTmuxWindowTarget({
    required this.sessionName,
    required this.windowIndex,
    required this.requiresVisibleSession,
    this.windowId,
  });

  final String sessionName;
  final int windowIndex;
  final String? windowId;
  final bool requiresVisibleSession;
}

class _TmuxTerminalThemeRefreshRequest {
  const _TmuxTerminalThemeRefreshRequest({
    required this.theme,
    required this.session,
    required this.sessionName,
    required this.refreshGeneration,
    required this.reason,
    required this.extraFlags,
  });

  final TerminalThemeData theme;
  final SshSession session;
  final String sessionName;
  final int refreshGeneration;
  final String reason;
  final String? extraFlags;
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  static const _localClipboardSyncInterval = Duration(milliseconds: 750);
  static const _remoteClipboardSyncInterval = Duration(seconds: 1);
  static const _promptOutputImeResetDebounce = Duration(milliseconds: 75);
  static const _tmuxForegroundVerificationInterval = Duration(seconds: 5);
  final _terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
  final _tmuxBarKey = GlobalKey<_TmuxExpandableBarState>();

  late Terminal _terminal;
  late final TerminalController _terminalController;
  late final ScrollController _terminalScrollController;
  late final ScrollController _nativeSelectionScrollController;
  late final TextEditingController _nativeSelectionController;
  late final FocusNode _nativeSelectionFocusNode;
  late FocusNode _terminalFocusNode;
  final _terminalTextInputController = TerminalTextInputHandlerController();
  final _toolbarController = KeyboardToolbarController();
  SSHSession? _shell;
  StreamSubscription<void>? _doneSubscription;
  StreamSubscription<String>? _shellStdoutSubscription;
  bool _isConnecting = true;
  String? _error;
  bool _showKeyboardToolbar = !_hideStoreScreenshotKeyboardToolbar;
  bool _isUsingAltBuffer = false;
  bool _terminalReportsMouseWheel = false;
  bool _isNativeSelectionMode = false;
  bool _revealsNativeSelectionOverlayInTouchScrollMode = false;
  bool _isSyncingNativeScroll = false;
  bool _hadNativeOverlaySelection = false;
  _NativeSelectionSnapshotData? _nativeSelectionSnapshotCache;
  Timer? _nativeOverlayCollapseTimer;
  int? _connectionId;
  double? _pinchFontSize;
  double? _lastPinchScale;
  double? _sessionFontSizeOverride;
  bool _isPinchZooming = false;
  bool _shouldFollowLiveOutput = true;
  double _lastTerminalScrollOffset = 0;
  bool _isTerminalScrollToBottomQueued = false;
  TerminalHyperlinkTracker? _terminalHyperlinkTracker;
  late final TerminalSessionController _sessionController;
  bool _showsTerminalMetadata = false;
  bool _isTmuxActive = false;
  String? _tmuxSessionName;
  int? _tmuxStateConnectionId;
  _InitialTmuxWindowTarget? _pendingInitialTmuxWindowTarget;
  bool _showTmuxBar = true;
  bool _isTmuxBarExpanded = false;
  String? _connectionOpenedWorkingDirectory;
  String? _tmuxLaunchWorkingDirectory;
  String? _tmuxWorkingDirectory;
  int _tmuxDetectionGeneration = 0;
  int _tmuxBarRecoveryGeneration = 0;
  int _tmuxForegroundVerificationGeneration = 0;
  Timer? _tmuxForegroundVerificationTimer;
  bool _tmuxForegroundVerificationInFlight = false;
  final Map<String, _VerifiedTerminalPath> _verifiedTerminalPathCache =
      <String, _VerifiedTerminalPath>{};
  final ListQueue<String> _verifiedTerminalPathCacheOrder = ListQueue<String>();
  final Set<String> _verifyingTerminalPathCacheKeys = <String>{};
  String? _terminalPathCacheScope;
  String? _pendingTerminalLinkTap;
  int? _pendingTerminalLinkTapPointer;
  Offset? _pendingTerminalLinkTapDownPosition;
  Duration? _pendingTerminalLinkTapDownTimestamp;
  String? _recentlyOpenedTerminalLinkTap;
  String? _pendingTerminalPathTap;
  int? _pendingTerminalPathTapPointer;
  Offset? _pendingTerminalPathTapDownPosition;
  Duration? _pendingTerminalPathTapDownTimestamp;
  String? _recentlyOpenedTerminalPathTap;
  int? _pendingTerminalDoubleTapPointer;
  Offset? _pendingTerminalDoubleTapDownPosition;
  Duration? _pendingTerminalDoubleTapDownTimestamp;
  int? _terminalDoubleTapConsumedPointer;
  Offset? _lastTerminalTapPosition;
  Duration? _lastTerminalTapTimestamp;
  int? _pendingTerminalMouseTapPointer;
  Offset? _pendingTerminalMouseTapDownPosition;
  Duration? _pendingTerminalMouseTapDownTimestamp;
  final Set<int> _terminalOutputPauseTouchPointers = <int>{};
  TerminalTextUnderline? _hoveredTerminalPathUnderline;
  List<({String path, TerminalTextUnderline underline, Rect touchRect})>
  _visibleTerminalPathUnderlines =
      const <
        ({String path, TerminalTextUnderline underline, Rect touchRect})
      >[];
  bool _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = true;
  bool? _lastShowsTerminalPathUnderlines;
  CellOffset? _lastHoveredTerminalPathOffset;
  String? _lastHoveredTerminalPath;
  bool _isTerminalPathUnderlineRefreshQueued = false;

  /// Monotonically-increasing counter; incremented whenever the terminal
  /// buffer changes content. Used to invalidate per-row snapshot caches.
  int _terminalContentGeneration = 0;

  /// Cache of [_TerminalPathTapSnapshot] objects keyed by the canonical start
  /// row of each wrapped-line group. Invalidated when
  /// [_terminalContentGeneration] changes.
  final Map<int, _TerminalPathTapSnapshot?> _terminalPathSnapshotCache = {};

  /// The terminal-content generation that [_terminalPathSnapshotCache] and
  /// [_terminalPathAnalysisCache] were last populated for.
  int _terminalPathSnapshotCacheGeneration = -1;

  /// Cache of [_TerminalPathSnapshotAnalysis] keyed by snapshot text. The
  /// regex-heavy analysis is deterministic on the snapshot text, so it can be
  /// shared across rows that produce the same text content. Cleared together
  /// with [_terminalPathSnapshotCache].
  final Map<String, _TerminalPathSnapshotAnalysis> _terminalPathAnalysisCache =
      {};

  SshSession? _terminalPathVerificationSession;
  Future<SftpClient?>? _terminalPathVerificationSftpFuture;
  SftpClient? _terminalPathVerificationSftp;
  String? _terminalPathVerificationHomeDirectory;
  late final ProviderSubscription<bool> _sharedClipboardSubscription;
  late final ProviderSubscription<bool> _sharedClipboardLocalReadSubscription;
  late final ProviderSubscription<bool> _terminalWakeLockSubscription;
  late final ProviderSubscription<TerminalThemeSettings>
  _terminalThemeSettingsSubscription;
  late final ProviderSubscription<ThemeMode> _themeModeSubscription;
  Timer? _localClipboardSyncTimer;
  Timer? _remoteClipboardSyncTimer;
  Timer? _promptOutputImeResetTimer;
  bool _isPollingRemoteClipboard = false;
  bool _isPushingLocalClipboard = false;
  bool _remoteClipboardUnsupported = false;
  String? _lastObservedLocalClipboardText;
  String? _lastObservedRemoteClipboardText;
  String? _lastAppliedLocalClipboardText;
  String? _lastAppliedRemoteClipboardText;
  String? _recentLocalClipboardText;
  DateTime? _recentLocalClipboardAt;
  bool _isTerminalSizeRefreshQueued = false;
  bool _terminalWakeLockSetting = false;

  // Theme state
  Host? _host;
  AgentLaunchPreset? _autoConnectAgentPreset;
  bool _startClisInYoloMode = false;
  TerminalThemeData? _currentTheme;
  TerminalThemeData? _sessionThemeOverride;
  final Object _terminalAppThemeOverrideOwner = Object();
  late final TerminalAppThemeOverrideNotifier _terminalAppThemeOverrideNotifier;
  Brightness? _lastThemeDependencyBrightness;
  int _terminalThemeRefreshGeneration = 0;
  final Set<Timer> _terminalThemeRefreshTimers = <Timer>{};
  bool _isTmuxThemeRefreshRunning = false;
  _TmuxTerminalThemeRefreshRequest? _pendingTmuxThemeRefreshRequest;
  bool _terminalThemeDependencyReloadQueued = false;
  bool _pendingTerminalThemeDependencyReload = false;
  bool _pendingTerminalThemeDependencyForceRemoteRefresh = false;
  String _pendingTerminalThemeDependencyReason = 'unknown';
  // Guards the build-path theme application so the same theme is not pushed
  // to the session on every rebuild.  Cleared at connect-time so the safety-
  // net call in build() still fires once for each new connection.
  TerminalThemeData? _lastBuildAppliedTheme;

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

  bool get _hasExpandedNativeOverlaySelection =>
      _isNativeSelectionMode &&
      hasActiveNativeOverlaySelection(_nativeSelectionController.selection);

  bool get _hasActiveSystemSelection {
    final selection = _terminalController.selection;
    return selection != null && !selection.isCollapsed;
  }

  bool get _isTerminalOutputFollowPaused =>
      _terminalOutputPauseTouchPointers.isNotEmpty ||
      _hasExpandedNativeOverlaySelection ||
      _hasActiveSystemSelection;

  bool get _terminalLiveOutputAutoScrollEnabled =>
      !_isTerminalOutputFollowPaused;

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

  SshSession? get _observedSession => _sessionController.observedSession;

  String? get _iconName => _observedSession?.iconName;

  Uri? get _workingDirectory => _observedSession?.workingDirectory;

  String? get _liveWorkingDirectoryPath =>
      resolveTerminalWorkingDirectoryPath(_workingDirectory);

  String? get _workingDirectoryLabel =>
      formatTerminalWorkingDirectoryLabel(_workingDirectory);

  String? get _workingDirectoryPath =>
      _liveWorkingDirectoryPath ?? _tmuxWorkingDirectory;

  TerminalShellStatus? get _shellStatus => _observedSession?.shellStatus;

  int? get _lastExitCode => _observedSession?.lastExitCode;

  bool get _shouldReviewTerminalCommandInsertion =>
      shouldReviewTerminalCommandInsertion(
        shellStatus: _shellStatus,
        isUsingAltBuffer: _isUsingAltBuffer,
      );

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
    DiagnosticsLogService.instance.info(
      'terminal.screen',
      'init',
      fields: {
        'hostId': widget.hostId,
        'hasConnectionId': widget.connectionId != null,
        'hasInitialTmuxSession': widget.initialTmuxSessionName != null,
        'hasInitialTmuxWindow': widget.initialTmuxWindowIndex != null,
      },
    );
    _pendingInitialTmuxWindowTarget = _buildInitialTmuxWindowTarget(widget);
    WidgetsBinding.instance.addObserver(this);
    _sharedClipboardSubscription = ref.listenManual<bool>(
      sharedClipboardNotifierProvider,
      (previous, next) => unawaited(
        _applySharedClipboardSetting(
          enabled: next,
          allowLocalClipboardRead:
              next && ref.read(sharedClipboardLocalReadNotifierProvider),
        ),
      ),
    );
    _sharedClipboardLocalReadSubscription = ref.listenManual<bool>(
      sharedClipboardLocalReadNotifierProvider,
      (previous, next) => unawaited(
        _applySharedClipboardSetting(
          enabled: ref.read(sharedClipboardNotifierProvider),
          allowLocalClipboardRead: next,
        ),
      ),
    );
    _terminalAppThemeOverrideNotifier = ref.read(
      terminalAppThemeOverrideProvider.notifier,
    );
    final terminalWakeLockService = ref.read(terminalWakeLockServiceProvider);
    _sessionController = TerminalSessionController(
      wakeLockService: terminalWakeLockService,
      wakeLockOwnerId: terminalWakeLockService.createOwner(),
      readCurrentConnectionState: _readCurrentConnectionState,
      getSession: (connectionId) => _sessionsNotifier?.getSession(connectionId),
      connectionId: () => _connectionId,
      hasActiveShell: () => _shell != null,
      hasError: () => _error != null,
      isBackgrounded: () => _wasBackgrounded,
      onSessionMetadataChanged: _handleSessionMetadataChanged,
    );
    _terminalWakeLockSetting = ref.read(terminalWakeLockNotifierProvider);
    _sessionController.wakeLockEnabled = _terminalWakeLockSetting;
    _terminalWakeLockSubscription = ref.listenManual<bool>(
      terminalWakeLockNotifierProvider,
      (previous, next) {
        _terminalWakeLockSetting = next;
        _sessionController.wakeLockEnabled = next;
        _syncTerminalWakeLock();
      },
    );
    _terminalThemeSettingsSubscription = ref
        .listenManual<TerminalThemeSettings>(terminalThemeSettingsProvider, (
          previous,
          next,
        ) {
          if (_sameTerminalThemeSettings(previous, next)) {
            return;
          }
          _handleTerminalThemeDependenciesChanged(
            forceRemoteRefresh: true,
            reason: 'settings_changed',
          );
        });
    _themeModeSubscription = ref.listenManual<ThemeMode>(
      themeModeNotifierProvider,
      (previous, next) {
        if (previous == next) {
          return;
        }
        _handleTerminalThemeDependenciesChanged(
          forceRemoteRefresh: true,
          reason: 'theme_mode_changed',
        );
      },
    );
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminalScrollController = ScrollController()
      ..addListener(_handleTerminalScroll);
    _nativeSelectionScrollController = ScrollController()
      ..addListener(_syncTerminalScrollFromNative);
    _nativeSelectionController = TextEditingController()
      ..addListener(_onNativeOverlayControllerChanged);
    _nativeSelectionFocusNode = FocusNode();
    _isUsingAltBuffer = _terminal.isUsingAltBuffer;
    _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    _terminal.addListener(_onTerminalStateChanged);
    _terminalController.addListener(_onSelectionChanged);
    _terminalFocusNode = FocusNode();
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_loadHostAndConnect);
  }

  _InitialTmuxWindowTarget? _buildInitialTmuxWindowTarget(
    TerminalScreen widget,
  ) {
    final sessionName = widget.initialTmuxSessionName?.trim();
    final windowIndex = widget.initialTmuxWindowIndex;
    final windowId = widget.initialTmuxWindowId?.trim();
    if (sessionName == null ||
        sessionName.isEmpty ||
        windowIndex == null ||
        windowIndex < 0) {
      return null;
    }
    return _InitialTmuxWindowTarget(
      sessionName: sessionName,
      windowIndex: windowIndex,
      windowId: windowId != null && isValidTmuxWindowId(windowId)
          ? windowId
          : null,
      requiresVisibleSession: widget.initialTmuxWindowRequiresVisibleSession,
    );
  }

  void _onTerminalStateChanged() {
    _nativeSelectionSnapshotCache = null;
    _terminalContentGeneration++;
    if (_isNativeSelectionMode && !_hasExpandedNativeOverlaySelection) {
      _refreshNativeOverlayText(preserveSelection: true);
    }

    _queueVisibleTerminalPathUnderlineRefresh();

    if (_shouldFollowLiveOutput && !_isTerminalOutputFollowPaused) {
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
    if (_sessionController.isObservingSession(session)) {
      _captureConnectionOpenedWorkingDirectory();
      return;
    }

    if (!identical(_terminalPathVerificationSession, session)) {
      _disposeTerminalPathVerificationSftp();
    }
    _sessionController.observeSessionMetadata(session);
    _captureConnectionOpenedWorkingDirectory();
  }

  void _handleSessionMetadataChanged() {
    if (!mounted) {
      return;
    }
    _captureConnectionOpenedWorkingDirectory();
    _syncVerifiedTerminalPathCacheScope();
    setState(() {});
  }

  void _captureConnectionOpenedWorkingDirectory() {
    if (_connectionOpenedWorkingDirectory != null) {
      return;
    }

    _connectionOpenedWorkingDirectory = normalizeSftpAbsolutePath(
      _liveWorkingDirectoryPath ?? _tmuxLaunchWorkingDirectory,
    );
  }

  Future<void> _applySharedClipboardSetting({
    required bool enabled,
    required bool allowLocalClipboardRead,
    SshSession? session,
    bool waitForInitialSync = true,
  }) async {
    await _sessionController.applySharedClipboardSetting(
      enabled: enabled,
      allowLocalClipboardRead: allowLocalClipboardRead,
      startSync: _startSharedClipboardSync,
      stopSync: _stopSharedClipboardSync,
      session: session,
      waitForInitialSync: waitForInitialSync,
    );
  }

  void _applyTerminalThemeToSession(
    TerminalThemeData theme, {
    SshSession? session,
    bool forceRemoteRefresh = false,
    String reason = 'unspecified',
  }) {
    final targetSession = _sessionController.resolveTargetSession(
      session: session,
    );
    if (targetSession == null) {
      if (reason != 'build') {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'apply_no_session',
          fields: {
            'reason': reason,
            'connectionId': _connectionId,
            'forceRemoteRefresh': forceRemoteRefresh,
          },
        );
      }
      return;
    }
    final previousTheme = targetSession.terminalTheme;
    targetSession.terminalTheme = theme;
    if (targetSession.terminal != _terminal) {
      if (reason != 'build') {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'apply_foreign_terminal',
          fields: {
            'reason': reason,
            'connectionId': targetSession.connectionId,
            'forceRemoteRefresh': forceRemoteRefresh,
            'hasSessionTerminal': targetSession.terminal != null,
          },
        );
      }
      return;
    }
    final didThemeChange =
        previousTheme != null &&
        !_terminalThemesMatchForRemoteRefresh(previousTheme, theme);
    final plainTuiRefreshAllowed = _shouldRefreshPlainTerminalTui(
      targetSession,
    );
    final terminalViewReady = _isTerminalThemeRefreshViewReady;
    final shouldRefreshFirstTheme =
        previousTheme == null && (_isTmuxActive || plainTuiRefreshAllowed);
    final willRefresh =
        forceRemoteRefresh || didThemeChange || shouldRefreshFirstTheme;
    if (willRefresh || reason != 'build') {
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'apply_decision',
        fields: {
          'reason': reason,
          'connectionId': targetSession.connectionId,
          'forceRemoteRefresh': forceRemoteRefresh,
          'hasPreviousTheme': previousTheme != null,
          'didThemeChange': didThemeChange,
          'shouldRefreshFirstTheme': shouldRefreshFirstTheme,
          'willRefresh': willRefresh,
          'isTmuxActive': _isTmuxActive,
          'plainTuiRefreshAllowed': plainTuiRefreshAllowed,
          'colorSchemeUpdatesMode':
              targetSession.terminalColorSchemeUpdatesMode,
          'focusMode': _terminal.reportFocusMode,
          'altBuffer': _terminal.isUsingAltBuffer,
          'mouseMode': _terminal.mouseMode != MouseMode.none,
          'shellReady': _shell != null,
          'terminalViewReady': terminalViewReady,
        },
      );
    }
    if (willRefresh) {
      _refreshTerminalThemeForTui(theme, targetSession, reason: reason);
      return;
    }
  }

  void _refreshTerminalThemeForTui(
    TerminalThemeData theme,
    SshSession session, {
    required String reason,
  }) {
    _cancelTerminalThemeRefreshTimers();
    final refreshGeneration = ++_terminalThemeRefreshGeneration;
    final plainTuiRefreshAllowed = _shouldRefreshPlainTerminalTui(session);
    final terminalViewReady = _isTerminalThemeRefreshViewReady;
    final tmuxStateBelongsToSession =
        _tmuxStateConnectionId == session.connectionId;
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'refresh_requested',
      fields: {
        'reason': reason,
        'connectionId': session.connectionId,
        'isTmuxActive': _isTmuxActive,
        'tmuxStateBelongsToSession': tmuxStateBelongsToSession,
        'plainTuiRefreshAllowed': plainTuiRefreshAllowed,
        'colorSchemeUpdatesMode': session.terminalColorSchemeUpdatesMode,
        'focusMode': _terminal.reportFocusMode,
        'altBuffer': _terminal.isUsingAltBuffer,
        'mouseMode': _terminal.mouseMode != MouseMode.none,
        'shellReady': _shell != null,
        'terminalViewReady': terminalViewReady,
      },
    );
    if (!terminalViewReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isCurrentTerminalThemeRefresh(
          theme: theme,
          session: session,
          refreshGeneration: refreshGeneration,
        )) {
          return;
        }
        _refreshTerminalThemeForTui(
          theme,
          session,
          reason: '${reason}_view_ready',
        );
      });
    }
    if (_isTmuxActive && tmuxStateBelongsToSession) {
      // Push fresh OSC 10/11/4 reports to tmux itself. tmux caches the outer
      // terminal's default colors and ANSI palette and answers inner-pane OSC
      // queries from that cache.
      _refreshTerminalThemeReportsForTui(
        theme,
        includeColorReports: true,
        reason: '${reason}_tmux_outer',
      );
      _refreshTmuxClientAfterTerminalThemeChange(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        reason: reason,
      );
      return;
    }

    if (!plainTuiRefreshAllowed) {
      // A bare shell prompt treats terminal reports as typed input. Only send
      // synthetic reports after a foreground app has enabled terminal-control
      // modes that identify it as a TUI.
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'plain_refresh_skipped',
        fields: {
          'reason': reason,
          'connectionId': session.connectionId,
          'colorSchemeUpdatesMode': session.terminalColorSchemeUpdatesMode,
          'focusMode': _terminal.reportFocusMode,
          'altBuffer': _terminal.isUsingAltBuffer,
          'mouseMode': _terminal.mouseMode != MouseMode.none,
          'shellReady': _shell != null,
          'terminalViewReady': _isTerminalThemeRefreshViewReady,
        },
      );
      return;
    }

    // Do not send unsolicited OSC palette replies directly to a plain
    // foreground TUI. Codex treats those bytes as user input, and its crossterm
    // color re-query can also be disrupted by unrelated terminal reports.
    // Always send a synthetic focus transition so focus-aware TUIs re-query OSC
    // 10/11 through the normal path; only send the private theme-mode and
    // default-color response cycle to apps that explicitly requested DEC 2031
    // color-scheme updates.
    final includeThemeModeReport = session.terminalColorSchemeUpdatesMode;
    _refreshTerminalThemeReportsForTui(
      theme,
      includeThemeModeReport: false,
      reason: '${reason}_plain_focus',
    );
    if (includeThemeModeReport) {
      _scheduleTerminalThemeRefreshForTui(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        delay: const Duration(milliseconds: 250),
        includeFocusReport: false,
        reason: '${reason}_plain_theme_mode',
      );
      for (final delay in const [
        Duration(milliseconds: 330),
        Duration(milliseconds: 410),
        Duration(milliseconds: 490),
      ]) {
        _scheduleTerminalThemeRefreshForTui(
          theme: theme,
          session: session,
          refreshGeneration: refreshGeneration,
          delay: delay,
          includeFocusReport: false,
          includeThemeModeReport: false,
          includeDefaultColorReports: true,
          reason: '${reason}_plain_defaults',
        );
      }
    }
    _scheduleTerminalThemeRefreshForTui(
      theme: theme,
      session: session,
      refreshGeneration: refreshGeneration,
      delay: const Duration(milliseconds: 550),
      includeThemeModeReport: false,
      reason: '${reason}_plain_focus_late',
    );
    if (includeThemeModeReport) {
      _scheduleTerminalThemeRefreshForTui(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        delay: const Duration(milliseconds: 800),
        includeFocusReport: false,
        reason: '${reason}_plain_theme_mode_late',
      );
    }
  }

  void _refreshTerminalThemeReportsForTui(
    TerminalThemeData theme, {
    bool includeThemeModeReport = true,
    bool includeColorReports = false,
    bool includeDefaultColorReports = false,
    bool includeFocusReport = true,
    String reason = 'unspecified',
  }) {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null || !_isTerminalThemeRefreshViewReady) {
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'reports_unavailable',
        fields: {
          'reason': reason,
          'includeThemeModeReport': includeThemeModeReport,
          'includeColorReports': includeColorReports,
          'includeDefaultColorReports': includeDefaultColorReports,
          'includeFocusReport': includeFocusReport,
          'shellReady': _shell != null,
          'hasOutputCallback': _terminal.onOutput != null,
        },
      );
      return;
    }
    DiagnosticsLogService.instance.debug(
      'terminal.theme',
      'reports_sent',
      fields: {
        'reason': reason,
        'includeThemeModeReport': includeThemeModeReport,
        'includeColorReports': includeColorReports,
        'includeDefaultColorReports': includeDefaultColorReports,
        'includeFocusReport': includeFocusReport,
        'shellReady': _shell != null,
        'hasOutputCallback': _terminal.onOutput != null,
      },
    );
    if (includeThemeModeReport) {
      terminalView.refreshThemeModeReport(isDark: theme.isDark);
    }
    if (includeColorReports) {
      terminalView.refreshThemeColorReports(theme);
    }
    if (includeDefaultColorReports) {
      terminalView.refreshThemeDefaultColorReports(theme);
    }
    if (includeFocusReport) {
      terminalView.refreshFocusReport(forceTransition: true, force: true);
    }
  }

  bool _shouldRefreshPlainTerminalTui(SshSession session) =>
      session.terminalColorSchemeUpdatesMode ||
      _terminal.reportFocusMode ||
      _terminal.isUsingAltBuffer ||
      _terminal.mouseMode != MouseMode.none;

  bool get _isTerminalThemeRefreshViewReady {
    final terminalViewWidget = _terminalViewKey.currentWidget;
    return _terminalViewKey.currentState != null &&
        terminalViewWidget is MonkeyTerminalView &&
        identical(terminalViewWidget.terminal, _terminal);
  }

  /// Proactively pushes the active terminal theme into tmux's per-pane color
  /// cache.
  ///
  /// Called whenever tmux is freshly detected or re-detected, regardless of
  /// whether a theme switch just happened. tmux caches the outer terminal's
  /// default colors per-pane, populated either when tmux first queries the
  /// outer client or via unsolicited OSC reports. If MonkeySSH attaches to a
  /// tmux session that was started under a different (or wrong) outer
  /// terminal — or if a previous attach landed before [SshSession.terminalTheme]
  /// was set — the cache can answer inner-pane OSC 10/11/12 queries with stale
  /// values forever. TUIs like Codex CLI bake those answers into their
  /// composer/surface colors, leaving them mismatched until the cache is
  /// refreshed.
  ///
  /// This priming sends the same OSC reports + tmux pane palette update +
  /// foreground-client redraw that a theme switch would. It also wakes the
  /// foreground pane because tmux may be detected after a TUI has already
  /// cached stale default colors.
  void _primeTmuxTerminalTheme(SshSession session) {
    if (!_isTmuxActive || _tmuxStateConnectionId != session.connectionId) {
      return;
    }
    _cancelTerminalThemeRefreshTimers();
    final theme = session.terminalTheme ?? _resolveEffectiveTerminalTheme();
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'tmux_prime_requested',
      fields: {
        'connectionId': session.connectionId,
        'hasTmuxSessionName': _tmuxSessionName != null,
        'shellReady': _shell != null,
        'terminalViewReady': _terminalViewKey.currentState != null,
      },
    );
    _refreshTerminalThemeReportsForTui(
      theme,
      includeColorReports: true,
      reason: 'tmux_prime_outer',
    );

    final tmuxSessionName = _tmuxSessionName;
    if (tmuxSessionName == null) {
      _scheduleTerminalThemeRefreshForTui(
        theme: theme,
        session: session,
        refreshGeneration: ++_terminalThemeRefreshGeneration,
        delay: const Duration(milliseconds: 150),
        includeColorReports: true,
        reason: 'tmux_prime_no_session_name',
      );
      return;
    }
    final refreshGeneration = ++_terminalThemeRefreshGeneration;
    final extraFlags = _host?.tmuxExtraFlags;
    _queueTmuxTerminalThemeRefresh(
      _TmuxTerminalThemeRefreshRequest(
        theme: theme,
        session: session,
        sessionName: tmuxSessionName,
        refreshGeneration: refreshGeneration,
        reason: 'tmux_prime',
        extraFlags: extraFlags,
      ),
    );
    for (final (:delay, :reason) in const [
      (delay: Duration(milliseconds: 900), reason: 'tmux_prime_late_900ms'),
      (delay: Duration(milliseconds: 1800), reason: 'tmux_prime_late_1800ms'),
    ]) {
      _scheduleTmuxTerminalThemeRefresh(
        _TmuxTerminalThemeRefreshRequest(
          theme: theme,
          session: session,
          sessionName: tmuxSessionName,
          refreshGeneration: refreshGeneration,
          reason: reason,
          extraFlags: extraFlags,
        ),
        delay: delay,
      );
    }
  }

  void _refreshTmuxClientAfterTerminalThemeChange({
    required TerminalThemeData theme,
    required SshSession session,
    required int refreshGeneration,
    required String reason,
  }) {
    final tmuxSessionName = _tmuxSessionName;
    if (tmuxSessionName == null) {
      _scheduleTerminalThemeRefreshForTui(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        delay: const Duration(milliseconds: 150),
        includeColorReports: true,
        reason: '${reason}_tmux_no_session_name',
      );
      return;
    }

    _scheduleTmuxTerminalThemeRefresh(
      _TmuxTerminalThemeRefreshRequest(
        theme: theme,
        session: session,
        sessionName: tmuxSessionName,
        refreshGeneration: refreshGeneration,
        reason: reason,
        extraFlags: _host?.tmuxExtraFlags,
      ),
      delay: const Duration(milliseconds: 75),
    );
  }

  void _scheduleTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest request, {
    required Duration delay,
  }) {
    late final Timer timer;
    timer = Timer(delay, () {
      _terminalThemeRefreshTimers.remove(timer);
      if (_tmuxSessionName != request.sessionName ||
          !_isCurrentTerminalThemeRefresh(
            theme: request.theme,
            session: request.session,
            refreshGeneration: request.refreshGeneration,
          )) {
        return;
      }
      _queueTmuxTerminalThemeRefresh(request);
    });
    _terminalThemeRefreshTimers.add(timer);
  }

  void _queueTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest request,
  ) {
    if (!_isCurrentTerminalThemeRefresh(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
    )) {
      return;
    }
    if (_isTmuxThemeRefreshRunning) {
      _pendingTmuxThemeRefreshRequest = request;
      DiagnosticsLogService.instance.debug(
        'terminal.theme',
        'tmux_refresh_queued',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'shellReady': _shell != null,
          'terminalViewReady': _terminalViewKey.currentState != null,
        },
      );
      return;
    }

    _isTmuxThemeRefreshRunning = true;
    unawaited(_runQueuedTmuxTerminalThemeRefresh(request));
  }

  Future<void> _runQueuedTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest initialRequest,
  ) async {
    try {
      var request = initialRequest;
      while (true) {
        await _runTmuxTerminalThemeRefresh(request);
        final nextRequest = _pendingTmuxThemeRefreshRequest;
        _pendingTmuxThemeRefreshRequest = null;
        if (nextRequest == null ||
            !_isCurrentTerminalThemeRefresh(
              theme: nextRequest.theme,
              session: nextRequest.session,
              refreshGeneration: nextRequest.refreshGeneration,
            )) {
          return;
        }
        request = nextRequest;
      }
    } finally {
      _isTmuxThemeRefreshRunning = false;
    }
  }

  Future<void> _runTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest request,
  ) async {
    if (!_isCurrentTerminalThemeRefresh(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
    )) {
      return;
    }

    try {
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'tmux_refresh_start',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'shellReady': _shell != null,
          'terminalViewReady': _terminalViewKey.currentState != null,
        },
      );
      await ref
          .read(tmuxServiceProvider)
          .refreshTerminalTheme(
            request.session,
            request.sessionName,
            request.theme,
            extraFlags: request.extraFlags,
          );
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'tmux_refresh_complete',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'shellReady': _shell != null,
          'terminalViewReady': _terminalViewKey.currentState != null,
        },
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.theme',
        'tmux_refresh_failed',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }

    if (!_isCurrentTerminalThemeRefresh(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
    )) {
      return;
    }
    _refreshTerminalThemeReportsForTui(
      request.theme,
      includeColorReports: true,
      reason: '${request.reason}_tmux_complete_outer',
    );
    _scheduleTerminalThemeRefreshForTui(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
      delay: const Duration(milliseconds: 25),
      includeColorReports: true,
      reason: '${request.reason}_tmux_complete_outer_25ms',
    );
    _scheduleTerminalThemeRefreshForTui(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
      delay: const Duration(milliseconds: 275),
      includeColorReports: true,
      reason: '${request.reason}_tmux_complete_outer_275ms',
    );
  }

  void _scheduleTerminalThemeRefreshForTui({
    required TerminalThemeData theme,
    required SshSession session,
    required int refreshGeneration,
    required Duration delay,
    bool includeThemeModeReport = true,
    bool includeColorReports = false,
    bool includeDefaultColorReports = false,
    bool includeFocusReport = true,
    String reason = 'unspecified',
  }) {
    late final Timer timer;
    timer = Timer(delay, () {
      _terminalThemeRefreshTimers.remove(timer);
      if (!_isCurrentTerminalThemeRefresh(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
      )) {
        return;
      }
      _refreshTerminalThemeReportsForTui(
        theme,
        includeThemeModeReport: includeThemeModeReport,
        includeColorReports: includeColorReports,
        includeDefaultColorReports: includeDefaultColorReports,
        includeFocusReport: includeFocusReport,
        reason: reason,
      );
    });
    _terminalThemeRefreshTimers.add(timer);
  }

  void _cancelTerminalThemeRefreshTimers() {
    for (final timer in _terminalThemeRefreshTimers) {
      timer.cancel();
    }
    _terminalThemeRefreshTimers.clear();
  }

  bool _isCurrentTerminalThemeRefresh({
    required TerminalThemeData theme,
    required SshSession session,
    required int refreshGeneration,
  }) {
    final activeTheme = session.terminalTheme;
    return mounted &&
        refreshGeneration == _terminalThemeRefreshGeneration &&
        session.terminal == _terminal &&
        activeTheme != null &&
        _terminalThemesMatchForRemoteRefresh(activeTheme, theme);
  }

  bool _terminalThemesMatchForRemoteRefresh(
    TerminalThemeData previous,
    TerminalThemeData next,
  ) =>
      previous.id == next.id &&
      previous.isDark == next.isDark &&
      previous.foreground == next.foreground &&
      previous.background == next.background &&
      previous.cursor == next.cursor &&
      previous.selection == next.selection &&
      previous.black == next.black &&
      previous.red == next.red &&
      previous.green == next.green &&
      previous.yellow == next.yellow &&
      previous.blue == next.blue &&
      previous.magenta == next.magenta &&
      previous.cyan == next.cyan &&
      previous.white == next.white &&
      previous.brightBlack == next.brightBlack &&
      previous.brightRed == next.brightRed &&
      previous.brightGreen == next.brightGreen &&
      previous.brightYellow == next.brightYellow &&
      previous.brightBlue == next.brightBlue &&
      previous.brightMagenta == next.brightMagenta &&
      previous.brightCyan == next.brightCyan &&
      previous.brightWhite == next.brightWhite;

  bool _sameTerminalTheme(
    TerminalThemeData? previous,
    TerminalThemeData? next,
  ) {
    if (previous == null || next == null) {
      return previous == next;
    }
    return _terminalThemesMatchForRemoteRefresh(previous, next);
  }

  bool _sameTerminalThemeSettings(
    TerminalThemeSettings? previous,
    TerminalThemeSettings next,
  ) =>
      previous != null &&
      previous.lightThemeId == next.lightThemeId &&
      previous.darkThemeId == next.darkThemeId;

  void _handleTerminalThemeDependenciesChanged({
    bool forceRemoteRefresh = false,
    String reason = 'unknown',
  }) {
    if (!mounted) {
      return;
    }
    _pendingTerminalThemeDependencyReload = true;
    _pendingTerminalThemeDependencyForceRemoteRefresh =
        _pendingTerminalThemeDependencyForceRemoteRefresh || forceRemoteRefresh;
    _pendingTerminalThemeDependencyReason = reason;
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'dependency_changed',
      fields: {
        'reason': reason,
        'connectionId': _connectionId,
        'forceRemoteRefresh': forceRemoteRefresh,
        'hasCurrentTheme': _currentTheme != null,
        'hasSessionOverride': _sessionThemeOverride != null,
      },
    );
    _scheduleTerminalThemeDependencyReload();
  }

  void _scheduleTerminalThemeDependencyReload() {
    if (_terminalThemeDependencyReloadQueued) {
      return;
    }
    _terminalThemeDependencyReloadQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminalThemeDependencyReloadQueued = false;
      if (!mounted || !_pendingTerminalThemeDependencyReload) {
        return;
      }
      if (_currentTheme == null) {
        return;
      }
      final forceRemoteRefresh =
          _pendingTerminalThemeDependencyForceRemoteRefresh;
      final reason = _pendingTerminalThemeDependencyReason;
      _pendingTerminalThemeDependencyReload = false;
      _pendingTerminalThemeDependencyForceRemoteRefresh = false;
      _pendingTerminalThemeDependencyReason = 'unknown';
      unawaited(
        _reloadTerminalThemeForDependencies(
          forceRemoteRefresh: forceRemoteRefresh,
          reason: reason,
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _reloadTerminalThemeForDependencies({
    bool forceRemoteRefresh = false,
    String reason = 'unknown',
  }) async {
    final session = _connectionId == null
        ? null
        : _sessionsNotifier?.getSession(_connectionId!);
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'dependency_reload',
      fields: {
        'reason': reason,
        'connectionId': _connectionId,
        'forceRemoteRefresh': forceRemoteRefresh,
        'hasSession': session != null,
        'hasSessionOverride': _sessionThemeOverride != null,
      },
    );
    if (session != null) {
      final restored = await _restoreSessionThemeOverride(
        session,
        forceRemoteRefresh: forceRemoteRefresh,
        reason: reason,
      );
      if (restored) {
        return;
      }
    }

    if (_sessionThemeOverride == null) {
      await _loadTheme(forceRemoteRefresh: forceRemoteRefresh, reason: reason);
    }
  }

  void _syncAppThemeOverrideFromSession(SshSession session) {
    if (session.terminalThemeLightId == null &&
        session.terminalThemeDarkId == null) {
      _clearAppThemeOverride();
      return;
    }
    _terminalAppThemeOverrideNotifier.activeOverride = TerminalAppThemeOverride(
      owner: _terminalAppThemeOverrideOwner,
      lightThemeId: session.terminalThemeLightId,
      darkThemeId: session.terminalThemeDarkId,
    );
  }

  void _clearAppThemeOverride() => _terminalAppThemeOverrideNotifier
      .clearForOwner(_terminalAppThemeOverrideOwner);

  TerminalThemeData _resolveEffectiveTerminalTheme() {
    final isDark = _resolveTerminalThemeBrightness() == Brightness.dark;
    return _sessionThemeOverride ??
        _currentTheme ??
        (isDark
            ? TerminalThemes.defaultDarkTheme
            : TerminalThemes.defaultLightTheme);
  }

  Brightness _resolveTerminalThemeBrightness() {
    final themeMode = ref.read(themeModeNotifierProvider);
    return switch (themeMode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
  }

  SshConnectionState _selectTrackedConnectionState(
    Map<int, SshConnectionState> states,
  ) => _sessionController.selectTrackedConnectionState(states);

  Future<void> _startSharedClipboardSync(SshSession session) async {
    _stopSharedClipboardSync();
    _remoteClipboardUnsupported = false;
    _lastObservedLocalClipboardText = session.localClipboardReadEnabled
        ? await _readSystemClipboardText()
        : null;
    _lastObservedRemoteClipboardText = await _readRemoteClipboardText(session);

    if (!mounted ||
        !session.clipboardSharingEnabled ||
        _remoteClipboardUnsupported) {
      return;
    }

    if (session.localClipboardReadEnabled) {
      _localClipboardSyncTimer = Timer.periodic(
        _localClipboardSyncInterval,
        (_) => unawaited(_syncLocalClipboardToRemote(session)),
      );
    }
    if (!_remoteClipboardUnsupported) {
      _remoteClipboardSyncTimer = Timer.periodic(
        _remoteClipboardSyncInterval,
        (_) => unawaited(_syncRemoteClipboardToLocal(session)),
      );
    }
  }

  void _stopSharedClipboardSync() {
    _localClipboardSyncTimer?.cancel();
    _localClipboardSyncTimer = null;
    _remoteClipboardSyncTimer?.cancel();
    _remoteClipboardSyncTimer = null;
    _isPollingRemoteClipboard = false;
    _isPushingLocalClipboard = false;
  }

  Future<String?> _readSystemClipboardText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        return data!.text;
      }
    } on PlatformException {
      if (!_isAndroidPlatform) {
        return null;
      }
    }

    if (_isAndroidPlatform) {
      try {
        return await Pasteboard.text;
      } on PlatformException {
        return null;
      }
    }

    return null;
  }

  Future<void> _syncLocalClipboardToRemote(SshSession session) async {
    if (!mounted ||
        !session.clipboardSharingEnabled ||
        !session.localClipboardReadEnabled ||
        !_sessionController.isObservingSession(session) ||
        _remoteClipboardUnsupported ||
        _isPushingLocalClipboard) {
      return;
    }

    final localText = await _readSystemClipboardText();
    if (localText == null ||
        localText == _lastObservedLocalClipboardText ||
        localText == _lastObservedRemoteClipboardText ||
        localText == _lastAppliedLocalClipboardText ||
        !RemoteClipboardSyncService.canSyncText(localText)) {
      _lastObservedLocalClipboardText = localText;
      return;
    }

    _isPushingLocalClipboard = true;
    try {
      final output = await _runRemoteCommand(
        session,
        RemoteClipboardSyncService.buildWriteCommand(localText),
      );
      if (RemoteClipboardSyncService.outputIndicatesUnsupported(output)) {
        _remoteClipboardUnsupported = true;
        _remoteClipboardSyncTimer?.cancel();
        _remoteClipboardSyncTimer = null;
        return;
      }
      _lastObservedLocalClipboardText = localText;
      _lastObservedRemoteClipboardText = localText;
      _lastAppliedRemoteClipboardText = localText;
    } finally {
      _isPushingLocalClipboard = false;
    }
  }

  Future<void> _syncRemoteClipboardToLocal(SshSession session) async {
    if (!mounted ||
        !session.clipboardSharingEnabled ||
        !_sessionController.isObservingSession(session) ||
        _remoteClipboardUnsupported ||
        _isPollingRemoteClipboard) {
      return;
    }

    _isPollingRemoteClipboard = true;
    try {
      final remoteText = await _readRemoteClipboardText(session);
      if (!shouldApplyRemoteClipboardTextToLocal(
        remoteText: remoteText,
        lastObservedRemoteText: _lastObservedRemoteClipboardText,
        lastObservedLocalText: _lastObservedLocalClipboardText,
        lastAppliedRemoteText: _lastAppliedRemoteClipboardText,
        recentLocalClipboardText: _recentLocalClipboardText,
        recentLocalClipboardAt: _recentLocalClipboardAt,
        now: DateTime.now(),
      )) {
        if (remoteText != null) {
          _lastObservedRemoteClipboardText = remoteText;
        }
        return;
      }

      final remoteClipboardText = remoteText;
      if (remoteClipboardText == null) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: remoteClipboardText));
      _lastObservedRemoteClipboardText = remoteClipboardText;
      _lastObservedLocalClipboardText = remoteClipboardText;
      _lastAppliedLocalClipboardText = remoteClipboardText;
    } on PlatformException {
      return;
    } finally {
      _isPollingRemoteClipboard = false;
    }
  }

  Future<String?> _readRemoteClipboardText(SshSession session) async {
    final output = await _runRemoteCommand(
      session,
      RemoteClipboardSyncService.buildReadCommand(),
    );
    final parsed = RemoteClipboardSyncService.parseReadOutput(output);
    if (!parsed.supported) {
      _remoteClipboardUnsupported = true;
      return null;
    }
    return parsed.text;
  }

  Future<String> _runRemoteCommand(SshSession session, String command) =>
      session.runQueuedExec(() async {
        final exec = await session.execute(command);
        try {
          final stdout = StringBuffer();
          final stderr = StringBuffer();
          final stdoutFuture = exec.stdout
              .cast<List<int>>()
              .transform(utf8.decoder)
              .forEach(stdout.write);
          final stderrFuture = exec.stderr
              .cast<List<int>>()
              .transform(utf8.decoder)
              .forEach(stderr.write);
          await Future.wait<void>([stdoutFuture, stderrFuture, exec.done]);
          return stdout.toString().isNotEmpty
              ? stdout.toString()
              : stderr.toString();
        } finally {
          exec.close();
        }
      }, priority: SshExecPriority.low);

  void _handleTerminalScroll() {
    final currentOffset = _terminalScrollController.hasClients
        ? _terminalScrollController.offset
        : 0.0;
    final didScrollOffsetChange = currentOffset != _lastTerminalScrollOffset;
    _lastTerminalScrollOffset = currentOffset;
    if (!_isTerminalOutputFollowPaused || didScrollOffsetChange) {
      _shouldFollowLiveOutput = shouldFollowTerminalOutput(
        hasScrollClients: _terminalScrollController.hasClients,
        currentOffset: currentOffset,
        maxScrollExtent: _terminalScrollController.hasClients
            ? _terminalScrollController.position.maxScrollExtent
            : 0,
      );
    }
    _syncNativeScrollFromTerminal();
    _refreshVisibleTerminalPathUnderlines();
  }

  void _followLiveOutput() {
    _shouldFollowLiveOutput = true;
    _queueTerminalScrollToBottom();
  }

  void _handleTerminalLinkTapDown(
    TapDownDetails tapDetails,
    CellOffset cellOffset,
  ) {
    _terminalTextInputController.suppressNextTouchKeyboardRequest();
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
          _isTerminalOutputFollowPaused ||
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

    final hasActiveSelection = _hasActiveSystemSelection;
    _syncTerminalLiveOutputAutoScroll();
    setState(() {});
    if (!hasActiveSelection &&
        _shouldFollowLiveOutput &&
        !_isTerminalOutputFollowPaused) {
      _queueTerminalScrollToBottom();
    }
  }

  void _syncNativeScrollFromTerminal({bool force = false}) {
    if (!_showsNativeSelectionOverlay ||
        (!force && _hasExpandedNativeOverlaySelection) ||
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
    _autoConnectAgentPreset = await ref
        .read(agentLaunchPresetServiceProvider)
        .getPresetForHost(widget.hostId);
    final cliLaunchPreferences = await ref
        .read(hostCliLaunchPreferencesServiceProvider)
        .getPreferencesForHost(widget.hostId);
    _startClisInYoloMode = cliLaunchPreferences.startInYoloMode;
    DiagnosticsLogService.instance.info(
      'terminal.screen',
      'host_loaded',
      fields: {
        'hostId': widget.hostId,
        'hasHost': _host != null,
        'hasAutoConnectCommand':
            _host?.autoConnectCommand?.trim().isNotEmpty ?? false,
        'hasTmuxAutoAttach': _host?.tmuxSessionName?.trim().isNotEmpty ?? false,
      },
    );
    await _loadTheme(reason: 'initial_load');
    await _connect(preferredConnectionId: widget.connectionId);
  }

  Future<void> _loadTheme({
    bool forceRemoteRefresh = false,
    String reason = 'load_theme',
  }) async {
    if (!mounted) return;

    final brightness = _resolveTerminalThemeBrightness();
    _lastThemeDependencyBrightness = brightness;
    final themeService = ref.read(terminalThemeServiceProvider);
    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final theme = await themeService.getThemeForHost(
      _host,
      brightness,
      allowHostOverride: monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      ),
    );

    if (!mounted) {
      return;
    }
    final didThemeChange = !_sameTerminalTheme(_currentTheme, theme);
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'loaded',
      fields: {
        'reason': reason,
        'connectionId': _connectionId,
        'forceRemoteRefresh': forceRemoteRefresh,
        'brightness': brightness.name,
        'didThemeChange': didThemeChange,
        'hasSessionOverride': _sessionThemeOverride != null,
      },
    );
    if (didThemeChange) {
      setState(() => _currentTheme = theme);
    } else {
      _currentTheme = theme;
    }
    _applyTerminalThemeToSession(
      theme,
      forceRemoteRefresh: forceRemoteRefresh,
      reason: reason,
    );
    if (_pendingTerminalThemeDependencyReload) {
      _scheduleTerminalThemeDependencyReload();
    }
  }

  Future<bool> _restoreSessionThemeOverride(
    SshSession session, {
    bool forceRemoteRefresh = false,
    String reason = 'restore_override',
  }) async {
    final brightness = _resolveTerminalThemeBrightness();
    final themeId = brightness == Brightness.dark
        ? session.terminalThemeDarkId
        : session.terminalThemeLightId;

    if (themeId == null) {
      if (mounted) {
        if (_sessionThemeOverride != null) {
          setState(() => _sessionThemeOverride = null);
        }
        _syncAppThemeOverrideFromSession(session);
      }
      if (forceRemoteRefresh) {
        await _loadTheme(
          forceRemoteRefresh: true,
          reason: '${reason}_fallback',
        );
        return true;
      }
      return false;
    }

    final themeService = ref.read(terminalThemeServiceProvider);
    final resolvedTheme = await themeService.getThemeById(themeId);
    if (!mounted) {
      return false;
    }
    if (resolvedTheme == null) {
      if (_sessionThemeOverride != null) {
        setState(() => _sessionThemeOverride = null);
      }
      return false;
    }
    if (!_sameTerminalTheme(_sessionThemeOverride, resolvedTheme)) {
      setState(() => _sessionThemeOverride = resolvedTheme);
    } else {
      _sessionThemeOverride = resolvedTheme;
    }
    _applyTerminalThemeToSession(
      resolvedTheme,
      session: session,
      forceRemoteRefresh: forceRemoteRefresh,
      reason: reason,
    );
    _syncAppThemeOverrideFromSession(session);
    return true;
  }

  Future<void> _connect({
    int? preferredConnectionId,
    bool forceNew = false,
  }) async {
    if (!mounted) return;

    // Clean up any previous connection state before reconnecting.
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    await _shellStdoutSubscription?.cancel();
    _shellStdoutSubscription = null;
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = null;
    _shell = null;
    // Allow the build-path safety-net call to fire once for the new session.
    _lastBuildAppliedTheme = null;

    setState(() {
      _isConnecting = true;
      _error = null;
      _connectionOpenedWorkingDirectory = null;
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

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;

    final result = await _sessionsNotifier!.connect(
      widget.hostId,
      forceNew: shouldForceNew,
      useHostThemeOverrides: monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      ),
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
      _syncTerminalWakeLock(SshConnectionState.disconnected);
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
        final sharedClipboardEnabled = await ref.read(
          sharedClipboardProvider.future,
        );
        final sharedClipboardLocalReadEnabled = await ref.read(
          sharedClipboardLocalReadProvider.future,
        );
        session
          ..clipboardSharingEnabled = sharedClipboardEnabled
          ..localClipboardReadEnabled =
              sharedClipboardEnabled && sharedClipboardLocalReadEnabled;
        _terminal.removeListener(_onTerminalStateChanged);
        _terminal = existingTerminal;
        _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
        _observeSessionMetadata(session);
        _isUsingAltBuffer = _terminal.isUsingAltBuffer;
        _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
        _terminal.addListener(_onTerminalStateChanged);
        _shell = await session.getShell();
        _wireTerminalCallbacks(session);
        _applyTerminalThemeToSession(
          _resolveEffectiveTerminalTheme(),
          session: session,
          reason: 'open_existing_terminal',
        );
        await _applySharedClipboardSetting(
          enabled: sharedClipboardEnabled,
          allowLocalClipboardRead: sharedClipboardLocalReadEnabled,
          session: session,
          waitForInitialSync: false,
        );
        await _restoreSessionThemeOverride(
          session,
          forceRemoteRefresh: true,
          reason: 'open_existing_restore_override',
        );
        setState(() {
          _sessionFontSizeOverride = session.terminalFontSize;
          _isConnecting = false;
        });
        _syncTerminalWakeLock(SshConnectionState.connected);
        _scheduleTerminalSizeRefresh();
        _restoreTerminalFocus();

        // Detect tmux on existing sessions too (may not have been detected
        // yet if the terminal was opened before tmux started).
        if (!_isTmuxActive) {
          unawaited(
            _detectTmux(
              session,
              skipDelay: true,
              isReopeningExistingTerminal: true,
            ),
          );
        }
        return;
      }

      // First time opening shell for this session — create terminal in session.
      final sessionTerminal = session.getOrCreateTerminal();
      final sharedClipboardEnabled = await ref.read(
        sharedClipboardProvider.future,
      );
      final sharedClipboardLocalReadEnabled = await ref.read(
        sharedClipboardLocalReadProvider.future,
      );
      session
        ..clipboardSharingEnabled = sharedClipboardEnabled
        ..localClipboardReadEnabled =
            sharedClipboardEnabled && sharedClipboardLocalReadEnabled;
      _terminal.removeListener(_onTerminalStateChanged);
      _terminal = sessionTerminal;
      _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
      _observeSessionMetadata(session);
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      _terminal.addListener(_onTerminalStateChanged);
      _applyTerminalThemeToSession(
        _resolveEffectiveTerminalTheme(),
        session: session,
        reason: 'open_new_terminal',
      );

      _shell = await session.getShell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );
      DiagnosticsLogService.instance.info(
        'terminal',
        'shell_opened',
        fields: {'connectionId': session.connectionId, 'reusedTerminal': false},
      );

      _wireTerminalCallbacks(session);
      await _applySharedClipboardSetting(
        enabled: sharedClipboardEnabled,
        allowLocalClipboardRead: sharedClipboardLocalReadEnabled,
        session: session,
        waitForInitialSync: false,
      );

      if (!mounted) return;

      await _restoreSessionThemeOverride(
        session,
        forceRemoteRefresh: true,
        reason: 'open_new_restore_override',
      );
      setState(() {
        _sessionFontSizeOverride = session.terminalFontSize;
        _isConnecting = false;
      });
      _syncTerminalWakeLock(SshConnectionState.connected);
      _scheduleTerminalSizeRefresh();
      _restoreTerminalFocus();

      // Start port forwards
      await _startPortForwards(session);
      await _runAutoConnectCommand();

      // Detect tmux after the auto-connect command has had time to start.
      // A small delay ensures tmux has initialized if the auto-connect
      // command launches a tmux session.
      unawaited(_detectTmux(session));
    } on Object catch (e) {
      DiagnosticsLogService.instance.error(
        'terminal',
        'shell_open_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': e.runtimeType,
        },
      );
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _error = 'Failed to start shell. Try reconnecting.';
      });
    }
  }

  /// Wire terminal onOutput/onResize callbacks for this screen instance.
  void _wireTerminalCallbacks(SshSession session) {
    // Listen for shell close events.
    _doneSubscription = session.shellDoneStream.listen((_) {
      DiagnosticsLogService.instance.warning(
        'terminal',
        'shell_done_stream',
        fields: {'connectionId': session.connectionId},
      );
      if (mounted) {
        _handleShellClosed();
      }
    });
    _shellStdoutSubscription = session.shellStdoutStream.listen(
      _schedulePromptOutputImeResetCheck,
      onError: (Object error, StackTrace stackTrace) {
        if (kDebugMode) {
          debugPrint('Terminal stdout stream error: $error');
          debugPrint('$stackTrace');
        }
        DiagnosticsLogService.instance.error(
          'terminal',
          'stdout_listener_error',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      },
    );

    _terminal.onOutput = (data) {
      // On iOS/Android soft keyboards, Return sends a lone '\n' via
      // textInput(), but SSH expects '\r'. The proper
      // keyInput(TerminalKey.enter) path already produces '\r', so we
      // only normalize single-'\n' to avoid rewriting legitimate LF
      // characters in pasted or multi-char input.
      final output = normalizeTerminalOutputForRemoteShell(
        data == '\n' ? '\r' : data,
      );

      _shell?.write(utf8.encode(output));
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      session.updateTerminalWindowMetrics(
        columns: width,
        rows: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      );
      _shell?.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };
  }

  void _scheduleTerminalSizeRefresh() {
    if (_isTerminalSizeRefreshQueued) {
      return;
    }
    _isTerminalSizeRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalSizeRefreshQueued = false;
      if (!mounted) {
        return;
      }
      _terminalViewKey.currentState?.refreshTerminalSize();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  SshConnectionState _readCurrentConnectionState() {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return SshConnectionState.disconnected;
    }
    return ref.read(activeSessionsProvider)[connectionId] ??
        SshConnectionState.disconnected;
  }

  void _syncTerminalWakeLock([SshConnectionState? connectionState]) {
    _sessionController.syncWakeLock(connectionState);
  }

  void _schedulePromptOutputImeResetCheck(String data) {
    if (!_isMobilePlatform || !_shellOutputLooksLikePromptReturn(data)) {
      return;
    }
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = Timer(_promptOutputImeResetDebounce, () {
      _promptOutputImeResetTimer = null;
      if (!mounted) {
        return;
      }
      _terminalTextInputController.handleExternalTerminalOutput();
    });
  }

  bool _shellOutputLooksLikePromptReturn(String data) {
    final sanitizedData = _stripTerminalPromptEscapeSequences(data);
    if (sanitizedData.isEmpty) {
      return false;
    }

    var index = sanitizedData.length - 1;
    while (index >= 0) {
      final codeUnit = sanitizedData.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return false;
      }
      if (!_isPromptReturnWhitespaceCodeUnit(codeUnit)) {
        break;
      }
      index--;
    }

    if (index < 0) {
      return false;
    }

    var visibleCodeUnitCount = 0;
    while (index >= 0) {
      final codeUnit = sanitizedData.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        break;
      }
      if (!_isPromptReturnWhitespaceCodeUnit(codeUnit)) {
        visibleCodeUnitCount++;
        if (visibleCodeUnitCount > 4) {
          return false;
        }
        if (_isPromptReturnAsciiLetterOrDigit(codeUnit)) {
          return false;
        }
      }
      index--;
    }

    return visibleCodeUnitCount > 0;
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

    // Structured tmux attach is a first-class connection mode, not a generic
    // automation command. Run it even when Pro-only auto-connect automation is
    // unavailable so tmux-native navigation remains accessible.
    final tmuxSession = _initialTmuxSessionName ?? host.tmuxSessionName;
    if (tmuxSession != null && tmuxSession.isNotEmpty) {
      final tmuxCommand = buildTmuxCommand(
        sessionName: tmuxSession,
        workingDirectory: host.tmuxWorkingDirectory,
        extraFlags: host.tmuxExtraFlags,
      );
      final review = assessAutoConnectCommandExecution(
        tmuxCommand,
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
      shell.write(utf8.encode(formatAutoConnectCommandForShell(tmuxCommand)));
      return;
    }

    final resolvedStoredCommand = _resolveStoredAutoConnectCommand(host);
    final mode = resolveAutoConnectCommandMode(
      command: resolvedStoredCommand,
      snippetId: host.autoConnectSnippetId,
    );
    if (mode == AutoConnectCommandMode.none) {
      return;
    }

    final hasAccess = await ref
        .read(monetizationServiceProvider)
        .canUseFeature(MonetizationFeature.autoConnectAutomation);
    if (!hasAccess) {
      if (mounted) {
        final bottomMargin = upgradeSnackBarBottomMargin(
          MediaQuery.of(context),
          showKeyboardToolbar: _showKeyboardToolbar,
          keyboardToolbarHeight: resolveKeyboardToolbarHeight(
            MediaQuery.of(context),
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
            content: const Text(
              'This auto-connect workflow needs MonkeySSH Pro to run.',
            ),
            action: SnackBarAction(
              label: 'Upgrade',
              onPressed: () => context.pushNamed(
                Routes.upgrade,
                queryParameters: <String, String>{
                  'feature': MonetizationFeature.autoConnectAutomation.name,
                  'action': 'Run this auto-connect workflow',
                  'outcome':
                      'Unlock Pro to run saved commands or snippets '
                      'automatically when a terminal opens.',
                },
              ),
            ),
          ),
        );
      }
      return;
    }

    String? snippetCommand;
    int? resolvedSnippetId;
    final snippetId = host.autoConnectSnippetId;
    if (snippetId != null) {
      final snippetRepo = ref.read(snippetRepositoryProvider);
      final snippet = await snippetRepo.getById(snippetId);
      if (snippet == null) {
        if (kDebugMode) {
          debugPrint(
            'Auto-connect snippet $snippetId is unavailable; '
            'using cached command.',
          );
        }
      } else {
        snippetCommand = snippet.command;
        resolvedSnippetId = snippet.id;
      }
    }

    final command = resolveAutoConnectCommandText(
      mode: mode,
      storedCommand: resolvedStoredCommand,
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

  String? get _initialTmuxSessionName {
    final sessionName = widget.initialTmuxSessionName?.trim();
    return sessionName == null || sessionName.isEmpty ? null : sessionName;
  }

  String? _preferredTmuxSessionName(Host? host) =>
      _initialTmuxSessionName ??
      resolvePreferredTmuxSessionName(
        structuredSessionName: host?.tmuxSessionName,
        autoConnectCommand: _resolveStoredAutoConnectCommand(host),
      );

  void _clearTmuxState() {
    _stopTmuxForegroundVerification();
    _tmuxDetectionGeneration += 1;
    _isTmuxActive = false;
    _tmuxSessionName = null;
    _tmuxStateConnectionId = null;
    _isTmuxBarExpanded = false;
    _tmuxLaunchWorkingDirectory = null;
    _tmuxWorkingDirectory = null;
  }

  void _startTmuxForegroundVerification(
    SshSession session,
    String sessionName,
  ) {
    _tmuxForegroundVerificationTimer?.cancel();
    _tmuxForegroundVerificationInFlight = false;
    final generation = ++_tmuxForegroundVerificationGeneration;
    _tmuxForegroundVerificationTimer = Timer.periodic(
      _tmuxForegroundVerificationInterval,
      (_) => unawaited(
        _verifyTmuxForegroundSession(session, sessionName, generation),
      ),
    );
  }

  void _stopTmuxForegroundVerification() {
    _tmuxForegroundVerificationTimer?.cancel();
    _tmuxForegroundVerificationTimer = null;
    _tmuxForegroundVerificationGeneration += 1;
    _tmuxForegroundVerificationInFlight = false;
  }

  Future<void> _verifyTmuxForegroundSession(
    SshSession session,
    String sessionName,
    int generation,
  ) async {
    if (_tmuxForegroundVerificationInFlight ||
        !mounted ||
        generation != _tmuxForegroundVerificationGeneration ||
        _connectionId != session.connectionId ||
        !_isTmuxActive ||
        _tmuxSessionName != sessionName) {
      return;
    }

    _tmuxForegroundVerificationInFlight = true;
    try {
      final foregroundSessionName = await ref
          .read(tmuxServiceProvider)
          .foregroundSessionNameOrThrow(
            session,
            extraFlags: _host?.tmuxExtraFlags,
          );
      if (!mounted ||
          generation != _tmuxForegroundVerificationGeneration ||
          _connectionId != session.connectionId ||
          !_isTmuxActive ||
          _tmuxSessionName != sessionName) {
        return;
      }
      if (foregroundSessionName == sessionName) {
        DiagnosticsLogService.instance.debug(
          'tmux.ui',
          'foreground_verified',
          fields: {'connectionId': session.connectionId},
        );
        return;
      }

      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'foreground_detached',
        fields: {
          'connectionId': session.connectionId,
          'hasForegroundSession': foregroundSessionName != null,
        },
      );
      setState(_clearTmuxState);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'foreground_verify_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    } finally {
      if (generation == _tmuxForegroundVerificationGeneration) {
        _tmuxForegroundVerificationInFlight = false;
      }
    }
  }

  /// Detects whether the connected session is inside tmux.
  ///
  /// Starts with any structured tmux configuration immediately, then retries
  /// discovery until the shell-side attach command has settled.
  Future<bool> _detectTmux(
    SshSession session, {
    bool skipDelay = false,
    bool preserveExistingTmuxState = false,
    bool isReopeningExistingTerminal = false,
  }) async {
    // Capture the connection ID at the start so we can verify it hasn't
    // changed after async gaps (user may have switched connections).
    final capturedConnectionId = _connectionId;
    final detectionGeneration = ++_tmuxDetectionGeneration;
    final host = _host;
    final preferredSessionName = _preferredTmuxSessionName(host);
    final tmuxStateBelongsToSession =
        _tmuxStateConnectionId == session.connectionId;
    final mayPreserveExistingTmuxState =
        preserveExistingTmuxState && tmuxStateBelongsToSession;
    final existingCandidateSessionName =
        resolveOwnedTmuxDetectionExistingSessionName(
          sessionConnectionId: session.connectionId,
          tmuxStateConnectionId: _tmuxStateConnectionId,
          existingSessionName: _tmuxSessionName,
        );
    final candidateSessionName = resolveTmuxDetectionCandidateSessionName(
      preferredSessionName: preferredSessionName,
      existingSessionName: existingCandidateSessionName,
    );
    final hasExistingVisibleTmuxState =
        tmuxStateBelongsToSession && _isTmuxActive && _tmuxSessionName != null;
    final shouldKeepExistingTmuxStateWhileDetecting =
        mayPreserveExistingTmuxState ||
        (hasExistingVisibleTmuxState &&
            candidateSessionName != null &&
            candidateSessionName == existingCandidateSessionName);
    final shouldPrimeTmuxStateWhileDetecting =
        shouldPrimeTerminalTmuxStateWhileDetecting(
          candidateSessionName: candidateSessionName,
          hasExistingVisibleTmuxState: hasExistingVisibleTmuxState,
          mayPreserveExistingTmuxState: mayPreserveExistingTmuxState,
          isReopeningExistingTerminal: isReopeningExistingTerminal,
        );
    final hadVisibleOrPrimedTmuxState =
        hasExistingVisibleTmuxState || shouldPrimeTmuxStateWhileDetecting;
    final preferredWorkingDirectory = host?.tmuxWorkingDirectory;
    var confirmedTmuxActive = false;
    var hadDetectionFailure = false;

    if (mounted) {
      setState(() {
        if (shouldKeepExistingTmuxStateWhileDetecting) {
          if (preferredWorkingDirectory != null) {
            _tmuxLaunchWorkingDirectory = preferredWorkingDirectory;
            _tmuxWorkingDirectory = preferredWorkingDirectory;
          }
        } else if (shouldPrimeTmuxStateWhileDetecting) {
          _isTmuxActive = true;
          _tmuxSessionName = candidateSessionName;
          _tmuxStateConnectionId = session.connectionId;
          _tmuxLaunchWorkingDirectory = preferredWorkingDirectory;
          _tmuxWorkingDirectory = preferredWorkingDirectory;
        } else if (!mayPreserveExistingTmuxState) {
          _stopTmuxForegroundVerification();
          _isTmuxActive = false;
          _tmuxSessionName = null;
          _tmuxStateConnectionId = null;
          _tmuxLaunchWorkingDirectory = null;
          _tmuxWorkingDirectory = null;
        }
      });
    }

    try {
      final tmux = ref.read(tmuxServiceProvider);
      final retrySchedule = resolveTmuxDetectionRetrySchedule(
        skipDelay: skipDelay,
      );

      for (final delay in retrySchedule) {
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
          if (!mounted ||
              _connectionId != capturedConnectionId ||
              detectionGeneration != _tmuxDetectionGeneration) {
            return false;
          }
        }

        final bool active;
        final String? foregroundSessionName;
        try {
          foregroundSessionName = await tmux.foregroundSessionNameOrThrow(
            session,
            extraFlags: host?.tmuxExtraFlags,
          );
          active = candidateSessionName != null
              ? foregroundSessionName == candidateSessionName
              : foregroundSessionName != null;
        } on Object catch (error) {
          hadDetectionFailure = true;
          DiagnosticsLogService.instance.warning(
            'tmux.ui',
            'detection_attempt_failed',
            fields: {
              'connectionId': session.connectionId,
              'hasCandidate': candidateSessionName != null,
              'errorType': error.runtimeType,
            },
          );
          if (candidateSessionName == null &&
              !hadVisibleOrPrimedTmuxState &&
              !mayPreserveExistingTmuxState) {
            rethrow;
          }
          continue;
        }
        DiagnosticsLogService.instance.debug(
          'tmux.ui',
          'detection_attempt',
          fields: {
            'connectionId': session.connectionId,
            'active': active,
            'hasCandidate': candidateSessionName != null,
            'hasForegroundSession': foregroundSessionName != null,
          },
        );
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }
        if (!active) {
          confirmedTmuxActive = false;
          hadDetectionFailure = false;
          if (candidateSessionName == null &&
              foregroundSessionName == null &&
              !hadVisibleOrPrimedTmuxState &&
              !mayPreserveExistingTmuxState) {
            break;
          }
          continue;
        }
        confirmedTmuxActive = true;

        final sessionName = candidateSessionName ?? foregroundSessionName;
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }
        if (sessionName == null) {
          DiagnosticsLogService.instance.debug(
            'tmux.ui',
            'detection_no_session_name',
            fields: {'connectionId': session.connectionId},
          );
          continue;
        }

        final List<TmuxWindow> windows;
        try {
          windows = await tmux.listWindows(
            session,
            sessionName,
            extraFlags: host?.tmuxExtraFlags,
          );
        } on Object catch (error) {
          hadDetectionFailure = true;
          DiagnosticsLogService.instance.warning(
            'tmux.ui',
            'detection_windows_failed',
            fields: {
              'connectionId': session.connectionId,
              'errorType': error.runtimeType,
            },
          );
          continue;
        }
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }
        if (windows.isEmpty) {
          DiagnosticsLogService.instance.debug(
            'tmux.ui',
            'detection_empty_windows',
            fields: {'connectionId': session.connectionId},
          );
          continue;
        }

        // Get the active window's working directory for SFTP/path resolution.
        var tmuxLaunchCwd = preferredWorkingDirectory;
        var tmuxCwd = preferredWorkingDirectory;
        try {
          final activeWindow = windows.where((w) => w.isActive).firstOrNull;
          tmuxLaunchCwd ??= activeWindow?.currentPath;
          tmuxCwd ??= activeWindow?.currentPath;
        } on Object {
          // Non-critical — path resolution will fall back to OSC 7.
        }

        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }

        setState(() {
          _isTmuxActive = true;
          _tmuxSessionName = sessionName;
          _tmuxStateConnectionId = session.connectionId;
          _tmuxLaunchWorkingDirectory = tmuxLaunchCwd;
          _tmuxWorkingDirectory = tmuxCwd;
          _connectionOpenedWorkingDirectory ??= normalizeSftpAbsolutePath(
            tmuxLaunchCwd,
          );
        });
        _startTmuxForegroundVerification(session, sessionName);
        DiagnosticsLogService.instance.info(
          'tmux.ui',
          'detection_success',
          fields: {
            'connectionId': session.connectionId,
            'windowCount': windows.length,
          },
        );
        // Prime tmux's per-pane color cache with the active theme as soon
        // as we confirm tmux is running. Without this, an inner TUI like
        // Codex CLI that queries OSC 11 for theme detection would receive
        // whatever stale value tmux had cached (e.g., from a previous
        // attach to a different terminal), and bake the wrong composer
        // surface color into its rendered output.
        _primeTmuxTerminalTheme(session);
        await _activateInitialTmuxWindowIfNeeded(session, sessionName, windows);
        return true;
      }

      if (!mounted ||
          _connectionId != capturedConnectionId ||
          detectionGeneration != _tmuxDetectionGeneration) {
        return false;
      }

      if (shouldPreserveTerminalTmuxStateAfterDetectionFailure(
        preserveExistingTmuxState: mayPreserveExistingTmuxState,
        hadVisibleOrPrimedTmuxState: hadVisibleOrPrimedTmuxState,
        confirmedTmuxActive: confirmedTmuxActive,
        hadDetectionFailure: hadDetectionFailure,
      )) {
        final logFields = {
          'connectionId': session.connectionId,
          'confirmedTmuxActive': confirmedTmuxActive,
          'hadDetectionFailure': hadDetectionFailure,
        };
        if (hadDetectionFailure) {
          DiagnosticsLogService.instance.warning(
            'tmux.ui',
            'detection_preserved_existing',
            fields: logFields,
          );
        } else {
          DiagnosticsLogService.instance.info(
            'tmux.ui',
            'detection_preserved_existing',
            fields: logFields,
          );
        }
        return false;
      }

      if (!mayPreserveExistingTmuxState) {
        setState(_clearTmuxState);
      }
      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'detection_inactive',
        fields: {'connectionId': session.connectionId},
      );
      return false;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'detection_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      if (!mounted ||
          _connectionId != capturedConnectionId ||
          detectionGeneration != _tmuxDetectionGeneration) {
        return false;
      }
      if (shouldPreserveTerminalTmuxStateAfterDetectionFailure(
        preserveExistingTmuxState: mayPreserveExistingTmuxState,
        hadVisibleOrPrimedTmuxState: hadVisibleOrPrimedTmuxState,
        confirmedTmuxActive: confirmedTmuxActive,
        hadDetectionFailure: true,
      )) {
        DiagnosticsLogService.instance.warning(
          'tmux.ui',
          'detection_preserved_existing',
          fields: {
            'connectionId': session.connectionId,
            'confirmedTmuxActive': confirmedTmuxActive,
            'hadDetectionFailure': true,
          },
        );
        return false;
      }
      if (!mayPreserveExistingTmuxState) {
        setState(_clearTmuxState);
      }
      return false;
    }
  }

  Future<void> _activateInitialTmuxWindowIfNeeded(
    SshSession session,
    String sessionName,
    List<TmuxWindow> windows,
  ) async {
    final target = _pendingInitialTmuxWindowTarget;
    if (target == null || target.sessionName != sessionName) {
      return;
    }
    final targetWindow = target.windowId == null
        ? windows
              .where((window) => window.index == target.windowIndex)
              .firstOrNull
        : windows.where((window) => window.id == target.windowId).firstOrNull;
    if (targetWindow == null) {
      return;
    }
    _pendingInitialTmuxWindowTarget = null;
    try {
      await _switchTmuxWindow(
        session,
        targetWindow.index,
        windowId: target.windowId,
        forceVisibleTmux: target.requiresVisibleSession,
      );
    } on Exception catch (error) {
      _showTmuxActionFailure(error);
    }
  }

  String? _resolveStoredAutoConnectCommand(Host? host) {
    if (host == null) {
      return null;
    }
    if (host.autoConnectSnippetId != null) {
      return host.autoConnectCommand;
    }
    final preset = _autoConnectAgentPreset;
    if (preset == null) {
      return host.autoConnectCommand;
    }
    try {
      return buildAgentLaunchCommand(
        preset,
        startInYoloMode: _startClisInYoloMode,
      );
    } on FormatException {
      return host.autoConnectCommand;
    }
  }

  /// Wraps the terminal view in a Stack with the tmux bar overlaid.
  ///
  /// When tmux is active, the terminal gets bottom padding equal to the
  /// handle bar height so the collapsed handle sits over empty space.
  /// When expanded, the bar slides up over the terminal content.
  /// When tmux is not active, the terminal fills the entire space.
  Widget _buildTerminalWithTmuxBar(
    TerminalThemeData terminalTheme,
    bool isMobile,
    ThemeData theme,
    SshConnectionState connectionState,
  ) {
    final showTmux =
        _isTmuxActive &&
        _showTmuxBar &&
        connectionState == SshConnectionState.connected;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tmuxBarSafeInsets = resolveTmuxBarSafeInsets(
          MediaQuery.of(context),
        );
        final targetBottomPadding = showTmux
            ? _TmuxExpandableBar.handleHeight + tmuxBarSafeInsets.bottom
            : 0.0;
        final availableHeight = max(
          0,
          constraints.maxHeight - tmuxBarSafeInsets.bottom,
        ).toDouble();

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetBottomPadding),
          duration: _tmuxBarRevealDuration,
          curve: Curves.easeOutCubic,
          child: _buildTmuxExpandableBar(theme, availableHeight),
          builder: (context, animatedBottomPadding, child) {
            final barOpacity = resolveTmuxBarRevealOpacity(
              animatedBottomPadding,
            );

            return Stack(
              children: [
                // Reserve actual layout space for the collapsed handle so the
                // terminal viewport ends exactly at the handle boundary.
                Positioned.fill(
                  child: ColoredBox(
                    color: terminalTheme.background,
                    child: Column(
                      children: [
                        Expanded(
                          child: _buildTerminalView(terminalTheme, isMobile),
                        ),
                        SizedBox(height: animatedBottomPadding),
                      ],
                    ),
                  ),
                ),
                if (showTmux && _isTmuxBarExpanded)
                  Positioned.fill(
                    child: Listener(
                      key: const ValueKey('tmux-terminal-dismiss-region'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) => _collapseTmuxBarIfExpanded(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                if (showTmux || animatedBottomPadding > 0)
                  Positioned(
                    left: tmuxBarSafeInsets.left,
                    right: tmuxBarSafeInsets.right,
                    bottom: resolveTmuxBarRevealBottomOffset(
                      animatedBottomPadding,
                    ),
                    child: IgnorePointer(
                      ignoring: barOpacity == 0,
                      child: Opacity(
                        opacity: barOpacity,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// Builds the tmux expandable bar overlaid at the bottom of the terminal.
  Widget _buildTmuxExpandableBar(ThemeData theme, double availableHeight) {
    final connectionId = _connectionId;
    if (connectionId == null || _tmuxSessionName == null) {
      return const SizedBox.shrink();
    }

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return const SizedBox.shrink();

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isProUser = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );

    return _TmuxExpandableBar(
      key: _tmuxBarKey,
      session: session,
      tmuxSessionName: _tmuxSessionName!,
      tmuxExtraFlags: _host?.tmuxExtraFlags,
      availableHeight: availableHeight,
      recoveryGeneration: _tmuxBarRecoveryGeneration,
      isProUser: isProUser,
      startClisInYoloMode: _startClisInYoloMode,
      initiallyExpanded: widget.initiallyExpandTmuxWindows,
      ref: ref,
      onAction: _handleTmuxAction,
      onExpandedChanged: _handleTmuxBarExpandedChanged,
      onWindowLoadStalled: _recoverTmuxWindowPanel,
      scopeWorkingDirectory: resolveTmuxAiSessionScopeWorkingDirectory(
        liveTerminalWorkingDirectory: _liveWorkingDirectoryPath,
        tmuxWorkingDirectory: _tmuxWorkingDirectory,
        sessionWorkingDirectory: session.workingDirectory,
      ),
    );
  }

  void _handleTmuxBarExpandedChanged(bool expanded) {
    if (_isTmuxBarExpanded == expanded || !mounted) {
      return;
    }
    setState(() => _isTmuxBarExpanded = expanded);
  }

  bool _collapseTmuxBarIfExpanded() {
    if (!_isTmuxBarExpanded) {
      return false;
    }
    final collapsed = _tmuxBarKey.currentState?.collapseIfExpanded() ?? false;
    if (!collapsed && mounted) {
      setState(() => _isTmuxBarExpanded = false);
    }
    return true;
  }

  /// Handles an action from the draggable tmux panel.
  Future<void> _handleTmuxAction(TmuxNavigatorAction action) async {
    final connectionId = _connectionId;
    if (connectionId == null) return;
    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return;

    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'navigator_action',
      fields: {
        'connectionId': connectionId,
        'action': diagnosticTmuxNavigatorActionKind(action),
      },
    );
    await _performTmuxNavigatorAction(session, action);
  }

  Future<void> _recoverTmuxWindowPanel(
    SshSession session,
    String sessionName,
  ) async {
    if (!mounted ||
        _connectionId != session.connectionId ||
        _tmuxSessionName != sessionName) {
      return;
    }

    final recovered = await _detectTmux(
      session,
      preserveExistingTmuxState: true,
    );
    if (!mounted ||
        _connectionId != session.connectionId ||
        !_isTmuxActive ||
        _tmuxSessionName != sessionName) {
      return;
    }
    if (!recovered) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_recovery_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }

    setState(() => _tmuxBarRecoveryGeneration += 1);
  }

  /// Opens the tmux window navigator bottom sheet and handles the
  /// selected action.
  Future<void> _openTmuxNavigator() async {
    final connectionId = _connectionId;
    if (connectionId == null || _tmuxSessionName == null) return;

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return;

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isProUser = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );

    final action = await showTmuxNavigator(
      context: context,
      ref: ref,
      session: session,
      tmuxSessionName: _tmuxSessionName!,
      tmuxExtraFlags: _host?.tmuxExtraFlags,
      isProUser: isProUser,
      startClisInYoloMode: _startClisInYoloMode,
      scopeWorkingDirectory: resolveTmuxAiSessionScopeWorkingDirectory(
        liveTerminalWorkingDirectory: _liveWorkingDirectoryPath,
        tmuxWorkingDirectory: _tmuxWorkingDirectory,
        sessionWorkingDirectory: session.workingDirectory,
      ),
    );

    if (!mounted || action == null) return;

    await _performTmuxNavigatorAction(session, action);
  }

  Future<void> _performTmuxNavigatorAction(
    SshSession session,
    TmuxNavigatorAction action,
  ) async {
    try {
      switch (action) {
        case TmuxSwitchWindowAction(:final windowIndex):
          await _switchTmuxWindow(session, windowIndex);
        case TmuxNewWindowAction(:final command, :final windowName):
          await _createTmuxWindow(session, command: command, name: windowName);
        case TmuxResumeSessionAction(
          :final resumeCommand,
          :final workingDirectory,
        ):
          await _createTmuxWindow(
            session,
            command: resumeCommand,
            workingDirectory: workingDirectory,
          );
        case TmuxCloseWindowAction(:final windowIndex):
          await _closeTmuxWindow(session, windowIndex);
      }
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'navigator_action_failed',
        fields: {
          'connectionId': session.connectionId,
          'action': diagnosticTmuxNavigatorActionKind(action),
          'errorType': error.runtimeType,
        },
      );
      _showTmuxActionFailure(error);
    }
  }

  void _showTmuxActionFailure(Exception error) {
    if (!mounted) return;
    final message = switch (error) {
      TimeoutException() =>
        'Timed out waiting for tmux. Reconnect if actions keep failing.',
      _ => 'tmux action failed. Check the session and try again.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Switches to a different tmux window via exec channel.
  ///
  /// Uses an exec channel (not the interactive shell) because
  /// `tmux select-window` is a server operation — the tmux server
  /// notifies all attached clients of the change. Writing to the PTY
  /// would inject the command as input to whatever program is running.
  Future<void> _switchTmuxWindow(
    SshSession session,
    int windowIndex, {
    String? windowId,
    bool forceVisibleTmux = false,
  }) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    final tmux = ref.read(tmuxServiceProvider);
    final targetWindowId = windowId != null && isValidTmuxWindowId(windowId)
        ? windowId
        : null;
    if (targetWindowId == null) {
      await tmux.selectWindow(
        session,
        sessionName,
        windowIndex,
        extraFlags: _host?.tmuxExtraFlags,
      );
    } else {
      await tmux.selectWindow(
        session,
        sessionName,
        windowIndex,
        windowId: targetWindowId,
        extraFlags: _host?.tmuxExtraFlags,
      );
    }

    // Clear stale working directory — it will be refreshed from
    // OSC 7 or the next tmux query.
    _tmuxWorkingDirectory = null;
    await _reattachTmuxIfNeeded(
      session,
      sessionName,
      forceVisibleTmux: forceVisibleTmux,
    );
    _scheduleTerminalSizeRefresh();
  }

  /// Creates a new tmux window via exec channel, then reattaches the visible
  /// terminal if tmux is no longer in the foreground there.
  ///
  /// Prefers the tmux session's current pane directory so "new window" starts
  /// where the user is actually working, while still preserving explicit
  /// working-directory overrides (e.g. resuming an AI session).
  Future<void> _createTmuxWindow(
    SshSession session, {
    String? command,
    String? name,
    String? workingDirectory,
  }) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    final tmux = ref.read(tmuxServiceProvider);
    String? currentPaneWorkingDirectory;
    if (!(workingDirectory?.trim().isNotEmpty ?? false)) {
      currentPaneWorkingDirectory = await tmux.currentPanePath(
        session,
        sessionName,
        extraFlags: _host?.tmuxExtraFlags,
      );
    }
    if (!mounted) return;
    final resolvedWorkingDirectory = resolveTmuxWindowWorkingDirectory(
      explicitWorkingDirectory: workingDirectory,
      currentPaneWorkingDirectory: currentPaneWorkingDirectory,
      observedWorkingDirectory: _tmuxWorkingDirectory ?? _workingDirectoryPath,
      launchWorkingDirectory: _tmuxLaunchWorkingDirectory,
      hostWorkingDirectory: _host?.tmuxWorkingDirectory,
    );
    await tmux.createWindow(
      session,
      sessionName,
      command: command,
      name: name,
      workingDirectory: resolvedWorkingDirectory,
      extraFlags: _host?.tmuxExtraFlags,
    );
    _tmuxWorkingDirectory = resolvedWorkingDirectory;
    await _reattachTmuxIfNeeded(session, sessionName);
    _scheduleTerminalSizeRefresh();
  }

  /// Closes a tmux window via exec channel.
  Future<void> _closeTmuxWindow(SshSession session, int windowIndex) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    await ref
        .read(tmuxServiceProvider)
        .killWindow(
          session,
          sessionName,
          windowIndex,
          extraFlags: _host?.tmuxExtraFlags,
        );
    _scheduleTerminalSizeRefresh();
  }

  Future<void> _reattachTmuxIfNeeded(
    SshSession session,
    String sessionName, {
    bool forceVisibleTmux = false,
  }) async {
    final tmux = ref.read(tmuxServiceProvider);
    var hasForegroundClient = false;
    try {
      hasForegroundClient = await tmux.hasForegroundClientOrThrow(
        session,
        sessionName,
        extraFlags: _host?.tmuxExtraFlags,
      );
    } on Exception catch (error) {
      if (!forceVisibleTmux) {
        DiagnosticsLogService.instance.warning(
          'tmux.ui',
          'reattach_foreground_check_failed',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        return;
      }
      hasForegroundClient = false;
    }
    if (!mounted || hasForegroundClient) {
      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'reattach_not_needed',
        fields: {
          'connectionId': session.connectionId,
          'hasForegroundClient': hasForegroundClient,
        },
      );
      return;
    }

    final canReattachInCurrentShell = shouldReattachTmuxAfterWindowAction(
      hasForegroundClient: hasForegroundClient,
      shellStatus: _shellStatus,
    );
    if (!canReattachInCurrentShell && !forceVisibleTmux) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'tmux updated $sessionName, but this terminal is not safely at '
            'a shell prompt.',
          ),
        ),
      );
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'reattach_skipped_shell_not_prompt',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }

    if (forceVisibleTmux && !canReattachInCurrentShell) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Opening tmux alert interrupted the running shell command.',
          ),
        ),
      );
    }

    final shell = forceVisibleTmux && !canReattachInCurrentShell
        ? await _reopenShellForVisibleTmux(session)
        : _shell;
    if (shell == null) {
      return;
    }

    final host = _host;
    final reattachCommand = buildTmuxCommand(
      sessionName: sessionName,
      workingDirectory: host?.tmuxWorkingDirectory,
      extraFlags: host?.tmuxExtraFlags,
    );
    shell.write(utf8.encode(formatAutoConnectCommandForShell(reattachCommand)));
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'reattach_command_sent',
      fields: {'connectionId': session.connectionId},
    );
  }

  Future<SSHSession?> _reopenShellForVisibleTmux(SshSession session) async {
    bool stillOwnsSession() => mounted && _connectionId == session.connectionId;

    final previousTerminal = _terminal;
    final previousTerminalHyperlinkTracker = _terminalHyperlinkTracker;
    final previousIsUsingAltBuffer = _isUsingAltBuffer;
    final previousTerminalReportsMouseWheel = _terminalReportsMouseWheel;
    final previousShell = _shell;
    var removedTerminalListener = false;
    var closedExistingShell = false;

    void restorePreviousTerminalState({required bool restoreShell}) {
      _terminal = previousTerminal;
      _terminalHyperlinkTracker = previousTerminalHyperlinkTracker;
      _isUsingAltBuffer = previousIsUsingAltBuffer;
      _terminalReportsMouseWheel = previousTerminalReportsMouseWheel;
      if (removedTerminalListener) {
        _terminal.addListener(_onTerminalStateChanged);
        removedTerminalListener = false;
      }
      if (restoreShell) {
        _shell = previousShell;
      }
    }

    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    unawaited(_shellStdoutSubscription?.cancel());
    _shellStdoutSubscription = null;
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = null;

    final pty = SSHPtyConfig(
      width: _terminal.viewWidth,
      height: _terminal.viewHeight,
    );

    final SSHSession shell;
    try {
      _terminal.removeListener(_onTerminalStateChanged);
      removedTerminalListener = true;
      _shell = null;

      await session.closeShell(waitForStreams: false);
      closedExistingShell = true;
      if (!stillOwnsSession()) {
        restorePreviousTerminalState(restoreShell: false);
        return null;
      }

      _applyTerminalThemeToSession(
        _resolveEffectiveTerminalTheme(),
        session: session,
        reason: 'reopen_shell',
      );
      shell = await session.getShell(pty: pty);
      if (!stillOwnsSession()) {
        restorePreviousTerminalState(restoreShell: false);
        return null;
      }
      final terminal = session.terminal;
      if (terminal == null) {
        return null;
      }

      _terminal = terminal;
      _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      _terminal.addListener(_onTerminalStateChanged);
      removedTerminalListener = false;
      _shell = shell;
      _wireTerminalCallbacks(session);
    } on Object {
      restorePreviousTerminalState(restoreShell: !closedExistingShell);
      rethrow;
    }

    if (!stillOwnsSession()) {
      return null;
    }
    final sharedClipboardEnabled = await ref.read(
      sharedClipboardProvider.future,
    );
    if (!stillOwnsSession()) {
      return null;
    }
    final sharedClipboardLocalReadEnabled = await ref.read(
      sharedClipboardLocalReadProvider.future,
    );
    if (!stillOwnsSession()) {
      return null;
    }
    await _applySharedClipboardSetting(
      enabled: sharedClipboardEnabled,
      allowLocalClipboardRead: sharedClipboardLocalReadEnabled,
      session: session,
      waitForInitialSync: false,
    );
    if (!stillOwnsSession()) {
      return null;
    }
    if (mounted) {
      setState(() {
        _isUsingAltBuffer = _terminal.isUsingAltBuffer;
        _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      });
      _scheduleTerminalSizeRefresh();
    }
    return shell;
  }

  void _handleTrackedConnectionStateChange(
    SshConnectionState? previous,
    SshConnectionState next,
  ) {
    final connectionId = _connectionId;
    if (connectionId == null) {
      _syncTerminalWakeLock(SshConnectionState.disconnected);
      return;
    }

    final previousState = previous ?? SshConnectionState.disconnected;
    final nextState = next;
    _syncTerminalWakeLock(nextState);
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
      _clearTmuxState();
      _isConnecting = false;
      _error ??= 'Connection closed';
    });
  }

  void _handleShellClosed() {
    final connectionId = _connectionId;
    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    _syncTerminalWakeLock(SshConnectionState.disconnected);
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
        _clearTmuxState();
        _isConnecting = false;
        _error = 'Connection closed';
      });
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    }
    // Clean up the session state regardless of background/foreground.
    if (connectionId != null) {
      ref.read(tmuxServiceProvider).clearCache(connectionId);
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
    _clearAppThemeOverride();
    _syncTerminalWakeLock(SshConnectionState.disconnected);
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    _shell = null;
    if (connectionId != null) {
      ref.read(tmuxServiceProvider).clearCache(connectionId);
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
        _clearTmuxState();
        _isConnecting = true;
        _error = null;
      });
    } else {
      _clearTmuxState();
      _isConnecting = true;
      _error = null;
    }

    final previousConnectionId = _connectionId;
    _connectionId = null;
    _clearAppThemeOverride();
    _syncTerminalWakeLock(SshConnectionState.disconnected);
    _connectionLostWhileBackgrounded = false;
    try {
      await _doneSubscription?.cancel();
      _doneSubscription = null;
      _shell = null;
      if (previousConnectionId != null) {
        ref.read(tmuxServiceProvider).clearCache(previousConnectionId);
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
    _clearAppThemeOverride();
    _sharedClipboardSubscription.close();
    _sharedClipboardLocalReadSubscription.close();
    _terminalWakeLockSubscription.close();
    _terminalThemeSettingsSubscription.close();
    _themeModeSubscription.close();
    _cancelTerminalThemeRefreshTimers();
    _sessionController.dispose();
    _stopSharedClipboardSync();
    _stopTmuxForegroundVerification();
    _promptOutputImeResetTimer?.cancel();
    _disposeTerminalPathVerificationSftp();
    _terminal
      ..removeListener(_onTerminalStateChanged)
      ..onOutput = null
      ..onResize = null;
    _terminalController
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _terminalScrollController
      ..removeListener(_handleTerminalScroll)
      ..dispose();
    _nativeSelectionScrollController
      ..removeListener(_syncTerminalScrollFromNative)
      ..dispose();
    _nativeSelectionController
      ..removeListener(_onNativeOverlayControllerChanged)
      ..dispose();
    _nativeOverlayCollapseTimer?.cancel();
    _nativeSelectionFocusNode.dispose();
    _doneSubscription?.cancel();
    _shellStdoutSubscription?.cancel();
    _terminalFocusNode.dispose();
    _toolbarController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _wasBackgrounded = true;
      _stopSharedClipboardSync();
      _syncTerminalWakeLock();
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      _syncTerminalWakeLock();
      _scheduleTerminalSizeRefresh();
      final session = _observedSession;
      if (session != null && session.clipboardSharingEnabled) {
        unawaited(_startSharedClipboardSync(session));
      }
      if (_connectionLostWhileBackgrounded && mounted) {
        _connectionLostWhileBackgrounded = false;
        _terminal.write('\r\n[reconnecting...]\r\n');
        _reconnect();
      } else if (session != null) {
        unawaited(
          _reloadTerminalThemeForDependencies(
            forceRemoteRefresh: true,
            reason: 'app_resumed',
          ),
        );
      }
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    _handleTerminalThemeDependenciesChanged(
      forceRemoteRefresh: true,
      reason: 'platform_brightness_changed',
    );
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _scheduleTerminalSizeRefresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload theme when system brightness changes
    final brightness = _resolveTerminalThemeBrightness();
    final didBrightnessChange = _lastThemeDependencyBrightness != brightness;
    _lastThemeDependencyBrightness = brightness;
    if (_currentTheme == null) {
      return;
    }
    if (!didBrightnessChange) {
      return;
    }
    _handleTerminalThemeDependenciesChanged(
      forceRemoteRefresh: true,
      reason: 'dependencies_brightness_changed',
    );
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
    ref.listen<SshConnectionState>(
      activeSessionsProvider.select(_selectTrackedConnectionState),
      _handleTrackedConnectionStateChange,
    );
    final theme = Theme.of(context);
    final connectionState = ref.watch(
      activeSessionsProvider.select(_selectTrackedConnectionState),
    );
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final systemKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;

    // Use session override, or loaded theme, or fallback.
    final terminalTheme = _resolveEffectiveTerminalTheme();
    // Only push the theme to the session when it differs from what was last
    // applied via this path.  Explicit callers (_openShell, _loadTheme, etc.)
    // use their own call sites and do not update _lastBuildAppliedTheme, so
    // a theme change from those paths will still trigger one build-path call
    // on the next rebuild.
    if (!_sameTerminalTheme(terminalTheme, _lastBuildAppliedTheme)) {
      _lastBuildAppliedTheme = terminalTheme;
      _applyTerminalThemeToSession(terminalTheme, reason: 'build');
    }
    final connectionLabel = describeTerminalConnectionState(
      connectionState,
      isConnecting: _isConnecting,
    );
    final connectionIdentity = formatTerminalConnectionIdentity(
      username: _redactStoreScreenshotIdentities ? 'store' : _host?.username,
      hostname: _redactStoreScreenshotIdentities
          ? 'local-demo'
          : _host?.hostname,
      port: _redactStoreScreenshotIdentities ? null : _host?.port,
      connectionId: _connectionId,
    );
    final titleSubtitleSegments = <String>[];
    if (connectionIdentity != null) {
      titleSubtitleSegments.add(connectionIdentity);
    }
    if ((_iconName ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_iconName!);
    }
    if ((_windowTitle ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_windowTitle!);
    }
    final titleSubtitle = titleSubtitleSegments.join(' • ');
    final statusChips = _buildTerminalStatusChips(theme);

    return PopScope(
      canPop: !_isTmuxBarExpanded,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        _collapseTmuxBarIfExpanded();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _host?.label ?? 'Terminal',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _TerminalConnectionStatusIcon(
                    label: connectionLabel,
                    state: connectionState,
                    isConnecting: _isConnecting,
                  ),
                ],
              ),
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
            if (_isTmuxActive &&
                !_showTmuxBar &&
                connectionState == SshConnectionState.connected)
              IconButton(
                icon: const Icon(Icons.window_outlined),
                onPressed: _connectionId == null ? null : _openTmuxNavigator,
                tooltip: 'tmux windows',
              ),
            IconButton(
              icon: const Icon(Icons.folder_outlined),
              onPressed:
                  _connectionId == null ||
                      connectionState != SshConnectionState.connected
                  ? null
                  : () => unawaited(_openConnectionFileBrowser()),
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
              icon: _ExtraKeysToggleKeycap(
                key: ValueKey<String>(
                  _showKeyboardToolbar
                      ? 'extra-keys-toggle-active'
                      : 'extra-keys-toggle-inactive',
                ),
                isActive: _showKeyboardToolbar,
              ),
              onPressed: () =>
                  setState(() => _showKeyboardToolbar = !_showKeyboardToolbar),
              tooltip: _showKeyboardToolbar
                  ? 'Hide extra keys'
                  : 'Show extra keys',
            ),
            PopupMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'snippets',
                  child: Row(
                    children: [
                      Icon(Icons.code_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Snippets'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'change_theme',
                  child: Row(
                    children: [
                      Icon(Icons.palette_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Change Theme'),
                    ],
                  ),
                ),
                if (statusChips.isNotEmpty)
                  PopupMenuItem(
                    value: 'toggle_terminal_info',
                    child: Row(
                      children: [
                        Icon(
                          _showsTerminalMetadata
                              ? Icons.info_outlined
                              : Icons.info_outline_rounded,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _showsTerminalMetadata
                              ? 'Hide Terminal Info'
                              : 'Show Terminal Info',
                        ),
                      ],
                    ),
                  ),
                if (_isTmuxActive)
                  PopupMenuItem(
                    value: 'toggle_tmux_bar',
                    child: Row(
                      children: [
                        Icon(
                          _showTmuxBar
                              ? Icons.window_outlined
                              : Icons.window_rounded,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(_showTmuxBar ? 'Hide tmux Bar' : 'Show tmux Bar'),
                      ],
                    ),
                  ),
                if (isMobile)
                  CheckedPopupMenuItem(
                    value: 'toggle_tap_keyboard',
                    checked: ref.read(tapToShowKeyboardNotifierProvider),
                    child: const Text('Tap to Show Keyboard'),
                  ),
                const PopupMenuDivider(),
                if (!isMobile)
                  PopupMenuItem(
                    value: 'native_select',
                    child: Row(
                      children: [
                        Icon(
                          _isNativeSelectionMode
                              ? Icons.deselect_rounded
                              : Icons.select_all_rounded,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _isNativeSelectionMode
                              ? 'Exit Native Selection'
                              : 'Native Selection',
                        ),
                      ],
                    ),
                  ),
                if (_workingDirectoryPath != null)
                  const PopupMenuItem(
                    value: 'copy_working_directory',
                    child: Row(
                      children: [
                        Icon(Icons.folder_copy_outlined, size: 20),
                        SizedBox(width: 12),
                        Text('Copy Current Directory'),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'paste',
                  child: Row(
                    children: [
                      Icon(Icons.paste_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Paste'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'paste_image',
                  child: Row(
                    children: [
                      Icon(Icons.image_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Paste Images'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'paste_file',
                  child: Row(
                    children: [
                      Icon(Icons.attach_file_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Paste Files'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'disconnect',
                  child: Row(
                    children: [
                      Icon(Icons.link_off_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Disconnect'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Builder(
          builder: (bodyContext) {
            final showsKeyboardToolbar =
                _showKeyboardToolbar &&
                !showsDisconnectedOverlay &&
                (!_isNativeSelectionMode || _isMobilePlatform);
            final terminalArea = _buildTerminalWithTmuxBar(
              terminalTheme,
              isMobile,
              theme,
              connectionState,
            );
            return Column(
              children: [
                Expanded(
                  // The KeyboardToolbar below already absorbs the bottom
                  // safe-area inset via its own SafeArea, so strip it here to
                  // prevent the tmux bar from floating above the toolbar.
                  child: showsKeyboardToolbar
                      ? MediaQuery.removePadding(
                          context: bodyContext,
                          removeBottom: true,
                          child: terminalArea,
                        )
                      : terminalArea,
                ),
                if (showsKeyboardToolbar)
                  KeyboardToolbar(
                    controller: _toolbarController,
                    terminal: _terminal,
                    onKeyPressed: _handleKeyboardToolbarKeyPressed,
                    onPasteRequested: _pasteClipboard,
                    onPasteImageRequested: _pastePickedImage,
                    onPasteFilesRequested: _pastePickedFiles,
                    terminalFocusNode: _terminalFocusNode,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Toggles the system keyboard visibility on mobile platforms.
  void _toggleSystemKeyboard(bool isVisible) {
    if (isVisible) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    } else {
      // Explicit user action — always show the keyboard regardless of the
      // tap-to-show setting.
      _restoreTerminalFocus(forceShowSystemKeyboard: true);
    }
  }

  /// Restores focus to the terminal after a UI interaction.
  ///
  /// When [showSystemKeyboard] is `true` the soft keyboard is shown only if
  /// the tap-to-show-keyboard setting permits it.  Use
  /// [forceShowSystemKeyboard] to bypass the setting (e.g. the explicit
  /// toolbar keyboard toggle).
  void _restoreTerminalFocus({
    bool showSystemKeyboard = false,
    bool forceShowSystemKeyboard = false,
  }) {
    if (!mounted) {
      return;
    }
    _dismissNativeSelectionOverlayForEditing();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _terminalFocusNode.requestFocus();
      final shouldShowKeyboard =
          forceShowSystemKeyboard ||
          (showSystemKeyboard && ref.read(tapToShowKeyboardNotifierProvider));
      if (shouldShowKeyboard && _isMobilePlatform) {
        _terminalTextInputController.requestKeyboard();
      }
    });
  }

  void _handleKeyboardToolbarKeyPressed() {
    _followLiveOutput();
    _terminalTextInputController.clearImeBuffer();
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

  Widget _buildTerminalTransientIndicator({
    required ThemeData theme,
    required String label,
  }) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );

  Future<void> _showThemePicker() async {
    final currentId = _sessionThemeOverride?.id ?? _currentTheme?.id;
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );

    if (theme != null && mounted) {
      final isDark = _resolveTerminalThemeBrightness() == Brightness.dark;
      final monetizationState =
          ref.read(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final hasHostThemeAccess = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );
      final connectionId = _connectionId;
      var hasSession = false;
      if (connectionId != null) {
        final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
        final session =
            (sessionsNotifier
                  ..updateSessionTheme(connectionId, theme.id, isDark: isDark))
                .getSession(connectionId);
        if (session != null) {
          hasSession = true;
          _syncAppThemeOverrideFromSession(session);
        }
      }
      setState(() => _sessionThemeOverride = theme);
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'picker_selected',
        fields: {
          'connectionId': connectionId,
          'isDark': isDark,
          'hasHostThemeAccess': hasHostThemeAccess,
          'hasSession': hasSession,
        },
      );
      _applyTerminalThemeToSession(
        theme,
        forceRemoteRefresh: true,
        reason: 'theme_picker',
      );

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
                    child: Text(
                      hasHostThemeAccess
                          ? 'Save to Host'
                          : 'Save to Host (Pro)',
                    ),
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
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.hostSpecificThemes,
      blockedAction: 'Save this theme to the host',
      blockedOutcome:
          'Unlock Pro to keep this host on the selected terminal theme.',
    );
    if (!hasAccess || !mounted) {
      return;
    }

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
    final routeTouchScrollToTerminal = _routesTouchScrollToTerminal;
    final terminalPathLinksEnabled = ref.watch(
      terminalPathLinksNotifierProvider,
    );
    final terminalPathLinkUnderlinesEnabled = ref.watch(
      terminalPathLinkUnderlinesNotifierProvider,
    );
    final showsTerminalPathUnderlines =
        terminalPathLinksEnabled && terminalPathLinkUnderlinesEnabled;
    final inlineUnderlines = showsTerminalPathUnderlines
        ? _isMobilePlatform
              ? [
                  for (final underline in _visibleTerminalPathUnderlines)
                    underline.underline,
                ]
              : <TerminalTextUnderline>[?_hoveredTerminalPathUnderline]
        : const <TerminalTextUnderline>[];
    final keyboardAppearance = resolveTerminalKeyboardAppearance(terminalTheme);
    Widget terminalView = MonkeyTerminalView(
      key: _terminalViewKey,
      _terminal,
      controller: _terminalController,
      scrollController: _terminalScrollController,
      resolveLinkTap: _resolveTerminalLinkTap,
      onLinkTapDown: _handleTerminalLinkTapDown,
      onLinkTap: _handleTerminalLinkTap,
      suppressLongPressDragSelection: isMobile,
      liveOutputAutoScroll: _terminalLiveOutputAutoScrollEnabled,
      useSystemSelection: isMobile,
      systemSelectionContextMenuBuilder: isMobile
          ? _buildTerminalSelectionContextMenu
          : null,
      focusNode: _terminalFocusNode,
      theme: terminalTheme.toXtermTheme(),
      textStyle: terminalTextStyle,
      inlineUnderlines: inlineUnderlines,
      keyboardAppearance: keyboardAppearance,
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

    if (_lastShowsTerminalPathUnderlines != showsTerminalPathUnderlines) {
      _lastShowsTerminalPathUnderlines = showsTerminalPathUnderlines;
      _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild =
          showsTerminalPathUnderlines;
    }
    if (!showsTerminalPathUnderlines && _hoveredTerminalPathUnderline != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hoveredTerminalPathUnderline == null) {
          return;
        }
        setState(() => _hoveredTerminalPathUnderline = null);
      });
    }
    if (!showsTerminalPathUnderlines &&
        _isMobilePlatform &&
        _visibleTerminalPathUnderlines.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _visibleTerminalPathUnderlines.isEmpty) {
          return;
        }
        setState(
          () => _visibleTerminalPathUnderlines =
              const <
                ({String path, TerminalTextUnderline underline, Rect touchRect})
              >[],
        );
      });
    }
    if (isMobile || terminalPathLinksEnabled) {
      terminalView = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleTerminalPointerDown,
        onPointerMove: _handleTerminalPointerMove,
        onPointerUp: _handleTerminalPointerUp,
        onPointerCancel: _handleTerminalPointerCancel,
        child: terminalView,
      );
    }
    if (showsTerminalPathUnderlines) {
      if (_isMobilePlatform) {
        if (_shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild) {
          _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = false;
          _queueVisibleTerminalPathUnderlineRefresh();
        }
      } else {
        terminalView = MouseRegion(
          onHover: _handleTerminalPathHover,
          onExit: (_) => _clearHoveredTerminalPathUnderline(),
          child: terminalView,
        );
      }
    }

    if (isMobile) {
      terminalView = TextSelectionTheme(
        data: TextSelectionTheme.of(context).copyWith(
          selectionColor: terminalTheme.readableSelection,
          selectionHandleColor: terminalTheme.cursor,
        ),
        child: terminalView,
      );
    }

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

    var mobileTerminalView = terminalView;

    if (_isPinchZooming) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          Positioned(
            top: 12,
            right: 12,
            child: _buildTerminalTransientIndicator(
              theme: theme,
              label: '${fontSize.toStringAsFixed(0)} pt',
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
      keyboardAppearance: keyboardAppearance,
      onUserInput: _followLiveOutput,
      onReviewInsertedText: _confirmKeyboardInsertion,
      buildReviewTextForInsertedText: _terminalCommandAfterInputDelta,
      resolveTextBeforeCursor: _terminalTextBeforeCursor,
      resolveTerminalKeyModifiers: () => (
        ctrl: _toolbarController.isCtrlActive,
        alt: _toolbarController.isAltActive,
        shift: _toolbarController.isShiftActive,
      ),
      consumeTerminalKeyModifiers: _toolbarController.consumeOneShot,
      applyTerminalTextInputModifiers:
          _toolbarController.applySystemKeyboardModifiers,
      hasActiveToolbarModifier: () =>
          _toolbarController.isCtrlActive || _toolbarController.isAltActive,
      readOnly: _showsNativeSelectionOverlay || overlayMessage != null,
      tapToShowKeyboard:
          ref.watch(tapToShowKeyboardNotifierProvider) &&
          !_showsNativeSelectionOverlay &&
          overlayMessage == null,
      showKeyboardOnFocus: false,
      manageFocus: false,
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

  Widget _buildTerminalSelectionContextMenu(
    BuildContext _,
    SelectableRegionState selectableRegionState,
  ) {
    final buttonItems = buildNativeSelectionContextMenuButtonItems(
      defaultItems: selectableRegionState.contextMenuButtonItems,
      onPaste: () {
        selectableRegionState.hideToolbar();
        unawaited(_pasteClipboard());
      },
    );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  /// Resolves the terminal text style for the given font family and size.
  TerminalStyle _getTerminalTextStyle(String fontFamily, double fontSize) {
    final textStyle = resolveMonospaceTextStyle(
      fontFamily,
      platform: Theme.of(context).platform,
      fontSize: fontSize,
    );
    return TerminalStyle.fromTextStyle(textStyle);
  }

  Future<void> _openConnectionFileBrowser() async {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }

    final tmuxPaneDirectory = await _resolveCurrentTmuxPaneDirectory();
    if (!mounted) {
      return;
    }

    // Prefer the last browser directory when opening from the toolbar. The
    // terminal cwd remains available for relative path resolution and as a
    // quick-jump inside the browser.
    final cwd = _workingDirectoryPath;
    final rememberedPath = ref.read(
      sftpBrowserLastPathsProvider,
    )[(hostId: widget.hostId, connectionId: connectionId)];
    final initialPath = rememberedPath ?? cwd;
    unawaited(
      context.pushNamed<String>(
        Routes.sftp,
        pathParameters: {'hostId': widget.hostId.toString()},
        queryParameters: _buildSftpBrowserQueryParameters(
          connectionId: connectionId,
          initialPath: initialPath,
          workingDirectory: cwd,
          tmuxPaneDirectory: tmuxPaneDirectory,
        ),
      ),
    );
  }

  Map<String, String> _buildSftpBrowserQueryParameters({
    int? connectionId,
    String? initialPath,
    String? workingDirectory,
    String? tmuxPaneDirectory,
  }) {
    final queryParameters = <String, String>{};

    void addParameter(String key, String? value) {
      if (value == null) {
        return;
      }
      queryParameters[key] = value;
    }

    addParameter('connectionId', connectionId?.toString());
    addParameter('path', initialPath);
    addParameter('cwd', workingDirectory);
    addParameter('connectionCwd', _connectionOpenedWorkingDirectory);
    addParameter('tmuxCwd', tmuxPaneDirectory);

    return queryParameters;
  }

  Future<String?> _resolveCurrentTmuxPaneDirectory() async {
    final fallbackDirectory = normalizeSftpAbsolutePath(_tmuxWorkingDirectory);
    final connectionId = _connectionId;
    final sessionName = _tmuxSessionName;
    if (!_isTmuxActive || connectionId == null || sessionName == null) {
      return fallbackDirectory;
    }

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) {
      return fallbackDirectory;
    }

    final paneDirectory = normalizeSftpAbsolutePath(
      await ref
          .read(tmuxServiceProvider)
          .currentPanePath(
            session,
            sessionName,
            extraFlags: _host?.tmuxExtraFlags,
          ),
    );
    if (paneDirectory == null) {
      return fallbackDirectory;
    }
    if (mounted && paneDirectory != _tmuxWorkingDirectory) {
      setState(() => _tmuxWorkingDirectory = paneDirectory);
    }
    return paneDirectory;
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
      case 'toggle_tmux_bar':
        final shouldShowTmuxBar = !_showTmuxBar;
        if (!shouldShowTmuxBar) {
          _collapseTmuxBarIfExpanded();
        }
        setState(() => _showTmuxBar = shouldShowTmuxBar);
        break;
      case 'toggle_tap_keyboard':
        final notifier = ref.read(tapToShowKeyboardNotifierProvider.notifier);
        await notifier.setEnabled(
          enabled: !ref.read(tapToShowKeyboardNotifierProvider),
        );
        break;
      case 'native_select':
        _toggleNativeSelectionMode();
        break;
      case 'copy_working_directory':
        await _copyWorkingDirectory();
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
            textLength: snapshot.textLength,
          );
    _enterNativeSelectionModeWithSnapshot((
      originCellOffset:
          initialRange?.normalized.begin ?? const CellOffset(0, 0),
      text: snapshot.text,
      selection: selection,
      lineStarts: snapshot.lineStarts,
      columnOffsets: snapshot.columnOffsets,
      lineCount: snapshot.lineCount,
      viewWidth: snapshot.viewWidth,
      textLength: snapshot.textLength,
      revealOverlayInTouchScrollMode: revealOverlayInTouchScrollMode,
    ));
  }

  void _enterNativeSelectionModeWithSnapshot(
    _PendingTouchSelectionSnapshot snapshot,
  ) {
    _nativeSelectionController.value = TextEditingValue(
      text: snapshot.text,
      selection: snapshot.selection,
    );
    _hadNativeOverlaySelection = hasActiveNativeOverlaySelection(
      snapshot.selection,
    );
    _nativeOverlayCollapseTimer?.cancel();
    setState(() {
      _isNativeSelectionMode = true;
      _revealsNativeSelectionOverlayInTouchScrollMode =
          _revealsNativeSelectionOverlayInTouchScrollMode ||
          snapshot.revealOverlayInTouchScrollMode;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isNativeSelectionMode) {
        return;
      }
      _syncNativeScrollFromTerminal(force: true);
      _nativeSelectionFocusNode.requestFocus();
      if (!_nativeSelectionController.selection.isCollapsed) {
        _nativeSelectionController.selection = snapshot.selection;
      }
    });
    if (_terminalController.selection != null) {
      _terminalController.clearSelection();
    }
  }

  void _exitNativeSelectionMode() {
    if (_isMobilePlatform) {
      return;
    }
    _nativeSelectionFocusNode.unfocus();
    setState(() {
      _isNativeSelectionMode = false;
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    _hadNativeOverlaySelection = false;
    _nativeOverlayCollapseTimer?.cancel();
    _terminalFocusNode.requestFocus();
  }

  void _refreshNativeOverlayText({required bool preserveSelection}) {
    if (!_isNativeSelectionMode) {
      return;
    }
    final snapshot = _buildNativeSelectionSnapshotData();
    final previousSelection = _nativeSelectionController.selection;
    final maxOffset = snapshot.textLength;
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

  _NativeSelectionSnapshotData _buildNativeSelectionSnapshotData() {
    final cachedSnapshot = _nativeSelectionSnapshotCache;
    if (cachedSnapshot != null) {
      return cachedSnapshot;
    }

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

    final snapshot = (
      text: builder.toString(),
      lineStarts: lineStarts,
      columnOffsets: lineColumnOffsets,
      lineCount: buffer.height,
      viewWidth: buffer.viewWidth,
      textLength: builder.length,
    );
    _nativeSelectionSnapshotCache = snapshot;
    return snapshot;
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

  void _onNativeOverlayControllerChanged() {
    if (!mounted || !_isNativeSelectionMode) {
      return;
    }
    final selection = _nativeSelectionController.selection;
    if (!selection.isValid) {
      return;
    }
    if (hasActiveNativeOverlaySelection(selection)) {
      _hadNativeOverlaySelection = true;
      _nativeOverlayCollapseTimer?.cancel();
      return;
    }
    if (!_hadNativeOverlaySelection) {
      return;
    }
    _nativeOverlayCollapseTimer?.cancel();
    _nativeOverlayCollapseTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || !_isNativeSelectionMode) {
        return;
      }
      if (!_nativeSelectionController.selection.isCollapsed) {
        return;
      }
      _hadNativeOverlaySelection = false;
      _handleNativeOverlaySelectionChanged(
        _nativeSelectionController.selection,
        null,
      );
    });
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
      case NativeSelectionOverlayChange.exitSelectionMode:
        _dismissNativeSelectionOverlayForEditing();
        return;
    }
  }

  void _dismissNativeSelectionOverlayForEditing() {
    if (!mounted) {
      return;
    }

    if (!_isNativeSelectionMode) {
      return;
    }

    if (!_isMobilePlatform) {
      return;
    }

    _nativeSelectionFocusNode.unfocus();
    _nativeSelectionController.clear();
    _terminalController.clearSelection();
    _hadNativeOverlaySelection = false;
    _nativeOverlayCollapseTimer?.cancel();
    setState(() {
      _isNativeSelectionMode = false;
      _revealsNativeSelectionOverlayInTouchScrollMode = false;
    });
  }

  String? _resolveTerminalLinkTap(CellOffset offset) {
    final externalLink = _resolveTerminalExternalLinkAtOffset(offset);
    if (externalLink != null) {
      _pendingTerminalPathTap = null;
      if (_consumeRecentlyOpenedTerminalLinkTap(externalLink)) {
        return null;
      }
      return externalLink;
    }

    if (!ref.read(terminalPathLinksNotifierProvider)) {
      _pendingTerminalPathTap = null;
      return null;
    }

    final detectedPath = _resolveTerminalFilePathAtOffset(
      offset,
      forgiving: _isMobilePlatform,
    );
    if (detectedPath == null) {
      final pendingPath = _pendingTerminalPathTap;
      _clearPendingTerminalPathTap();
      if (pendingPath == null || !_isInteractiveTerminalFilePath(pendingPath)) {
        return null;
      }
      if (_consumeRecentlyOpenedTerminalPathTap(pendingPath)) {
        return null;
      }
      return '$_terminalSftpPathPrefix$pendingPath';
    }

    _clearPendingTerminalPathTap();
    if (_consumeRecentlyOpenedTerminalPathTap(detectedPath)) {
      return null;
    }
    return '$_terminalSftpPathPrefix$detectedPath';
  }

  String? _resolveTerminalExternalLinkAtOffset(CellOffset offset) {
    if (!shouldResolveTerminalTapLinks(
      showsNativeSelectionOverlay: _showsNativeSelectionOverlay,
    )) {
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

    final wrappedSnapshot = _buildWrappedTerminalLinkSnapshot(row);
    if (wrappedSnapshot == null) {
      return null;
    }

    final rowIndex = row - wrappedSnapshot.startRow;
    final textOffset =
        wrappedSnapshot.rowStarts[rowIndex] +
        wrappedSnapshot.columnOffsets[rowIndex][column];
    final detectedLink = detectTerminalLinkAtTextOffset(
      wrappedSnapshot.text,
      textOffset,
    );
    return detectedLink?.uri.toString();
  }

  String? _resolveTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final detectedPath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: forgiving,
    );
    if (detectedPath == null) {
      return null;
    }

    if (_isInteractiveTerminalFilePath(detectedPath)) {
      return detectedPath;
    }

    _primeTerminalFilePathVerification(detectedPath);
    return null;
  }

  String? _detectTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final candidateOffsets = forgiving
        ? resolveForgivingTerminalTapOffsets(offset)
        : <CellOffset>[offset];
    for (final candidateOffset in candidateOffsets) {
      final detectedPath = _detectTerminalFilePathAtCell(candidateOffset);
      if (detectedPath != null) {
        return detectedPath;
      }
    }
    if (forgiving) {
      return _resolveSingleInteractiveTerminalFilePathOnRow(offset.y);
    }
    return null;
  }

  String? _resolveSingleInteractiveTerminalFilePathOnRow(int row) {
    final segments = _resolveInteractiveTerminalPathSegmentsOnRow(row);
    return segments.length == 1 ? segments.single.path : null;
  }

  String? _detectTerminalFilePathAtCell(CellOffset offset) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final pathSnapshot = _buildTerminalPathTapSnapshot(row);
    if (pathSnapshot == null) {
      return null;
    }

    return _detectTerminalFilePathInSnapshotAtCell(pathSnapshot, offset);
  }

  String? _detectTerminalFilePathInSnapshotAtCell(
    _TerminalPathTapSnapshot pathSnapshot,
    CellOffset offset,
  ) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    final line = _terminal.buffer.lines[row];
    if (line.getCodePoint(column) == 0) {
      return null;
    }

    final pathRowIndex = row - pathSnapshot.startRow;
    if (pathRowIndex < 0 || pathRowIndex >= pathSnapshot.columnOffsets.length) {
      return null;
    }

    final rowColumnOffsets = pathSnapshot.columnOffsets[pathRowIndex];
    if (column >= rowColumnOffsets.length) {
      return null;
    }

    final pathTextOffset =
        pathSnapshot.rowStarts[pathRowIndex] + rowColumnOffsets[column];
    final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      final activePath = _interactiveTerminalFilePathCandidate(
        detectedPath.path,
      );
      final activeEnd = activePath == null
          ? detectedPath.hitTestEnd
          : _resolveOriginalTerminalPathMatchEnd(
              normalizedSnapshot: snapshotAnalysis.normalizedSnapshot,
              normalizedStart: detectedPath.normalizedStart,
              normalizedLength: activePath.length,
            );
      if (activeEnd == null) {
        continue;
      }
      if (pathTextOffset >= detectedPath.start && pathTextOffset < activeEnd) {
        return detectedPath.path;
      }
    }
    return null;
  }

  _TerminalPathTapSnapshot? _buildWrappedTerminalLinkSnapshot(int row) {
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

  _TerminalPathTapSnapshot? _buildTerminalPathTapSnapshot(int row) {
    final buffer = _terminal.buffer;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    // Locate the canonical start of the wrapped-line group so that all rows
    // in the group share the same cache key.
    var cacheKey = row;
    while (cacheKey > 0 && buffer.lines[cacheKey].isWrapped) {
      cacheKey--;
    }

    // Invalidate snapshot and analysis caches when content has changed.
    if (_terminalPathSnapshotCacheGeneration != _terminalContentGeneration) {
      _terminalPathSnapshotCacheGeneration = _terminalContentGeneration;
      _terminalPathSnapshotCache.clear();
      _terminalPathAnalysisCache.clear();
    }

    if (_terminalPathSnapshotCache.containsKey(cacheKey)) {
      return _terminalPathSnapshotCache[cacheKey];
    }

    String lineTextAt(int lineIndex) => _buildNativeSelectionLineSnapshot(
      buffer.lines[lineIndex],
      buffer.viewWidth,
    ).text;

    var startRow = cacheKey;
    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    while (startRow > 0 &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(startRow - 1),
          nextLineText: lineTextAt(startRow),
        )) {
      startRow--;
    }

    while (endRow + 1 < buffer.height &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(endRow),
          nextLineText: lineTextAt(endRow + 1),
        )) {
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
      if (lineIndex < endRow && !buffer.lines[lineIndex + 1].isWrapped) {
        builder.write('\n');
      }
    }

    final snapshot = (
      text: builder.toString(),
      startRow: startRow,
      rowStarts: rowStarts,
      columnOffsets: columnOffsets,
    );
    _terminalPathSnapshotCache[cacheKey] = snapshot;
    return snapshot;
  }

  void _handleTerminalPathHover(PointerHoverEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null ||
        !ref.read(terminalPathLinksNotifierProvider) ||
        !ref.read(terminalPathLinkUnderlinesNotifierProvider)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final isSameHoveredCell =
        _lastHoveredTerminalPathOffset?.x == offset.x &&
        _lastHoveredTerminalPathOffset?.y == offset.y;
    final detectedPath = isSameHoveredCell
        ? _lastHoveredTerminalPath
        : _resolveTerminalFilePathAtOffset(offset);
    if (!isSameHoveredCell) {
      _lastHoveredTerminalPathOffset = offset;
      _lastHoveredTerminalPath = detectedPath;
    }
    if (detectedPath == null || !_shouldShowTerminalPathBadge(detectedPath)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final hoveredSegment = _resolveInteractiveTerminalPathSegmentAtOffset(
      offset,
      path: detectedPath,
    );
    if (hoveredSegment == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final underline = _buildTerminalPathInlineUnderline(
      row: offset.y,
      startColumn: hoveredSegment.startColumn,
      endColumn: hoveredSegment.endColumn,
    );
    if (underline == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    if (_hoveredTerminalPathUnderline == underline) {
      return;
    }
    setState(() => _hoveredTerminalPathUnderline = underline);
  }

  void _clearPendingTerminalPathTap() {
    _pendingTerminalPathTap = null;
    _pendingTerminalPathTapPointer = null;
    _pendingTerminalPathTapDownPosition = null;
    _pendingTerminalPathTapDownTimestamp = null;
  }

  void _clearPendingTerminalLinkTap() {
    _pendingTerminalLinkTap = null;
    _pendingTerminalLinkTapPointer = null;
    _pendingTerminalLinkTapDownPosition = null;
    _pendingTerminalLinkTapDownTimestamp = null;
  }

  bool _consumeRecentlyOpenedTerminalLinkTap(String link) {
    if (_recentlyOpenedTerminalLinkTap != link) {
      return false;
    }
    _recentlyOpenedTerminalLinkTap = null;
    return true;
  }

  bool _consumeRecentlyOpenedTerminalPathTap(String path) {
    if (_recentlyOpenedTerminalPathTap != path) {
      return false;
    }
    _recentlyOpenedTerminalPathTap = null;
    return true;
  }

  void _clearPendingTerminalDoubleTap() {
    _pendingTerminalDoubleTapPointer = null;
    _pendingTerminalDoubleTapDownPosition = null;
    _pendingTerminalDoubleTapDownTimestamp = null;
  }

  void _clearLastTerminalTap() {
    _lastTerminalTapPosition = null;
    _lastTerminalTapTimestamp = null;
  }

  void _pauseTerminalOutputFollowForTouch(PointerDownEvent event) {
    if (!_isMobilePlatform || event.kind != PointerDeviceKind.touch) {
      return;
    }

    if (_terminalOutputPauseTouchPointers.add(event.pointer)) {
      if (_terminalScrollController.hasClients) {
        _lastTerminalScrollOffset = _terminalScrollController.offset;
        _shouldFollowLiveOutput = shouldFollowTerminalOutput(
          hasScrollClients: true,
          currentOffset: _terminalScrollController.offset,
          maxScrollExtent: _terminalScrollController.position.maxScrollExtent,
        );
      }
      _syncTerminalLiveOutputAutoScroll();
      setState(() {});
    }
  }

  void _resumeTerminalOutputFollowForTouch(int pointer) {
    if (!_terminalOutputPauseTouchPointers.remove(pointer)) {
      return;
    }

    _syncTerminalLiveOutputAutoScroll();
    setState(() {});
    if (_terminalOutputPauseTouchPointers.isNotEmpty ||
        !_shouldFollowLiveOutput ||
        _isTerminalOutputFollowPaused) {
      return;
    }

    _queueTerminalScrollToBottom();
  }

  void _syncTerminalLiveOutputAutoScroll() {
    _terminalViewKey.currentState?.renderTerminal.liveOutputAutoScroll =
        _terminalLiveOutputAutoScrollEnabled;
  }

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _pauseTerminalOutputFollowForTouch(event);
    _handleTerminalLinkPointerDown(event);
    if (_pendingTerminalLinkTap == null) {
      _handleTerminalPathPointerDown(event);
    } else {
      _clearPendingTerminalPathTap();
    }
    _handleTerminalDoubleTapPointerDown(
      event,
      allowDoubleTap:
          _pendingTerminalLinkTap == null && _pendingTerminalPathTap == null,
    );
    _handleTerminalMouseTapPointerDown(
      event,
      allowTap:
          _pendingTerminalLinkTap == null &&
          _pendingTerminalPathTap == null &&
          _terminalDoubleTapConsumedPointer != event.pointer,
    );
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    _handleTerminalLinkPointerMove(event);
    _handleTerminalPathPointerMove(event);
    _handleTerminalDoubleTapPointerMove(event);
    _handleTerminalMouseTapPointerMove(event);
  }

  void _handleTerminalPointerUp(PointerUpEvent event) {
    final linkTapConsumed = _handleTerminalLinkPointerUp(event);
    final pathTapConsumed =
        !linkTapConsumed && _handleTerminalPathPointerUp(event);
    if (!linkTapConsumed && !pathTapConsumed) {
      _handleTerminalDoubleTapPointerUp(event);
      _handleTerminalMouseTapPointerUp(event);
    } else {
      _clearPendingTerminalMouseTap(event.pointer);
      _clearLastTerminalTap();
    }
    _resumeTerminalOutputFollowForTouch(event.pointer);
  }

  void _handleTerminalPointerCancel(PointerCancelEvent event) {
    _handleTerminalLinkPointerCancel(event);
    _handleTerminalPathPointerCancel(event);
    _handleTerminalDoubleTapPointerCancel(event);
    _clearPendingTerminalMouseTap(event.pointer);
    _resumeTerminalOutputFollowForTouch(event.pointer);
  }

  void _handleTerminalLinkPointerDown(PointerDownEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    _clearPendingTerminalLinkTap();
    if (event.kind != PointerDeviceKind.touch || terminalViewState == null) {
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final tappedLink = _resolveTerminalExternalLinkAtOffset(offset);
    if (tappedLink == null) {
      return;
    }

    _terminalTextInputController.suppressNextTouchKeyboardRequest();
    _pendingTerminalLinkTap = tappedLink;
    _pendingTerminalLinkTapPointer = event.pointer;
    _pendingTerminalLinkTapDownPosition = event.position;
    _pendingTerminalLinkTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalLinkPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalLinkTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalLinkTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalLinkTap();
    }
  }

  bool _handleTerminalLinkPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return false;
    }

    final pendingLink = _pendingTerminalLinkTap;
    final downPosition = _pendingTerminalLinkTapDownPosition;
    final downTimestamp = _pendingTerminalLinkTapDownTimestamp;
    if (pendingLink == null ||
        _pendingTerminalLinkTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalLinkTap();
      return pendingLink != null;
    }

    _clearPendingTerminalLinkTap();
    _clearPendingTerminalPathTap();
    _recentlyOpenedTerminalLinkTap = pendingLink;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_recentlyOpenedTerminalLinkTap == pendingLink) {
        _recentlyOpenedTerminalLinkTap = null;
      }
    });
    _handleTerminalLinkTap(pendingLink);
    return true;
  }

  void _handleTerminalLinkPointerCancel(PointerCancelEvent event) {
    if (_pendingTerminalLinkTapPointer == event.pointer) {
      _clearPendingTerminalLinkTap();
    }
  }

  void _handleTerminalMouseTapPointerDown(
    PointerDownEvent event, {
    required bool allowTap,
  }) {
    _clearPendingTerminalMouseTap();
    final terminalViewState = _terminalViewKey.currentState;
    if (event.kind != PointerDeviceKind.touch ||
        !allowTap ||
        terminalViewState == null ||
        !terminalViewState.shouldSendTerminalTapPointerInput) {
      return;
    }

    _pendingTerminalMouseTapPointer = event.pointer;
    _pendingTerminalMouseTapDownPosition = event.position;
    _pendingTerminalMouseTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalMouseTapPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalMouseTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalMouseTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalMouseTap(event.pointer);
    }
  }

  void _handleTerminalMouseTapPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch ||
        _terminalDoubleTapConsumedPointer == event.pointer) {
      _clearPendingTerminalMouseTap(event.pointer);
      return;
    }

    final downPosition = _pendingTerminalMouseTapDownPosition;
    final downTimestamp = _pendingTerminalMouseTapDownTimestamp;
    if (_pendingTerminalMouseTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalMouseTap(event.pointer);
      return;
    }

    _clearPendingTerminalMouseTap(event.pointer);
    _terminalViewKey.currentState?.sendTerminalPrimaryTap(event.position);
  }

  void _clearPendingTerminalMouseTap([int? pointer]) {
    if (pointer != null && _pendingTerminalMouseTapPointer != pointer) {
      return;
    }
    _pendingTerminalMouseTapPointer = null;
    _pendingTerminalMouseTapDownPosition = null;
    _pendingTerminalMouseTapDownTimestamp = null;
  }

  void _handleTerminalDoubleTapPointerDown(
    PointerDownEvent event, {
    required bool allowDoubleTap,
  }) {
    if (event.kind != PointerDeviceKind.touch || !allowDoubleTap) {
      _clearPendingTerminalDoubleTap();
      return;
    }

    final lastTapPosition = _lastTerminalTapPosition;
    final lastTapTimestamp = _lastTerminalTapTimestamp;
    final isDoubleTap =
        lastTapPosition != null &&
        lastTapTimestamp != null &&
        event.timeStamp - lastTapTimestamp <= kDoubleTapTimeout &&
        (event.position - lastTapPosition).distance <= kDoubleTapSlop;

    if (isDoubleTap) {
      // Let SelectionArea handle text selection without also forwarding the
      // second tap as terminal mouse input.
      _terminalDoubleTapConsumedPointer = event.pointer;
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
      return;
    }

    _pendingTerminalDoubleTapPointer = event.pointer;
    _pendingTerminalDoubleTapDownPosition = event.position;
    _pendingTerminalDoubleTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalDoubleTapPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalDoubleTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalDoubleTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
    }
  }

  void _handleTerminalDoubleTapPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _terminalDoubleTapConsumedPointer = null;
      _clearPendingTerminalDoubleTap();
      return;
    }

    final downPosition = _pendingTerminalDoubleTapDownPosition;
    final downTimestamp = _pendingTerminalDoubleTapDownTimestamp;
    if (_pendingTerminalDoubleTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
      return;
    }

    _lastTerminalTapPosition = event.position;
    _lastTerminalTapTimestamp = event.timeStamp;
    _clearPendingTerminalDoubleTap();
  }

  void _handleTerminalDoubleTapPointerCancel(PointerCancelEvent event) {
    if (_pendingTerminalDoubleTapPointer == event.pointer) {
      _clearPendingTerminalDoubleTap();
    }
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _terminalDoubleTapConsumedPointer = null;
    }
  }

  void _handleTerminalPathPointerDown(PointerDownEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    final pathLinksEnabled = ref.read(terminalPathLinksNotifierProvider);
    _clearPendingTerminalPathTap();
    if (terminalViewState == null || !pathLinksEnabled) {
      if (_hoveredTerminalPathUnderline != null) {
        _clearHoveredTerminalPathUnderline();
      }
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final terminalViewObject = terminalViewState.context.findRenderObject();
    final terminalViewLocalPosition = terminalViewObject is RenderBox
        ? terminalViewObject.globalToLocal(event.position)
        : terminalLocalPosition;
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final candidatePath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: event.kind == PointerDeviceKind.touch,
    );
    final underlinePath = event.kind == PointerDeviceKind.touch
        ? resolveTerminalPathTouchTargetTap(terminalViewLocalPosition, [
            for (final underline in _visibleTerminalPathUnderlines)
              (path: underline.path, touchRect: underline.touchRect),
          ])
        : null;
    final tappedPath = candidatePath ?? underlinePath;
    if (tappedPath != null && event.kind == PointerDeviceKind.touch) {
      _terminalTextInputController.suppressNextTouchKeyboardRequest();
    }
    if (candidatePath != null &&
        !_isInteractiveTerminalFilePath(candidatePath)) {
      _primeTerminalFilePathVerification(candidatePath);
    }
    if (tappedPath != null && _isInteractiveTerminalFilePath(tappedPath)) {
      _pendingTerminalPathTap = tappedPath;
      _pendingTerminalPathTapPointer = event.pointer;
      _pendingTerminalPathTapDownPosition = event.position;
      _pendingTerminalPathTapDownTimestamp = event.timeStamp;
    }
  }

  void _handleTerminalPathPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalPathTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalPathTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalPathTap();
    }
  }

  bool _handleTerminalPathPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return false;
    }

    final pendingPath = _pendingTerminalPathTap;
    final downPosition = _pendingTerminalPathTapDownPosition;
    final downTimestamp = _pendingTerminalPathTapDownTimestamp;
    if (pendingPath == null ||
        _pendingTerminalPathTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalPathTap();
      return pendingPath != null;
    }

    _clearPendingTerminalPathTap();
    _recentlyOpenedTerminalPathTap = pendingPath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_recentlyOpenedTerminalPathTap == pendingPath) {
        _recentlyOpenedTerminalPathTap = null;
      }
    });
    _handleTerminalLinkTap('$_terminalSftpPathPrefix$pendingPath');
    return true;
  }

  void _handleTerminalPathPointerCancel(PointerCancelEvent event) {
    if (_pendingTerminalPathTapPointer == event.pointer) {
      _clearPendingTerminalPathTap();
    }
  }

  void _clearHoveredTerminalPathUnderline() {
    _lastHoveredTerminalPathOffset = null;
    _lastHoveredTerminalPath = null;
    if (_hoveredTerminalPathUnderline == null || !mounted) {
      return;
    }
    setState(() => _hoveredTerminalPathUnderline = null);
  }

  bool _shouldShowTerminalPathBadge(String path) =>
      _isInteractiveTerminalFilePath(path);

  void _queueVisibleTerminalPathUnderlineRefresh() {
    if (!_isMobilePlatform ||
        _isTerminalPathUnderlineRefreshQueued ||
        !mounted) {
      return;
    }

    _isTerminalPathUnderlineRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalPathUnderlineRefreshQueued = false;
      if (!mounted) {
        return;
      }
      _refreshVisibleTerminalPathUnderlines();
    });
  }

  void _refreshVisibleTerminalPathUnderlines() {
    final terminalViewState = _terminalViewKey.currentState;
    final showsUnderlines =
        ref.read(terminalPathLinksNotifierProvider) &&
        ref.read(terminalPathLinkUnderlinesNotifierProvider);
    if (!_isMobilePlatform || !showsUnderlines || terminalViewState == null) {
      if (_visibleTerminalPathUnderlines.isNotEmpty) {
        setState(
          () => _visibleTerminalPathUnderlines =
              const <
                ({String path, TerminalTextUnderline underline, Rect touchRect})
              >[],
        );
      }
      return;
    }

    final renderTerminal = terminalViewState.renderTerminal;
    final rowRange = resolveVisibleTerminalRowRange(
      scrollOffset: _terminalScrollController.hasClients
          ? _terminalScrollController.offset
          : 0,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: renderTerminal.size.height,
      bufferHeight: _terminal.buffer.height,
    );
    if (rowRange == null) {
      return;
    }

    final underlines =
        <({String path, TerminalTextUnderline underline, Rect touchRect})>[];
    final buffer = _terminal.buffer;
    var row = rowRange.topRow;
    while (row <= rowRange.bottomRow) {
      // Skip single, non-wrapped rows that contain no path-like characters.
      // This avoids the expensive snapshot-building step for the majority of
      // output lines that can never match a file path.
      final isSingleRow =
          !buffer.lines[row].isWrapped &&
          (row + 1 >= buffer.height || !buffer.lines[row + 1].isWrapped);
      if (isSingleRow &&
          !terminalRowMayContainPath(buffer.lines[row], buffer.viewWidth)) {
        row++;
        continue;
      }
      final pathSnapshot = _buildTerminalPathTapSnapshot(row);
      if (pathSnapshot == null) {
        row++;
        continue;
      }
      final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
      final snapshotEndRow =
          pathSnapshot.startRow + pathSnapshot.columnOffsets.length - 1;
      final visibleSnapshotBottom = min(rowRange.bottomRow, snapshotEndRow);
      for (
        var snapshotRow = max(row, pathSnapshot.startRow);
        snapshotRow <= visibleSnapshotBottom;
        snapshotRow++
      ) {
        final segments = _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
          snapshotRow,
          pathSnapshot: pathSnapshot,
          snapshotAnalysis: snapshotAnalysis,
        );
        for (final segment in segments) {
          if (!_shouldShowTerminalPathBadge(segment.path)) {
            continue;
          }
          final underline = _buildTerminalPathInlineUnderline(
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          final touchRect = _buildTerminalPathTouchTargetRect(
            terminalViewState,
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          if (underline != null && touchRect != null) {
            underlines.add((
              path: segment.path,
              underline: underline,
              touchRect: touchRect,
            ));
          }
        }
      }
      row = visibleSnapshotBottom + 1;
    }

    if (!listEquals(_visibleTerminalPathUnderlines, underlines)) {
      setState(() => _visibleTerminalPathUnderlines = underlines);
    }
  }

  TerminalTextUnderline? _buildTerminalPathInlineUnderline({
    required int row,
    required int startColumn,
    required int endColumn,
  }) => resolveTerminalPathInlineUnderline(
    row: row,
    startColumn: startColumn,
    endColumn: endColumn,
    rowCount: _terminal.buffer.height,
    columnCount: _terminal.buffer.viewWidth,
  );

  Rect? _buildTerminalPathTouchTargetRect(
    MonkeyTerminalViewState terminalViewState, {
    required int row,
    required int startColumn,
    required int endColumn,
  }) {
    final terminalViewObject = terminalViewState.context.findRenderObject();
    if (terminalViewObject is! RenderBox) {
      return null;
    }
    final renderTerminal = terminalViewState.renderTerminal;
    final lineTopLeft = renderTerminal.localToGlobal(
      renderTerminal.getOffset(CellOffset(startColumn, row)),
      ancestor: terminalViewObject,
    );
    final lineEndOffset = renderTerminal.localToGlobal(
      renderTerminal.getOffset(
        CellOffset((endColumn + 1).clamp(0, _terminal.buffer.viewWidth), row),
      ),
      ancestor: terminalViewObject,
    );
    return resolveTerminalPathTouchTargetRect(
      lineTopLeft: lineTopLeft,
      lineEndOffset: lineEndOffset,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: terminalViewObject.size.height,
    );
  }

  ({String path, String text, int startColumn, int endColumn})?
  _resolveInteractiveTerminalPathSegmentAtOffset(
    CellOffset offset, {
    String? path,
  }) {
    for (final segment in _resolveInteractiveTerminalPathSegmentsOnRow(
      offset.y,
    )) {
      if (offset.x >= segment.startColumn &&
          offset.x <= segment.endColumn &&
          (path == null || segment.path == path)) {
        return segment;
      }
    }
    return null;
  }

  _TerminalPathSnapshotAnalysis _analyzeTerminalPathSnapshot(
    _TerminalPathTapSnapshot pathSnapshot,
  ) {
    final cached = _terminalPathAnalysisCache[pathSnapshot.text];
    if (cached != null) return cached;
    final analysis = (
      detectedPaths: _detectTerminalFilePathMatches(pathSnapshot.text),
      normalizedSnapshot: _normalizeTerminalFilePathDetectionText(
        pathSnapshot.text,
      ),
    );
    _terminalPathAnalysisCache[pathSnapshot.text] = analysis;
    return analysis;
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsOnRow(int row) {
    final clampedRow = row.clamp(0, _terminal.buffer.height - 1);
    final pathSnapshot = _buildTerminalPathTapSnapshot(clampedRow);
    if (pathSnapshot == null) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    return _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
      clampedRow,
      pathSnapshot: pathSnapshot,
      snapshotAnalysis: _analyzeTerminalPathSnapshot(pathSnapshot),
    );
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
    int row, {
    required _TerminalPathTapSnapshot pathSnapshot,
    required _TerminalPathSnapshotAnalysis snapshotAnalysis,
  }) {
    final rowIndex = row - pathSnapshot.startRow;
    if (rowIndex < 0 || rowIndex >= pathSnapshot.columnOffsets.length) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }
    if (snapshotAnalysis.detectedPaths.isEmpty) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    final rowStart = pathSnapshot.rowStarts[rowIndex];
    final rowColumnOffsets = pathSnapshot.columnOffsets[rowIndex];
    final rowEnd = rowStart + rowColumnOffsets.last;
    final rowText = pathSnapshot.text.substring(rowStart, rowEnd);
    final rowNormalizedStart = snapshotAnalysis
        .normalizedSnapshot
        .originalToNormalizedOffsets[rowStart];
    final rowNormalizedEnd =
        snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets[rowEnd];
    final relativeCandidatesToPrime = <String>{};
    final segments =
        <({String path, String text, int startColumn, int endColumn})>[];
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      if (detectedPath.normalizedEnd <= rowNormalizedStart ||
          detectedPath.normalizedStart >= rowNormalizedEnd) {
        continue;
      }

      final path = detectedPath.path;
      final activePath = _interactiveTerminalFilePathCandidate(path);
      if (activePath != null) {
        final visibleSegment = resolveTerminalFilePathSegmentOnRow(
          rowText: rowText,
          rowStartOffset: rowStart,
          rowColumnOffsets: rowColumnOffsets,
          originalToNormalizedOffsets:
              snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets,
          normalizedPathStart: detectedPath.normalizedStart,
          normalizedPathEnd: detectedPath.normalizedStart + activePath.length,
        );
        if (visibleSegment == null) {
          continue;
        }
        segments.add((
          path: path,
          text: visibleSegment.text,
          startColumn: visibleSegment.startColumn,
          endColumn: visibleSegment.endColumn,
        ));
      } else if (requiresTerminalFilePathVerification(path)) {
        relativeCandidatesToPrime.add(path);
      }
    }

    for (final path in relativeCandidatesToPrime) {
      _primeTerminalFilePathVerification(path);
    }

    return segments;
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
    _clearHoveredTerminalPathUnderline();
    if (link.startsWith(_terminalSftpPathPrefix)) {
      unawaited(
        _openTerminalFilePath(link.substring(_terminalSftpPathPrefix.length)),
      );
      return;
    }

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

  Future<void> _openTerminalFilePath(String path) async {
    final normalizedPath = trimTerminalFilePathCandidate(path);
    if (!isSupportedTerminalFilePath(normalizedPath)) {
      _showTerminalLinkMessage('Could not open $path');
      return;
    }

    final verifiedPath = await _resolveVerifiedTerminalFilePath(normalizedPath);
    if (!mounted || verifiedPath == null) {
      return;
    }

    final connectionId = _connectionId;
    final cwd = _workingDirectoryPath;
    final tmuxPaneDirectory = await _resolveCurrentTmuxPaneDirectory();
    if (!mounted) {
      return;
    }

    final result = await context.pushNamed<String>(
      Routes.sftp,
      pathParameters: {'hostId': widget.hostId.toString()},
      queryParameters: _buildSftpBrowserQueryParameters(
        connectionId: connectionId,
        initialPath: verifiedPath,
        workingDirectory: cwd,
        tmuxPaneDirectory: tmuxPaneDirectory,
      ),
    );
    if (!mounted || result == null) {
      return;
    }

    _showTerminalLinkMessage(result);
  }

  Future<void> _writeLocalClipboardText(String text) async {
    _recentLocalClipboardText = text;
    _recentLocalClipboardAt = DateTime.now();
    await Clipboard.setData(ClipboardData(text: text));
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

    await _writeLocalClipboardText(path);
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

  String _terminalPathCacheKey(String terminalPath) =>
      '${_currentTerminalPathCacheScope()}:$terminalPath';

  String _currentTerminalPathCacheScope() =>
      '${widget.hostId}:${_connectionId ?? 0}:${_workingDirectoryPath ?? ''}';

  void _syncVerifiedTerminalPathCacheScope() {
    final nextScope = _currentTerminalPathCacheScope();
    if (_terminalPathCacheScope == nextScope) {
      return;
    }
    _terminalPathCacheScope = nextScope;
    _resetVerifiedTerminalPathCache();
  }

  void _resetVerifiedTerminalPathCache() {
    _verifiedTerminalPathCache.clear();
    _verifiedTerminalPathCacheOrder.clear();
    _verifyingTerminalPathCacheKeys.clear();
  }

  void _cacheVerifiedTerminalPath(
    String cacheKey, {
    required String terminalPath,
    required String resolvedPath,
  }) {
    _verifiedTerminalPathCache.remove(cacheKey);
    _verifiedTerminalPathCache[cacheKey] = (
      terminalPath: terminalPath,
      resolvedPath: resolvedPath,
    );
    _verifiedTerminalPathCacheOrder
      ..remove(cacheKey)
      ..addLast(cacheKey);
    while (_verifiedTerminalPathCacheOrder.length >
        _maxVerifiedTerminalPathCacheEntries) {
      final evictedKey = _verifiedTerminalPathCacheOrder.removeFirst();
      _verifiedTerminalPathCache.remove(evictedKey);
    }
  }

  void _disposeTerminalPathVerificationSftp() {
    _terminalPathVerificationSftp?.close();
    _terminalPathVerificationSftp = null;
    _terminalPathVerificationSftpFuture = null;
    _terminalPathVerificationSession = null;
    _terminalPathVerificationHomeDirectory = null;
  }

  Future<SftpClient?> _resolveTerminalPathVerificationSftp(
    SshSession session,
  ) async {
    if (!identical(_terminalPathVerificationSession, session)) {
      _disposeTerminalPathVerificationSftp();
      _terminalPathVerificationSession = session;
    }

    final cachedSftp = _terminalPathVerificationSftp;
    if (cachedSftp != null) {
      return cachedSftp;
    }

    final inFlight = _terminalPathVerificationSftpFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = session
        .sftp()
        .timeout(_terminalPathVerificationTimeout)
        .then<SftpClient?>((sftp) {
          if (!identical(_terminalPathVerificationSession, session)) {
            sftp.close();
            return null;
          }
          _terminalPathVerificationSftp = sftp;
          return sftp;
        });
    _terminalPathVerificationSftpFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_terminalPathVerificationSftpFuture, future)) {
        _terminalPathVerificationSftpFuture = null;
      }
    }
  }

  Future<String?> _resolveTerminalPathVerificationHomeDirectory(
    SftpClient sftp,
    String terminalPath,
  ) async {
    if (terminalPath != '~' && !terminalPath.startsWith('~/')) {
      return null;
    }
    final cachedHomeDirectory = _terminalPathVerificationHomeDirectory;
    if (cachedHomeDirectory != null) {
      return cachedHomeDirectory;
    }

    final homeDirectory = normalizeSftpAbsolutePath(
      await sftp.absolute('.').timeout(_terminalPathVerificationTimeout),
    );
    _terminalPathVerificationHomeDirectory = homeDirectory;
    return homeDirectory;
  }

  _VerifiedTerminalPath? _verifiedTerminalPath(String terminalPath) {
    _syncVerifiedTerminalPathCacheScope();
    return _verifiedTerminalPathCache[_terminalPathCacheKey(terminalPath)];
  }

  String? _interactiveTerminalFilePathCandidate(String terminalPath) {
    final verifiedPath = _verifiedTerminalPath(terminalPath);
    if (verifiedPath != null) {
      return verifiedPath.terminalPath;
    }
    if (!_isInteractiveTerminalFilePath(terminalPath)) {
      return null;
    }
    return terminalPath;
  }

  bool _isInteractiveTerminalFilePath(String terminalPath) =>
      shouldActivateTerminalFilePath(
        terminalPath,
        hasVerifiedPath: _verifiedTerminalPath(terminalPath) != null,
      );

  void _primeTerminalFilePathVerification(String terminalPath) {
    if (!requiresTerminalFilePathVerification(terminalPath)) {
      return;
    }

    _syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    if (_verifiedTerminalPathCache.containsKey(cacheKey) ||
        _verifyingTerminalPathCacheKeys.contains(cacheKey)) {
      return;
    }

    _verifyingTerminalPathCacheKeys.add(cacheKey);
    unawaited(() async {
      try {
        final verifiedPath = await _resolveVerifiedTerminalFilePath(
          terminalPath,
          showErrors: false,
        );
        if (!mounted || verifiedPath == null) {
          return;
        }
        setState(() {
          _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = true;
        });
      } finally {
        _verifyingTerminalPathCacheKeys.remove(cacheKey);
      }
    }());
  }

  Future<String?> _resolveVerifiedTerminalFilePath(
    String terminalPath, {
    bool showErrors = true,
  }) async {
    _syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    final cachedPath = _verifiedTerminalPathCache[cacheKey];
    if (cachedPath != null) {
      return cachedPath.resolvedPath;
    }

    final session = _activeSession();
    final isExplicitPath = isExplicitTerminalFilePath(terminalPath);
    if (session == null) {
      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }

    try {
      final sftp = await _resolveTerminalPathVerificationSftp(session);
      if (sftp == null) {
        return null;
      }
      final verificationCandidates =
          requiresTerminalFilePathVerification(terminalPath)
          ? resolveTerminalFilePathVerificationCandidates(terminalPath)
          : <String>[terminalPath];
      for (final candidate in verificationCandidates) {
        final homeDirectory =
            await _resolveTerminalPathVerificationHomeDirectory(
              sftp,
              candidate,
            );
        final resolvedPath = resolveRequestedSftpPath(
          candidate,
          workingDirectory: _workingDirectoryPath,
          homeDirectory: homeDirectory,
        );
        if (resolvedPath == null) {
          continue;
        }

        try {
          await sftp
              .stat(resolvedPath)
              .timeout(_terminalPathVerificationTimeout);
        } on SftpStatusError catch (error) {
          if (error.code == SftpStatusCode.noSuchFile) {
            continue;
          }
          rethrow;
        }

        _cacheVerifiedTerminalPath(
          cacheKey,
          terminalPath: candidate,
          resolvedPath: resolvedPath,
        );
        return resolvedPath;
      }

      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage(
          'Could not open "$terminalPath" in SFTP: path does not exist',
        );
      }
      return null;
    } on TimeoutException {
      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage('Timed out opening "$terminalPath" in SFTP');
      }
      return null;
    } on SftpStatusError catch (error) {
      if (showErrors && isExplicitPath) {
        final message = error.code == SftpStatusCode.noSuchFile
            ? 'Could not open "$terminalPath" in SFTP: path does not exist'
            : 'Could not open "$terminalPath" in SFTP';
        _showTerminalLinkMessage(message);
      }
      return null;
    } on Object catch (error, stackTrace) {
      DiagnosticsLogService.instance.warning(
        'terminal',
        'sftp_path_resolution_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (kDebugMode) {
        debugPrint(
          'Failed to resolve terminal file path "$terminalPath": $error',
        );
        debugPrint('$stackTrace');
      }
      if (showErrors && isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }
  }

  int? _resolveOriginalTerminalPathMatchEnd({
    required _NormalizedTerminalPathSnapshot normalizedSnapshot,
    required int normalizedStart,
    required int normalizedLength,
  }) {
    if (normalizedLength <= 0) {
      return null;
    }

    final normalizedEnd = normalizedStart + normalizedLength;
    if (normalizedEnd > normalizedSnapshot.normalizedToOriginalEnds.length) {
      return null;
    }

    return normalizedSnapshot.normalizedToOriginalEnds[normalizedEnd - 1];
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

      final text = await _readSystemClipboardText();
      if (text == null || text.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        _showClipboardMessage('Clipboard is empty');
        return;
      }

      final shouldPaste =
          !_shouldReviewTerminalCommandInsertion ||
          await _confirmTerminalInsertionIfNeeded(
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
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'paste_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard access failed. Try again.');
    } on FileSystemException catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'file_upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard file upload failed. Try again.');
    } on SftpError catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'remote_upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        'Remote upload failed. Check permissions and try again.',
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard upload failed. Try again.');
    }
  }

  Future<void> _pastePickedImage() async {
    final pickerRequest = resolveTerminalUploadPickerRequest(images: true);
    await _pickAndPasteFiles(
      dialogTitle: pickerRequest.dialogTitle,
      pickerType: pickerRequest.pickerType,
      itemLabelSingular: pickerRequest.itemLabelSingular,
      itemLabelPlural: pickerRequest.itemLabelPlural,
      allowMultiple: pickerRequest.allowMultiple,
      failureContext: pickerRequest.failureContext,
    );
  }

  Future<void> _pastePickedFiles() async {
    final pickerRequest = resolveTerminalUploadPickerRequest(images: false);
    await _pickAndPasteFiles(
      dialogTitle: pickerRequest.dialogTitle,
      pickerType: pickerRequest.pickerType,
      itemLabelSingular: pickerRequest.itemLabelSingular,
      itemLabelPlural: pickerRequest.itemLabelPlural,
      allowMultiple: pickerRequest.allowMultiple,
      failureContext: pickerRequest.failureContext,
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
      final result = await FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        type: pickerType,
        allowMultiple: allowMultiple,
        withData: kIsWeb,
        withReadStream: !kIsWeb,
      );
      if (!mounted) {
        return;
      }
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
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'picker_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('$failureContext failed. Try again.');
    } on FileSystemException catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'picked_file_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('$failureContext failed. Try again.');
    } on SftpError catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'picked_remote_upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        'Remote upload failed. Check permissions and try again.',
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'picked_upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('$failureContext failed. Try again.');
    }
  }

  Future<T> _withClipboardSftp<T>(
    Future<T> Function(
      SftpClient sftp,
      RemoteFileService remoteFileService,
      String uploadDirectory,
    )
    action,
  ) async {
    final session = _activeSession();
    if (session == null) {
      throw StateError('Connection is not ready yet');
    }

    final remoteFileService = ref.read(remoteFileServiceProvider);
    final sftp = await session.sftp();
    try {
      final homeDirectory = await remoteFileService.resolveInitialDirectory(
        sftp,
      );
      final appUploadParentDirectory =
          buildRemoteClipboardUploadParentDirectory(homeDirectory);
      final uploadDirectory = buildRemoteClipboardUploadDirectory(
        homeDirectory,
      );
      await remoteFileService.ensureDirectoryExists(
        sftp,
        appUploadParentDirectory,
        mode: remoteUploadDirectoryMode,
      );
      await remoteFileService.ensureDirectoryExists(
        sftp,
        uploadDirectory,
        mode: remoteUploadDirectoryMode,
      );
      return await action(sftp, remoteFileService, uploadDirectory);
    } finally {
      sftp.close();
    }
  }

  Future<({String name, Uint8List bytes})> _readAndroidClipboardContentUri(
    String uri,
  ) => ref.read(clipboardContentServiceProvider).readContentUri(uri);

  Future<bool> _confirmClipboardUpload({
    required String title,
    required String message,
    required String confirmLabel,
    List<String> details = const [],
  }) async {
    if (!mounted) {
      return false;
    }
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
          'This will upload ${clipboardFiles.length} clipboard file${clipboardFiles.length == 1 ? '' : 's'} to $remoteClipboardUploadDirectoryDisplay on the connected host and paste their remote paths into the terminal.',
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
      uploadDirectory,
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
            uploadDirectory,
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
            uploadDirectory,
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
      'Uploaded ${remotePaths.length} file${remotePaths.length == 1 ? '' : 's'} to $remoteClipboardUploadDirectoryDisplay',
    );
  }

  Future<void> _pasteClipboardImage(Uint8List imageBytes) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard image?',
      message:
          'This will upload the clipboard image to $remoteClipboardUploadDirectoryDisplay on the connected host and paste its remote path into the terminal.',
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
      uploadDirectory,
    ) async {
      final remotePath = joinRemotePath(
        uploadDirectory,
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
    if (!mounted) {
      return;
    }
    final itemLabel = selectedFiles.length == 1
        ? itemLabelSingular
        : itemLabelPlural;
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload selected $itemLabel?',
      message:
          'This will upload ${selectedFiles.length == 1 ? 'the selected $itemLabelSingular' : '${selectedFiles.length} selected $itemLabelPlural'} to $remoteClipboardUploadDirectoryDisplay on the connected host and paste ${selectedFiles.length == 1 ? 'its remote path' : 'their remote paths'} into the terminal.',
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
      uploadDirectory,
    ) async {
      final remotePaths = <String>[];
      for (var index = 0; index < selectedFiles.length; index++) {
        final file = selectedFiles[index];
        final sourceName = resolvePickedTerminalUploadFileName(
          file,
          index: index,
        );
        final remotePath = joinRemotePath(
          uploadDirectory,
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
          if (bytes == null) {
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
      'Uploaded ${selectedFiles.length == 1 ? 'selected $itemLabelSingular' : '${remotePaths.length} $itemLabelPlural'} to $remoteClipboardUploadDirectoryDisplay',
    );
  }

  Future<bool> _confirmKeyboardInsertion(TerminalCommandReview review) async {
    if (!_shouldReviewTerminalCommandInsertion) {
      return true;
    }
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
    if (!_shouldReviewTerminalCommandInsertion) {
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

class _TerminalConnectionStatusIcon extends StatelessWidget {
  const _TerminalConnectionStatusIcon({
    required this.label,
    required this.state,
    required this.isConnecting,
  });

  final String label;
  final SshConnectionState state;
  final bool isConnecting;

  IconData get _icon {
    if (isConnecting &&
        (state == SshConnectionState.disconnected ||
            state == SshConnectionState.connecting)) {
      return Icons.sync;
    }

    switch (state) {
      case SshConnectionState.connected:
        return Icons.check_circle_outline;
      case SshConnectionState.connecting:
      case SshConnectionState.authenticating:
        return Icons.sync;
      case SshConnectionState.reconnecting:
        return Icons.sync_problem_outlined;
      case SshConnectionState.error:
        return Icons.error_outline;
      case SshConnectionState.disconnected:
        return Icons.link_off;
    }
  }

  Color _color(ColorScheme colorScheme) {
    if (isConnecting &&
        (state == SshConnectionState.disconnected ||
            state == SshConnectionState.connecting)) {
      return colorScheme.tertiary;
    }

    switch (state) {
      case SshConnectionState.connected:
        return colorScheme.primary;
      case SshConnectionState.connecting:
      case SshConnectionState.authenticating:
      case SshConnectionState.reconnecting:
        return colorScheme.tertiary;
      case SshConnectionState.error:
      case SshConnectionState.disconnected:
        return colorScheme.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = _color(colorScheme);

    return Semantics(
      label: 'Terminal connection status: $label',
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Icon(_icon, size: 20, color: statusColor),
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
