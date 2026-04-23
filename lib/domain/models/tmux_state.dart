import 'package:flutter/foundation.dart';

import 'agent_launch_preset.dart';

/// Represents a tmux session on a remote host.
@immutable
class TmuxSession {
  /// Creates a new [TmuxSession].
  const TmuxSession({
    required this.name,
    required this.windowCount,
    required this.isAttached,
    this.lastActivity,
  });

  /// Parses a [TmuxSession] from a pipe-delimited tmux format string.
  ///
  /// Expected format (from `tmux list-sessions -F`):
  /// `session_name|window_count|attached_flag|activity_epoch`
  factory TmuxSession.fromTmuxFormat(String line) {
    final fields = line.split('|');
    if (fields.length < 3) {
      throw FormatException('Invalid tmux session format: $line');
    }
    final activityEpoch = fields.length > 3 && fields[3].isNotEmpty
        ? int.tryParse(fields[3])
        : null;
    return TmuxSession(
      name: fields[0],
      windowCount: int.tryParse(fields[1]) ?? 0,
      isAttached: fields[2] == '1',
      lastActivity: activityEpoch != null && activityEpoch > 0
          ? DateTime.fromMillisecondsSinceEpoch(activityEpoch * 1000)
          : null,
    );
  }

  /// The session name.
  final String name;

  /// Number of windows in this session.
  final int windowCount;

  /// Whether a client is currently viewing this session.
  final bool isAttached;

  /// When this session was last active.
  final DateTime? lastActivity;

  @override
  String toString() =>
      'TmuxSession(name: $name, windows: $windowCount, '
      'attached: $isAttached)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxSession &&
          name == other.name &&
          windowCount == other.windowCount &&
          isAttached == other.isAttached;

  @override
  int get hashCode => Object.hash(name, windowCount, isAttached);
}

/// Represents a single window within a tmux session.
@immutable
class TmuxWindow {
  /// Creates a new [TmuxWindow].
  const TmuxWindow({
    required this.index,
    required this.name,
    required this.isActive,
    this.currentCommand,
    this.currentPath,
    this.flags,
    this.paneTitle,
    int? idleSeconds,
    this.lastActivityEpochSeconds,
  }) : _snapshotIdleSeconds = idleSeconds;

  /// Parses a [TmuxWindow] from a pipe-delimited tmux format string.
  ///
  /// Expected format (from `tmux list-windows -F`):
  /// `index|name|active_flag|command|path|flags|pane_title|activity_epoch`
  factory TmuxWindow.fromTmuxFormat(String line) {
    final fields = line.split('|');
    if (fields.length < 3) {
      throw FormatException('Invalid tmux window format: $line');
    }

    final activityEpoch = fields.length > 7 ? int.tryParse(fields[7]) : null;

    return TmuxWindow(
      index: int.tryParse(fields[0]) ?? 0,
      name: fields[1],
      isActive: fields[2] == '1',
      currentCommand: fields.length > 3 ? _nonEmpty(fields[3]) : null,
      currentPath: fields.length > 4 ? _nonEmpty(fields[4]) : null,
      flags: fields.length > 5 ? _nonEmpty(fields[5]) : null,
      paneTitle: fields.length > 6 ? _nonEmpty(fields[6]) : null,
      lastActivityEpochSeconds: activityEpoch != null && activityEpoch > 0
          ? activityEpoch
          : null,
    );
  }

  /// The tmux-reported window index within the session.
  final int index;

  /// The window name (often set by the running program or user).
  final String name;

  /// Whether this is the currently active window in the session.
  final bool isActive;

  /// The command currently running in the active pane, if available.
  final String? currentCommand;

  /// The working directory of the active pane, if available.
  final String? currentPath;

  /// tmux window flags (`*` active, `-` last, `#` alert/bell, etc.).
  final String? flags;

  /// The pane title set by the running application, if available.
  final String? paneTitle;

  /// tmux's `window_activity` epoch seconds, if available.
  final int? lastActivityEpochSeconds;

  final int? _snapshotIdleSeconds;

