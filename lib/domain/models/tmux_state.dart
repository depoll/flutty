import 'package:flutter/foundation.dart';

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
    final parts = line.split('|');
    if (parts.length < 3) {
      throw FormatException('Invalid tmux session format: $line');
    }
    final activityEpoch = parts.length > 3 && parts[3].isNotEmpty
        ? int.tryParse(parts[3])
        : null;
    return TmuxSession(
      name: parts[0],
      windowCount: int.tryParse(parts[1]) ?? 0,
      isAttached: parts[2] == '1',
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
    this.idleSeconds,
  });

  /// Parses a [TmuxWindow] from a pipe-delimited tmux format string.
  ///
  /// Expected format (from `tmux list-windows -F`):
  /// `index|name|active_flag|command|path|flags|pane_title|activity_epoch`
  factory TmuxWindow.fromTmuxFormat(String line) {
    final parts = line.split('|');
    if (parts.length < 3) {
      throw FormatException('Invalid tmux window format: $line');
    }

    // Compute idle seconds from window_activity epoch if available.
    int? idleSeconds;
    if (parts.length > 7) {
      final activityEpoch = int.tryParse(parts[7]);
      if (activityEpoch != null && activityEpoch > 0) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        idleSeconds = now - activityEpoch;
        if (idleSeconds < 0) idleSeconds = 0;
      }
    }

    return TmuxWindow(
      index: int.tryParse(parts[0]) ?? 0,
      name: parts[1],
      isActive: parts[2] == '1',
      currentCommand: parts.length > 3 ? _nonEmpty(parts[3]) : null,
      currentPath: parts.length > 4 ? _nonEmpty(parts[4]) : null,
      flags: parts.length > 5 ? _nonEmpty(parts[5]) : null,
      paneTitle: parts.length > 6 ? _nonEmpty(parts[6]) : null,
      idleSeconds: idleSeconds,
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

  /// Seconds since last output activity in this window, if available.
  final int? idleSeconds;

  /// Idle threshold (seconds) above which a window is considered "waiting".
  static const _idleThreshold = 15;

  /// Whether this window has a pending alert or bell.
  bool get hasAlert => flags != null && flags!.contains('#');

  /// Whether the window appears to be idle (no output for a while).
  ///
  /// A CLI that has finished working and is waiting for the user to
  /// return will have a high idle time while still showing as the
  /// `currentCommand`.
  bool get isIdle =>
      idleSeconds != null && idleSeconds! > _idleThreshold && !isActive;

  /// A short display title — prefers paneTitle, falls back to name.
  String get displayTitle => paneTitle ?? name;

  /// A human-readable status label for display.
  ///
  /// Only returns a label for noteworthy states — the active window
  /// is already visually highlighted via the index badge.
  String get statusLabel {
    if (hasAlert) return 'alert';
    if (isIdle) return 'waiting';
    return '';
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
          idleSeconds == other.idleSeconds;

  @override
  int get hashCode => Object.hash(
    index,
    name,
    isActive,
    currentCommand,
    currentPath,
    flags,
    paneTitle,
    idleSeconds,
  );
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

String? _nonEmpty(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ── tmux command helpers ──────────────────────────────────────────────────

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

  // Try -s <name> (new-session / new)
  final sFlag = RegExp('-[A-Za-z]*s\\s+$argPattern').firstMatch(tmuxPart);
  if (sFlag != null) {
    return sFlag.group(1) ?? sFlag.group(2) ?? sFlag.group(3);
  }

  // Try -t <name> (attach / attach-session)
  final tFlag = RegExp('-[A-Za-z]*t\\s+$argPattern').firstMatch(tmuxPart);
  if (tFlag != null) {
    return tFlag.group(1) ?? tFlag.group(2) ?? tFlag.group(3);
  }

  return null;
}

/// Strips surrounding quotes from a shell argument.
String _unquote(String value) {
  if (value.length >= 2) {
    if ((value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'))) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}
