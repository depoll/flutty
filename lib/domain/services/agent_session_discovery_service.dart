import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tmux_state.dart';
import 'ssh_service.dart';

/// Discovers recent AI coding tool sessions on remote hosts by scanning
/// known session storage locations.
///
/// Each tool stores session history differently. This service encapsulates
/// the per-tool discovery logic and presents a unified list of
/// [ToolSessionInfo] entries.
class AgentSessionDiscoveryService {
  /// Creates a new [AgentSessionDiscoveryService].
  const AgentSessionDiscoveryService();

  /// Discovers recent sessions across all supported tools for the given
  /// [workingDirectory] on the remote host.
  ///
  /// Each tool's sessions are discovered in most-recent-first order, then
  /// the combined result is interleaved round-robin across tools so no
  /// single tool dominates the list. Limits to [maxPerTool] sessions per
  /// tool to keep results manageable.
  ///
  /// The [workingDirectory] is passed to tools that support directory-scoped
  /// session lookup (currently Claude Code and Gemini CLI pass it through
  /// but do not yet filter by it — reserved for future use).
  Future<List<ToolSessionInfo>> discoverSessions(
    SshSession session, {
    String? workingDirectory,
    int maxPerTool = 5,
  }) async {
    final results = await Future.wait([
      _discoverClaudeSessions(session, workingDirectory, maxPerTool),
      _discoverCodexSessions(session, maxPerTool),
      _discoverCopilotSessions(session, maxPerTool),
      _discoverGeminiSessions(session, workingDirectory, maxPerTool),
      _discoverOpenCodeSessions(session, maxPerTool),
    ]);

    // Interleave results from each tool in their original (mtime) order.
    // Each tool's list is already sorted by most-recent-first from the
    // remote commands. Interleaving round-robin keeps the combined list
    // balanced across tools rather than pushing tools without timestamps
    // to the bottom.
    final all = <ToolSessionInfo>[];
    final iterators = results
        .where((list) => list.isNotEmpty)
        .map((list) => list.iterator)
        .toList();
    var remaining = true;
    while (remaining) {
      remaining = false;
      for (final it in iterators) {
        if (it.moveNext()) {
          all.add(it.current);
          remaining = true;
        }
      }
    }

    return all;
  }

  /// Builds the shell command to resume a specific session.
  String buildResumeCommand(ToolSessionInfo info) {
    switch (info.toolName) {
      case 'Claude Code':
        return 'claude --resume ${_shellQuote(info.sessionId)}';
      case 'Codex':
        return 'codex resume ${_shellQuote(info.sessionId)}';
      case 'Copilot CLI':
        return 'copilot --resume ${_shellQuote(info.sessionId)}';
      case 'Gemini CLI':
        return 'gemini --resume ${_shellQuote(info.sessionId)}';
      case 'OpenCode':
        if (info.sessionId == '_continue') {
          return 'opencode --continue';
        }
        return 'opencode --session ${_shellQuote(info.sessionId)}';
      default:
        return info.toolName.toLowerCase();
    }
  }

  // ── Claude Code ────────────────────────────────────────────────────────
  // Sessions: ~/.claude/projects/<path-hash>/*.jsonl
  // Index:    ~/.claude/history.jsonl