  /// Seconds since last output activity in this window, if available.
  int? get idleSeconds {
    final activityEpoch = lastActivityEpochSeconds;
    if (activityEpoch == null) {
      return _snapshotIdleSeconds;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final idleSeconds = now - activityEpoch;
    return idleSeconds < 0 ? 0 : idleSeconds;
  }

  /// Idle threshold (seconds) above which a window is considered "waiting".
  static const _idleThreshold = 15;

  /// Whether this window has a pending alert, bell, or activity notification.
  bool get hasAlert =>
      flags != null && (flags!.contains('#') || flags!.contains('!'));

  /// Whether the window appears to be idle (no output for a while).
  ///
  /// A CLI that has finished working and is waiting for the user to
  /// return will have a high idle time while still showing as the
  /// `currentCommand`, including when it is the currently selected window.
  bool get isIdle => idleSeconds != null && idleSeconds! > _idleThreshold;

  /// Whether the window appears to be actively running work.
  bool get isRunning => !hasAlert && !isIdle;

  /// Whether the window's status can still change from running to waiting
  /// without tmux emitting a new control-mode notification.
  bool get needsLocalIdleRefresh =>
      !hasAlert && idleSeconds != null && idleSeconds! <= _idleThreshold;

  /// Returns a copy of this window with selectively overridden fields.
  TmuxWindow copyWith({
    bool? isActive,
    String? name,
    String? currentCommand,
    String? currentPath,
    String? flags,
    String? paneTitle,
    int? lastActivityEpochSeconds,
  }) => TmuxWindow(
    index: index,
    name: name ?? this.name,
    isActive: isActive ?? this.isActive,
    currentCommand: currentCommand ?? this.currentCommand,
    currentPath: currentPath ?? this.currentPath,
    flags: flags ?? this.flags,
    paneTitle: paneTitle ?? this.paneTitle,
    idleSeconds: _snapshotIdleSeconds,
    lastActivityEpochSeconds:
        lastActivityEpochSeconds ?? this.lastActivityEpochSeconds,
  );

  /// A short display title — prefers the richest usable tmux title.
  String get displayTitle {
    final normalizedPaneTitle = _normalizedTmuxTitle(
      paneTitle,
      stripPlaceholderPrefix: true,
    );
    final normalizedName = _normalizedTmuxTitle(
      name,
      stripPlaceholderPrefix: true,
    );
    if (normalizedPaneTitle == null) return normalizedName ?? name;
    if (normalizedName == null) return normalizedPaneTitle;
    if (_hasPlaceholderPrefix(name)) return normalizedPaneTitle;
    if (_isDecoratedVariantOfTitle(name, normalizedPaneTitle)) {
      return name.trim();
    }
    return normalizedPaneTitle;
  }

  /// A compact window label for surfaces that should track tmux window
  /// switches immediately.
  ///
  /// tmux updates `window_name` as part of the window-switch snapshot, while
  /// `pane_title` can lag slightly behind focus changes on some hosts. Prefer
  /// the normalized window name here so collapsed labels stay in sync with the
  /// active window selection. If the window name is just echoing the current
  /// command (for example `copilot` or `claude`), prefer the richer pane title
  /// instead so the collapsed handle still distinguishes agent sessions.
  String get handleTitle {
    final normalizedPaneTitle = _normalizedTmuxTitle(
      paneTitle,
      stripPlaceholderPrefix: true,
    );
    final normalizedName = _normalizedTmuxTitle(
      name,
      stripPlaceholderPrefix: true,
    );
    final normalizedCommand = _normalizedTmuxTitle(
      currentCommand,
      stripPlaceholderPrefix: true,
    );
    if (normalizedPaneTitle != null &&
        normalizedName != null &&
        normalizedCommand != null &&
        normalizedName.toLowerCase() == normalizedCommand.toLowerCase() &&
        normalizedPaneTitle != normalizedName) {
      return normalizedPaneTitle;
    }
    return normalizedName ?? displayTitle;
  }

  /// Secondary context for the window title when both pane and window names
  /// are useful and distinct.
  String? get secondaryTitle {
    final normalizedPaneTitle = _normalizedTmuxTitle(
      paneTitle,
      stripPlaceholderPrefix: true,
    );
    final normalizedName = _normalizedTmuxTitle(
      name,
      stripPlaceholderPrefix: true,
    );
    if (_isDecoratedVariantOfTitle(name, normalizedPaneTitle)) {
      return null;
    }
    if (normalizedPaneTitle == null ||
        normalizedName == null ||
        normalizedName == normalizedPaneTitle) {
      return null;
    }
    return normalizedName;
  }

  /// A human-readable status label for display.
  ///
  String get statusLabel {
    if (hasAlert) return 'alert';
    if (isIdle) return 'waiting';
    return 'running';
  }

  /// The supported agent CLI running in the foreground, if one can be inferred.
  AgentLaunchTool? get foregroundAgentTool {
    for (final candidate in [currentCommand, name, paneTitle]) {
      final tool = agentLaunchToolForCommandName(candidate);
      if (tool != null) {
        return tool;
      }
    }
    return null;
  }

  @override
  String toString() =>
      'TmuxWindow(index: $index, name: $name, active: $isActive, '
      'command: $currentCommand, title: $paneTitle)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxWindow &&
          index == other.index &&
          name == other.name &&
          isActive == other.isActive &&
          currentCommand == other.currentCommand &&
          currentPath == other.currentPath &&
          flags == other.flags &&
          paneTitle == other.paneTitle &&
          lastActivityEpochSeconds == other.lastActivityEpochSeconds &&
          _snapshotIdleSeconds == other._snapshotIdleSeconds;

  @override
  int get hashCode => Object.hash(
    index,
    name,
    isActive,
    currentCommand,
    currentPath,
    flags,
    paneTitle,
    lastActivityEpochSeconds,
    _snapshotIdleSeconds,
  );
}

/// Live update emitted while watching a tmux session in control mode.
sealed class TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowChangeEvent].
  const TmuxWindowChangeEvent();
}

