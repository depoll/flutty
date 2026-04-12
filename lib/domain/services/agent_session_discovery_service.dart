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
  /// When [workingDirectory] is available, sessions are filtered to that
  /// directory whenever the tool exposes enough path information to do so.
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

    // Filter to sessions matching the working directory if provided.
    if (workingDirectory != null && workingDirectory.isNotEmpty) {
      final filtered = all
          .where(
            (s) =>
                _matchesWorkingDirectory(workingDirectory, s.workingDirectory),
          )
          .toList();
      // Return filtered results if any match; otherwise return all so the UI
      // still has a fallback when the remote tool doesn't persist directory
      // metadata for its sessions.
      if (filtered.isNotEmpty) return filtered;
    }

    return all;
  }

  /// Builds the shell command to resume a specific session.
  ///
  /// If the session has a [ToolSessionInfo.workingDirectory], the command
  /// `cd`s there first so the CLI finds its project context.
  String buildResumeCommand(ToolSessionInfo info) {
    final resume = switch (info.toolName) {
      'Claude Code' => 'claude --resume ${_shellQuote(info.sessionId)}',
      'Codex' => 'codex resume ${_shellQuote(info.sessionId)}',
      'Copilot CLI' => 'copilot --resume ${_shellQuote(info.sessionId)}',
      'Gemini CLI' => 'gemini --resume ${_shellQuote(info.sessionId)}',
      'OpenCode' =>
        info.sessionId == '_continue'
            ? 'opencode --continue'
            : 'opencode --session ${_shellQuote(info.sessionId)}',
      _ => info.toolName.toLowerCase(),
    };

    final dir = info.workingDirectory;
    if (dir != null && dir.isNotEmpty) {
      return 'cd ${_shellQuote(dir)} && $resume';
    }
    return resume;
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
      final seenIds = <String>{};
      for (final line in output.trim().split('\n').reversed) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          final sessionId = decoded['sessionId'] as String? ?? '';
          if (sessionId.isEmpty || seenIds.contains(sessionId)) continue;
          seenIds.add(sessionId);

          // timestamp may be int (epoch ms) or String (ISO 8601).
          DateTime? lastActive;
          final rawTs = decoded['timestamp'];
          if (rawTs is int) {
            lastActive = DateTime.fromMillisecondsSinceEpoch(rawTs);
          } else if (rawTs is String) {
            lastActive = DateTime.tryParse(rawTs);
          }

          String? summary;
          final sessionFile = await _exec(
            session,
            'find ~/.claude/projects -name ${_shellQuote('$sessionId.jsonl')} '
            '-type f 2>/dev/null | head -1',
          );
          final sessionFilePath = sessionFile.trim();
          if (sessionFilePath.isNotEmpty) {
            final customTitle = await _exec(
              session,
              'grep -o \'"customTitle":"[^"]*"\' '
              '${_shellQuote(sessionFilePath)} 2>/dev/null '
              '| tail -1 '
              '| sed \'s/"customTitle":"//;s/"\$//\'',
            );
            final agentName = await _exec(
              session,
              'grep -o \'"agentName":"[^"]*"\' '
              '${_shellQuote(sessionFilePath)} 2>/dev/null '
              '| tail -1 '
              '| sed \'s/"agentName":"//;s/"\$//\'',
            );
            final lastPrompt = await _exec(
              session,
              'grep -o \'"lastPrompt":"[^"]*"\' '
              '${_shellQuote(sessionFilePath)} 2>/dev/null '
              '| tail -1 '
              '| sed \'s/"lastPrompt":"//;s/"\$//\'',
            );
            summary = _firstNonEmpty([
              customTitle.trim(),
              agentName.trim(),
              lastPrompt.trim(),
            ]);
          }

          // Fall back to history index fields.
          final display = decoded['display'] as String?;
          summary ??=
              decoded['title'] as String? ??
              decoded['query'] as String? ??
              (display != null && !display.startsWith('/') ? display : null);

          sessions.add(
            ToolSessionInfo(
              toolName: 'Claude Code',
              sessionId: sessionId,
              workingDirectory:
                  decoded['directory'] as String? ??
                  decoded['project'] as String?,
              lastActive: lastActive,
              summary: summary,
            ),
          );
          if (sessions.length >= max) break;
        } on Object {
          continue;
        }
      }
      return sessions;
    } on Object {
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

        // Read metadata from first line and first real user prompt.
        String? summary;
        String? workingDirectory;
        DateTime? lastActive;
        try {
          final meta = await _exec(
            session,
            'head -1 ${_shellQuote(filePath)} 2>/dev/null',
          );
          if (meta.trim().isNotEmpty) {
            final decoded = jsonDecode(meta.trim());
            if (decoded is Map<String, dynamic>) {
              final payload =
                  decoded['payload'] as Map<String, dynamic>? ?? decoded;
              workingDirectory = payload['cwd'] as String?;
              final ts = decoded['timestamp'] as String?;
              if (ts != null) lastActive = DateTime.tryParse(ts);
            }
          }

          // Extract first prompt: skip session_meta, ignore environment/system
          // context, and take the first short input_text payload.
          final promptOutput = await _exec(
            session,
            'sed -n \'2,20p\' ${_shellQuote(filePath)} '
            '| grep -oE \'"text":"[^"]{1,120}"\' '
            '| grep -v \'"text":"<\' '
            '| grep -v \'"text":"#\' '
            '| head -1 '
            '| sed \'s/"text":"//;s/"\$//\'',
          );
          final prompt = promptOutput.trim();
          if (prompt.isNotEmpty) summary = prompt;
        } on Object {
          // Non-critical.
        }

        summary ??= _truncateId(fileName);

        sessions.add(
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: fileName,
            workingDirectory: workingDirectory,
            lastActive: lastActive,
            summary: summary,
          ),
        );
      }
      return sessions;
    } on Object {
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
        final dirPath = line.trim();
        final dirName = dirPath.split('/').where((s) => s.isNotEmpty).last;

        // Read workspace.yaml for name, summary, and cwd.
        String? summary;
        String? workingDirectory;
        try {
          final yaml = await _exec(
            session,
            'cat ${_shellQuote('${dirPath}workspace.yaml')} 2>/dev/null',
          );
          if (yaml.trim().isNotEmpty) {
            // Simple YAML field extraction (no dependency on yaml parser).
            for (final yamlLine in yaml.split('\n')) {
              final nameMatch = RegExp(r'^name:\s*(.+)').firstMatch(yamlLine);
              if (nameMatch != null) {
                summary = nameMatch.group(1)!.trim();
              }
              final summaryMatch = RegExp(
                r'^summary:\s*(.+)',
              ).firstMatch(yamlLine);
              if (summaryMatch != null && summary == null) {
                summary = summaryMatch.group(1)!.trim();
              }
              final cwdMatch = RegExp(r'^cwd:\s*(.+)').firstMatch(yamlLine);
              if (cwdMatch != null) {
                workingDirectory = cwdMatch.group(1)!.trim();
              }
            }
          }
        } on Object {
          // Non-critical.
        }

        // Fall back to plan.md first line if no name/summary.
        if (summary == null || summary.isEmpty) {
          try {
            final planHead = await _exec(
              session,
              'head -3 ${_shellQuote('${dirPath}plan.md')} 2>/dev/null',
            );
            if (planHead.trim().isNotEmpty) {
              for (final planLine in planHead.trim().split('\n')) {
                final cleaned = planLine
                    .replaceAll(RegExp(r'^#+\s*'), '')
                    .trim();
                if (cleaned.isNotEmpty && cleaned.length > 3) {
                  summary = cleaned.length > 80
                      ? '${cleaned.substring(0, 77)}...'
                      : cleaned;
                  break;
                }
              }
            }
          } on Object {
            // Non-critical.
          }
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'Copilot CLI',
            sessionId: dirName,
            workingDirectory: workingDirectory,
            summary: summary ?? _truncateId(dirName),
          ),
        );
      }
      return sessions;
    } on Object {
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

        // Extract project directory name from path.
        // Path: ~/.gemini/tmp/<project_dir>/chats/<file>.json
        final pathParts = filePath.split('/');
        final chatsIdx = pathParts.indexOf('chats');
        final projectDir = chatsIdx > 0 ? pathParts[chatsIdx - 1] : null;
        final sessionWorkingDirectory =
            projectDir != null &&
                workingDirectory != null &&
                _lastPathSegment(workingDirectory) == projectDir
            ? workingDirectory
            : null;

        // Try to read the first user message as summary.
        String? summary;
        try {
          final firstMsg = await _exec(
            session,
            'grep -o \'"text":"[^"]*"\' ${_shellQuote(filePath)} '
            '| head -1 '
            '| sed \'s/"text":"//;s/"\$//\'',
          );
          final text = firstMsg.trim();
          if (text.isNotEmpty && text.length > 1) {
            summary = text.length > 80 ? '${text.substring(0, 77)}...' : text;
          }
        } on Object {
          // Non-critical.
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'Gemini CLI',
            sessionId: fileName,
            workingDirectory: sessionWorkingDirectory,
            summary: summary ?? projectDir ?? _truncateId(fileName),
          ),
        );
      }
      return sessions;
    } on Object {
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
      // List session JSON files directly (more reliable than dirs).
      final output = await _exec(
        session,
        'find ~/.local/share/opencode/storage/session -name "ses_*.json" '
        '-type f -exec ls -1t {} + 2>/dev/null | head -n $max',
      );
      if (output.trim().isEmpty) return const [];

      final sessions = <ToolSessionInfo>[];
      for (final line in output.trim().split('\n')) {
        if (line.trim().isEmpty) continue;
        final filePath = line.trim();
        final fileName = filePath.split('/').last.replaceAll('.json', '');

        // Read the session JSON for title and directory.
        String? summary;
        String? workingDirectory;
        DateTime? lastActive;
        try {
          final content = await _exec(
            session,
            'head -c 500 ${_shellQuote(filePath)} 2>/dev/null',
          );
          if (content.trim().isNotEmpty) {
            // Parse partial JSON — title/directory are near the top.
            // Full parse may fail on truncated content, so extract fields.
            final titleMatch = RegExp(
              r'"title"\s*:\s*"([^"]*)"',
            ).firstMatch(content);
            final dirMatch = RegExp(
              r'"directory"\s*:\s*"([^"]*)"',
            ).firstMatch(content);
            summary = titleMatch?.group(1);
            workingDirectory = dirMatch?.group(1);
          }
        } on Object {
          // Non-critical.
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'OpenCode',
            sessionId: fileName,
            workingDirectory: workingDirectory,
            lastActive: lastActive,
            summary: summary ?? _truncateId(fileName),
          ),
        );
      }
      return sessions;
    } on Object {
      return const [];
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<String> _exec(SshSession session, String command) async {
    final execSession = await session.execute(command);
    final results = await Future.wait([
      execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
      execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
    ]).timeout(const Duration(seconds: 10), onTimeout: () => ['', '']);
    return results[0];
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static bool _matchesWorkingDirectory(
    String expectedDirectory,
    String? sessionDirectory,
  ) {
    if (sessionDirectory == null || sessionDirectory.isEmpty) return false;
    return sessionDirectory == expectedDirectory ||
        _lastPathSegment(sessionDirectory) ==
            _lastPathSegment(expectedDirectory);
  }

  static String _lastPathSegment(String path) =>
      path.split('/').where((segment) => segment.isNotEmpty).lastOrNull ?? path;

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
