/// Domain models for tmux session and window state.
///
/// These models represent the tmux state as queried over SSH exec channels.
/// They deliberately avoid tmux implementation details in their public API,
/// using user-friendly terminology ("windows" not "tmux windows").
library;

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

  /// Parses a [TmuxSession] from a tab-delimited tmux format string.
  ///
  /// Expected format (from `tmux list-sessions -F`):
  /// `session_name\twindow_count\tattached_flag\tactivity_epoch`
  factory TmuxSession.fromTmuxFormat(String line) {
    final parts = line.split('\t');
    if (parts.length < 3) {
      throw FormatException('Invalid tmux session format: $line');
    }
    return TmuxSession(
      name: parts[0],
      windowCount: int.tryParse(parts[1]) ?? 0,
      isAttached: parts[2] == '1',
      lastActivity: parts.length > 3
          ? DateTime.fromMillisecondsSinceEpoch(
              (int.tryParse(parts[3]) ?? 0) * 1000,
            )
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
  });

  /// Parses a [TmuxWindow] from a tab-delimited tmux format string.
  ///
  /// Expected format (from `tmux list-windows -F`):
  /// `index\tname\tactive_flag\tcurrent_command\tcurrent_path`
  factory TmuxWindow.fromTmuxFormat(String line) {
    final parts = line.split('\t');
    if (parts.length < 3) {
      throw FormatException('Invalid tmux window format: $line');
    }
    return TmuxWindow(
      index: int.tryParse(parts[0]) ?? 0,
      name: parts[1],
      isActive: parts[2] == '1',
      currentCommand: parts.length > 3 ? _nonEmpty(parts[3]) : null,
      currentPath: parts.length > 4 ? _nonEmpty(parts[4]) : null,
    );
  }

  /// The zero-based window index within the session.
  final int index;

  /// The window name (often set by the running program or user).
  final String name;

  /// Whether this is the currently active window in the session.
  final bool isActive;

  /// The command currently running in the active pane, if available.
  final String? currentCommand;

  /// The working directory of the active pane, if available.
  final String? currentPath;

  /// A human-readable status label for display.
  String get statusLabel {
    if (isActive) return 'active';
    if (currentCommand != null) return 'running';
    return 'idle';
  }

  @override
  String toString() =>
      'TmuxWindow(index: $index, name: $name, active: $isActive, '
      'command: $currentCommand)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxWindow &&
          index == other.index &&
          name == other.name &&
          isActive == other.isActive &&
          currentCommand == other.currentCommand &&
          currentPath == other.currentPath;

  @override
  int get hashCode =>
      Object.hash(index, name, isActive, currentCommand, currentPath);
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