/// A direct per-window snapshot from tmux's `%subscription-changed` output.
class TmuxWindowSnapshotEvent extends TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowSnapshotEvent].
  const TmuxWindowSnapshotEvent(this.window);

  /// The latest window snapshot from tmux.
  final TmuxWindow window;
}

/// A signal that callers should refetch the full window list.
class TmuxWindowReloadEvent extends TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowReloadEvent].
  const TmuxWindowReloadEvent();
}

/// Applies a live tmux window update to an existing window list.
List<TmuxWindow> applyTmuxWindowChangeEvent(
  List<TmuxWindow> windows,
  TmuxWindowChangeEvent event,
) {
  switch (event) {
    case TmuxWindowReloadEvent():
      return windows;
    case TmuxWindowSnapshotEvent(window: final window):
      final updated = windows
          .map(
            (existing) => window.isActive && existing.index != window.index
                ? existing.copyWith(isActive: false)
                : existing,
          )
          .toList(growable: true);
      final existingIndex = updated.indexWhere(
        (existing) => existing.index == window.index,
      );
      if (existingIndex == -1) {
        updated.add(window);
      } else {
        updated[existingIndex] = window;
      }
      updated.sort((a, b) => a.index.compareTo(b.index));
      return updated;
  }
}

/// Resolves the tmux window list after a full reload query.
///
/// A live tmux session should always report at least one window. Treat an
/// empty reload as transient: preserve the prior non-empty snapshot when
/// possible so the UI does not collapse into a broken-looking empty state
/// while a follow-up refresh retries in the background.
List<TmuxWindow>? resolveTmuxReloadedWindows(
  Iterable<TmuxWindow>? currentWindows,
  Iterable<TmuxWindow> reloadedWindows,
) {
  final nextWindows = reloadedWindows.toList(growable: false);
  if (nextWindows.isNotEmpty) {
    return nextWindows;
  }

  final previousWindows = currentWindows?.toList(growable: false);
  if (previousWindows != null && previousWindows.isNotEmpty) {
    return previousWindows;
  }

  return null;
}

/// Metadata for a recent AI coding tool session found on a remote host.
@immutable
class ToolSessionInfo {
  /// Creates a new [ToolSessionInfo].
  const ToolSessionInfo({
    required this.toolName,
    required this.sessionId,
    this.workingDirectory,
    this.lastActive,
    this.summary,
  });

  /// Human-readable tool name (e.g., "Claude Code", "Codex").
  final String toolName;

  /// Tool-specific session identifier used for resume commands.
  final String sessionId;

  /// The working directory this session was used in.
  final String? workingDirectory;

  /// When this session was last active.
  final DateTime? lastActive;

  /// A brief summary or title for the session, if available.
  final String? summary;

  /// How long ago this session was active, as a human-readable string.
  String get timeAgoLabel {
    if (lastActive == null) return '';
    final diff = DateTime.now().difference(lastActive!);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${diff.inDays ~/ 7}w ago';
  }

  /// A compact absolute + relative timestamp label for session lists.
  String get lastUpdatedLabel {
    if (lastActive == null) return '';
    final localTime = lastActive!.toLocal();
    final now = DateTime.now();
    final month = _monthAbbreviations[localTime.month - 1];
    final dateLabel = localTime.year == now.year
        ? '$month ${localTime.day}'
        : '$month ${localTime.day}, ${localTime.year}';
    return '$dateLabel | $timeAgoLabel';
  }

  @override
  String toString() =>
      'ToolSessionInfo(tool: $toolName, id: $sessionId, '
      'lastActive: $lastActive)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolSessionInfo &&
          toolName == other.toolName &&
          sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(toolName, sessionId);
}