  Future<List<ToolSessionInfo>> _discoverClaudeSessions(
    SshSession session,
    String? workingDirectory,
    int max,
  ) async {
    try {
      // Try to read the global history index first.
      final output = await _exec(
        session,
        'tail -n $max ~/.claude/history.jsonl 2>/dev/null',
      );
      if (output.trim().isEmpty) return const [];

      final sessions = <ToolSessionInfo>[];
      for (final line in output.trim().split('\n').reversed) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          final sessionId = decoded['sessionId'] as String? ?? '';
          if (sessionId.isEmpty) continue;

          sessions.add(
            ToolSessionInfo(
              toolName: 'Claude Code',
              sessionId: sessionId,
              workingDirectory: decoded['directory'] as String?,
              lastActive: decoded['timestamp'] != null
                  ? DateTime.tryParse(decoded['timestamp'] as String)
                  : null,
              summary:
                  decoded['title'] as String? ?? decoded['query'] as String?,
            ),
          );
          if (sessions.length >= max) break;
        } on Exception {
          continue;
        }
      }
      return sessions;
    } on Exception {
      return const [];
    }
  }

  // ── Codex CLI ──────────────────────────────────────────────────────────
  // Sessions: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl

  Future<List<ToolSessionInfo>> _discoverCodexSessions(
    SshSession session,
    int max,
  ) async {
    try {
      final output = await _exec(
        session,
        'find ~/.codex/sessions -name "rollout-*.jsonl" -type f '
        '-exec ls -1t {} + 2>/dev/null | head -n $max',
      );
      if (output.trim().isEmpty) return const [];

      final sessions = <ToolSessionInfo>[];
      for (final line in output.trim().split('\n')) {
        if (line.trim().isEmpty) continue;
        final filePath = line.trim();
        final fileName = filePath.split('/').last.replaceAll('.jsonl', '');

        sessions.add(
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: fileName,
            summary: fileName,
          ),
        );
      }
      return sessions;
    } on Exception {
      return const [];
    }
  }

  // ── Copilot CLI ────────────────────────────────────────────────────────
  // Sessions: ~/.copilot/session-state/<session-id>/

  Future<List<ToolSessionInfo>> _discoverCopilotSessions(
    SshSession session,
    int max,
  ) async {
    try {
      final output = await _exec(
        session,
        'ls -dt ~/.copilot/session-state/*/ 2>/dev/null | head -n $max',
      );
      if (output.trim().isEmpty) return const [];

      final sessions = <ToolSessionInfo>[];
      for (final line in output.trim().split('\n')) {
        if (line.trim().isEmpty) continue;
        // Extract session ID from directory path.
        final dirName = line.trim().split('/').where((s) => s.isNotEmpty).last;

        sessions.add(
          ToolSessionInfo(
            toolName: 'Copilot CLI',
            sessionId: dirName,
            summary: _truncateId(dirName),
          ),
        );
      }
      return sessions;
    } on Exception {
      return const [];
    }
  }

  // ── Gemini CLI ─────────────────────────────────────────────────────────
  // Sessions: ~/.gemini/tmp/<project_hash>/chats/*.json

  Future<List<ToolSessionInfo>> _discoverGeminiSessions(
    SshSession session,
    String? workingDirectory,
    int max,
  ) async {
    try {
      final output = await _exec(
        session,
        'find ~/.gemini/tmp -name "*.json" -path "*/chats/*" -type f '
        '-exec ls -1t {} + 2>/dev/null | head -n $max',
      );
      if (output.trim().isEmpty) return const [];

      final sessions = <ToolSessionInfo>[];
      for (final line in output.trim().split('\n')) {
        if (line.trim().isEmpty) continue;
        final filePath = line.trim();
        final fileName = filePath.split('/').last.replaceAll('.json', '');

        sessions.add(
          ToolSessionInfo(
            toolName: 'Gemini CLI',
            sessionId: fileName,
            summary: _truncateId(fileName),
          ),
        );
      }
      return sessions;
    } on Exception {
      return const [];
    }
  }

  // ── OpenCode ───────────────────────────────────────────────────────────
  // Sessions: ~/.local/share/opencode/storage/session/
  // CLI: opencode session list

  Future<List<ToolSessionInfo>> _discoverOpenCodeSessions(
    SshSession session,
    int max,
  ) async {
    try {
      // Try listing session directories by modification time.
      final output = await _exec(
        session,
        'ls -dt ~/.local/share/opencode/storage/session/*/ 2>/dev/null '
        '| head -n $max',
      );
      if (output.trim().isEmpty) return const [];

      final sessions = <ToolSessionInfo>[];
      for (final line in output.trim().split('\n')) {
        if (line.trim().isEmpty) continue;
        final dirName = line.trim().split('/').where((s) => s.isNotEmpty).last;

        sessions.add(
          ToolSessionInfo(
            toolName: 'OpenCode',
            sessionId: dirName,
            summary: _truncateId(dirName),
          ),
        );
      }
      return sessions;
    } on Exception {
      return const [];
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<String> _exec(SshSession session, String command) async {
    final execSession = await session.execute(command);
    final results = await Future.wait([
      execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
      execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
    ]);
    return results[0];
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  static String _truncateId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 8)}…';
  }
}

/// Provider for [AgentSessionDiscoveryService].
final agentSessionDiscoveryServiceProvider =
    Provider<AgentSessionDiscoveryService>(
      (ref) => const AgentSessionDiscoveryService(),
    );