const _monthAbbreviations = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String? _nonEmpty(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _normalizedTmuxTitle(
  String? value, {
  bool stripPlaceholderPrefix = false,
}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  var normalized = trimmed;
  if (stripPlaceholderPrefix) {
    normalized = normalized.replaceFirst(RegExp(r'^_+\s*'), '').trimLeft();
    normalized = normalized.replaceAll(RegExp(r'\s_+\s'), ' ').trim();
  }

  return normalized.isEmpty ? null : normalized;
}

bool _hasPlaceholderPrefix(String value) => value.trimLeft().startsWith('_');

bool _isDecoratedVariantOfTitle(String rawTitle, String? plainTitle) {
  if (plainTitle == null || plainTitle.isEmpty) return false;
  final trimmed = rawTitle.trim();
  if (trimmed.isEmpty || _hasPlaceholderPrefix(trimmed)) return false;
  final stripped = _stripLeadingDecorativePrefix(trimmed);
  return stripped.isNotEmpty && stripped == plainTitle && trimmed != plainTitle;
}

String _stripLeadingDecorativePrefix(String value) {
  final characters = value.runes.toList(growable: false);
  var startIndex = 0;
  while (startIndex < characters.length &&
      !_isAsciiLetterOrDigit(characters[startIndex])) {
    startIndex++;
  }
  if (startIndex == 0 || startIndex >= characters.length) return value;
  return String.fromCharCodes(characters.sublist(startIndex)).trimLeft();
}

bool _isAsciiLetterOrDigit(int rune) =>
    (rune >= 0x30 && rune <= 0x39) ||
    (rune >= 0x41 && rune <= 0x5A) ||
    (rune >= 0x61 && rune <= 0x7A);

// ── tmux command helpers ──────────────────────────────────────────────────

/// tmux command fragment that disables tmux's built-in status bar.
const tmuxDisableStatusBarCommand = r'\; set status off';

/// Builds a `tmux new-session` command from structured configuration.
///
/// Always uses `-A` (attach-or-create) so reconnecting reuses the session.
String buildTmuxCommand({
  required String sessionName,
  String? workingDirectory,
  String? extraFlags,
}) {
  final parts = <String>[
    'tmux new-session -A',
    "-s '${sessionName.replaceAll("'", "'\"'\"'")}'",
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
      "-c '${workingDirectory.trim().replaceAll("'", "'\"'\"'")}'",
    if (extraFlags != null && extraFlags.trim().isNotEmpty) extraFlags.trim(),
  ];
  return parts.join(' ');
}

/// Attempts to extract the tmux session name from a command string.
///
/// Handles common patterns:
/// - `tmux new-session -A -s myproject`
/// - `tmux new -As myproject`
/// - `tmux a -t myproject`
/// - `tmux attach -t myproject`
///
/// Returns `null` if the command doesn't appear to be a tmux invocation
/// or the session name can't be parsed.
String? parseTmuxSessionName(String? command) {
  if (command == null || command.isEmpty) return null;

  // Normalize: strip leading cd/env/path prefixes to find 'tmux ...'
  final tmuxIdx = command.indexOf('tmux ');
  if (tmuxIdx < 0) return null;
  final tmuxPart = command.substring(tmuxIdx);

  // Match a shell argument: 'quoted', "quoted", or unquoted-word.
  const argPattern = r"""(?:'([^']*)'|"([^"]*)"|(\S+))""";

  // Try -s <name> (new-session / new).
  // Use a whitespace lookbehind so we match standalone flags like `-s`
  // or combined flags like `-As`, but not subcommand suffixes like
  // `list-sessions`.
  final sFlag = RegExp(
    '(?<=\\s)-[A-Za-z]*s\\s+$argPattern',
  ).firstMatch(tmuxPart);
  if (sFlag != null) {
    return sFlag.group(1) ?? sFlag.group(2) ?? sFlag.group(3);
  }

  // Try -t <name> (attach / attach-session)
  final tFlag = RegExp(
    '(?<=\\s)-[A-Za-z]*t\\s+$argPattern',
  ).firstMatch(tmuxPart);
  if (tFlag != null) {
    return tFlag.group(1) ?? tFlag.group(2) ?? tFlag.group(3);
  }

  return null;
}

/// Resolves the preferred tmux session name before running remote queries.
///
/// Structured host settings win over parsed auto-connect commands because they
/// are explicit and avoid ambiguous tmux inference when multiple sessions exist.
String? resolvePreferredTmuxSessionName({
  String? structuredSessionName,
  String? autoConnectCommand,
}) {
  final structured = structuredSessionName?.trim();
  if (structured != null && structured.isNotEmpty) {
    return structured;
  }
  return parseTmuxSessionName(autoConnectCommand);
}
