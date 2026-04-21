import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tmux_state.dart';
import 'ssh_service.dart';

const _genericSessionSummaries = <String>{
  'untitled',
  'unnamed',
  'untitled session',
  'new session',
  'empty session',
  'session',
};

const _profileSourcingPrefix =
    '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } '
    '>/dev/null 2>&1; ';

/// Filters noisy discovered sessions and fills in a better display summary
/// when the tool only exposes a working directory.
@visibleForTesting
ToolSessionInfo? normalizeDiscoveredSessionInfo(
  ToolSessionInfo info, {
  String? activeWorkingDirectory,
}) {
  final normalizedSummary = _normalizeDiscoveredSessionSummary(
    info,
    activeWorkingDirectory: activeWorkingDirectory,
  );
  if (normalizedSummary == null) return null;
  return ToolSessionInfo(
    toolName: info.toolName,
    sessionId: info.sessionId,
    workingDirectory: info.workingDirectory,
    lastActive: info.lastActive,
    summary: normalizedSummary,
  );
}

/// Orders sessions from most to least recently updated, leaving untimestamped
/// items at the end.
@visibleForTesting
int compareDiscoveredSessionsByRecency(ToolSessionInfo a, ToolSessionInfo b) {
  final aTime = a.lastActive;
  final bTime = b.lastActive;
  if (aTime != null && bTime != null) {
    final compare = bTime.compareTo(aTime);
    if (compare != 0) return compare;
  } else if (aTime != null) {
    return -1;
  } else if (bTime != null) {
    return 1;
  }

  final toolCompare = a.toolName.compareTo(b.toolName);
  if (toolCompare != 0) return toolCompare;
  return (a.summary ?? '').compareTo(b.summary ?? '');
}

/// Discovered session results plus any tool histories that could not be read.
class DiscoveredSessionsResult {
  /// Creates a new [DiscoveredSessionsResult].
  DiscoveredSessionsResult({
    required Iterable<ToolSessionInfo> sessions,
    Iterable<String> failedTools = const <String>[],
  }) : sessions = List<ToolSessionInfo>.unmodifiable(sessions),
       failedTools = Set<String>.unmodifiable(failedTools);

  /// The sessions that were discovered successfully.
  final List<ToolSessionInfo> sessions;

  /// Tool names whose session history could not be loaded.
  final Set<String> failedTools;

  /// Whether any tool histories failed to load.
  bool get hasFailures => failedTools.isNotEmpty;

  /// A human-readable failure message for the UI.
  String? get failureMessage {
    if (failedTools.isEmpty) return null;
    final orderedTools = failedTools.toList()..sort();
    if (orderedTools.length == 1) {
      return 'Could not load ${orderedTools.first} sessions.';
    }
    final lastTool = orderedTools.removeLast();
    return 'Could not load ${orderedTools.join(', ')} and $lastTool sessions.';
  }
}

/// Whether a tool-level discovery issue should be surfaced to the UI.
///
/// Partial parse issues should stay silent when the tool still yielded usable
/// sessions, so users only see a failure banner when a tool's history could not
/// be loaded at all.
@visibleForTesting
bool shouldSurfaceDiscoveryFailure({
  required bool hadError,
  required int loadedSessionCount,
}) => hadError && loadedSessionCount == 0;

String? _normalizeDiscoveredSessionSummary(
  ToolSessionInfo info, {
  String? activeWorkingDirectory,
}) {
  final normalizedSummary = _sanitizeSessionSummary(
    info.summary,
    sessionId: info.sessionId,
    workingDirectory: info.workingDirectory,
  );
  if (normalizedSummary != null) return normalizedSummary;
  return _directorySummaryFallback(
    info.workingDirectory,
    activeWorkingDirectory: activeWorkingDirectory,
  );
}

String? _sanitizeSessionSummary(
  String? value, {
  required String sessionId,
  String? workingDirectory,
}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final unquoted = trimmed
      .replaceAll(RegExp(r"""^["'`]+|["'`]+$"""), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (unquoted.isEmpty) return null;

  final lowered = unquoted.toLowerCase();
  if (_genericSessionSummaries.contains(lowered) ||
      lowered == sessionId.toLowerCase() ||
      lowered == _truncateSessionIdValue(sessionId).toLowerCase()) {
    return null;
  }

  final workingDirectorySummary = _directorySummaryFallback(workingDirectory);
  if (workingDirectorySummary != null &&
      lowered == workingDirectorySummary.toLowerCase()) {
    return null;
  }

  final strippedSeparators = unquoted.replaceAll(
    RegExp(r'[\s\-_./\\[\](){}:;,*"`~]+'),
    '',
  );
  if (strippedSeparators.isEmpty) return null;
  return unquoted;
}

String? _directorySummaryFallback(
  String? workingDirectory, {
  String? activeWorkingDirectory,
}) {
  final trimmed = workingDirectory?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (activeWorkingDirectory != null &&
      activeWorkingDirectory.isNotEmpty &&
      AgentSessionDiscoveryService._matchesWorkingDirectory(
        activeWorkingDirectory,
        trimmed,
      )) {
    return null;
  }
  final segment = _pathLastSegment(trimmed);
  if (segment.isEmpty || segment == '.' || segment == '~') return null;
  return segment;
}

String _pathLastSegment(String path) =>
    path.split('/').where((segment) => segment.isNotEmpty).lastOrNull ?? path;

String _truncateSessionIdValue(String id) {
  if (id.length <= 12) return id;
  return '${id.substring(0, 8)}…';
}

String _summarizeSessionText(String value, {int maxLength = 80}) {
  final firstMeaningfulLine = value
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => value.trim());
  final collapsed = firstMeaningfulLine.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= maxLength) return collapsed;
  return '${collapsed.substring(0, maxLength - 3)}...';
}

String? _extractPlanSummary(String raw) {
  for (final line in const LineSplitter().convert(raw)) {
    final cleaned = line.replaceAll(RegExp(r'^#+\s*'), '').trim();
    if (cleaned.isNotEmpty && cleaned.length > 3) {
      return _summarizeSessionText(cleaned);
    }
  }
  return null;
}

int _calculateDiscoveryScanLimit(
  int maxPerTool, {
  int multiplier = 5,
  int minimum = 60,
  int maximum = 180,
}) {
  final scaledLimit = maxPerTool * multiplier;
  if (scaledLimit < minimum) return minimum;
  if (scaledLimit > maximum) return maximum;
  return scaledLimit;
}

/// Parses Copilot CLI workspace metadata from `workspace.yaml`.
@visibleForTesting
({String? summary, String? workingDirectory, DateTime? updatedAt})
parseCopilotWorkspaceYamlMetadata(String raw) {
  final lines = const LineSplitter().convert(raw);
  String? summary;
  String? workingDirectory;
  DateTime? updatedAt;

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];

    if (workingDirectory == null) {
      final cwdMatch = RegExp(r'^cwd:\s*(.+)\s*$').firstMatch(line);
      if (cwdMatch != null) {
        workingDirectory = cwdMatch.group(1)!.trim();
      }
    }

    if (updatedAt == null) {
      final updatedAtMatch = RegExp(
        r'^updated_at:\s*(.+)\s*$',
      ).firstMatch(line);
      if (updatedAtMatch != null) {
        updatedAt = DateTime.tryParse(updatedAtMatch.group(1)!.trim());
      }
    }

    if (summary != null) continue;
    final summaryMatch = RegExp(r'^summary:\s*(.*)$').firstMatch(line);
    if (summaryMatch == null) continue;

    final inlineValue = summaryMatch.group(1)!.trimRight();
    if (inlineValue.isEmpty) continue;
    if (inlineValue == '|' ||
        inlineValue == '|-' ||
        inlineValue == '>' ||
        inlineValue == '>-') {
      final blockLines = <String>[];
      while (index + 1 < lines.length) {
        final nextLine = lines[index + 1];
        if (!nextLine.startsWith('  ')) break;
        index += 1;
        blockLines.add(nextLine.substring(2));
      }
      final blockValue = blockLines.join('\n').trim();
      if (blockValue.isNotEmpty) {
        summary = _summarizeSessionText(blockValue);
      }
      continue;
    }

    final normalizedInlineValue = inlineValue.trim();
    if (normalizedInlineValue.isNotEmpty) {
      summary = _summarizeSessionText(normalizedInlineValue);
    }
  }

  return (
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
  );
}

/// Parses Codex rollout metadata from the head of a rollout JSONL file.
@visibleForTesting
({
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool parsedAny,
})
parseCodexRolloutMetadata(String raw) {
  String? summary;
  String? workingDirectory;
  DateTime? updatedAt;
  var parsedAny = false;

  for (final line in const LineSplitter().convert(raw)) {
    final decoded = _tryDecodeJsonObject(line);
    if (decoded == null) continue;
    parsedAny = true;

    final payload = _readMapField(decoded, 'payload');
    workingDirectory ??=
        _readStringField(payload, 'cwd') ?? _readStringField(decoded, 'cwd');
    updatedAt ??= _parseDateTimeValue(decoded['timestamp']);

    if (summary != null) continue;
    if (_readStringField(decoded, 'type') != 'event_msg' ||
        _readStringField(payload, 'type') != 'user_message') {
      continue;
    }

    final message = _readStringField(payload, 'message');
    if (message != null && message.trim().isNotEmpty) {
      summary = _summarizeSessionText(message);
    }
  }

  return (
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
    parsedAny: parsedAny,
  );
}

/// Parses Claude session metadata from a saved JSONL transcript.
@visibleForTesting
({
  String? customTitle,
  String? agentName,
  String? lastPrompt,
  String? userSummary,
  bool parsedAny,
})
parseClaudeSessionMetadata(String raw) {
  String? customTitle;
  String? agentName;
  String? lastPrompt;
  String? userSummary;
  var parsedAny = false;

  for (final line in const LineSplitter().convert(raw)) {
    final decoded = _tryDecodeJsonObject(line);
    if (decoded == null) continue;
    parsedAny = true;

    customTitle = _readStringField(decoded, 'customTitle') ?? customTitle;
    agentName = _readStringField(decoded, 'agentName') ?? agentName;
    lastPrompt = _readStringField(decoded, 'lastPrompt') ?? lastPrompt;

    if (userSummary != null ||
        _readStringField(decoded, 'type') != 'user' ||
        decoded['isMeta'] == true) {
      continue;
    }

    final message = _readMapField(decoded, 'message');
    userSummary = _extractClaudeUserSummary(
      _readStringField(message, 'content'),
    );
  }

  return (
    customTitle: customTitle,
    agentName: agentName,
    lastPrompt: lastPrompt,
    userSummary: userSummary,
    parsedAny: parsedAny,
  );
}

/// Parses Gemini session metadata from a saved chat JSON file.
@visibleForTesting
({
  String? sessionId,
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool isSubagent,
  bool parsedAny,
})
parseGeminiSessionMetadata(
  String raw, {
  String? activeWorkingDirectory,
  String? fallbackWorkingDirectory,
}) {
  final decoded = _decodeJsonOrJsonlObject(raw);
  if (decoded == null) {
    return (
      sessionId: null,
      summary: null,
      workingDirectory: fallbackWorkingDirectory,
      updatedAt: null,
      isSubagent: false,
      parsedAny: false,
    );
  }

  final storedSummary = _readStringField(decoded, 'summary');
  final summary = (storedSummary?.trim().isNotEmpty ?? false)
      ? _summarizeSessionText(storedSummary!)
      : _extractGeminiUserSummary(_readListField(decoded, 'messages'));
  final directories = _readListField(decoded, 'directories');
  final resolvedWorkingDirectory =
      _resolveGeminiWorkingDirectory(
        directories,
        activeWorkingDirectory: activeWorkingDirectory,
      ) ??
      fallbackWorkingDirectory;

  return (
    sessionId: _readStringField(decoded, 'sessionId'),
    summary: summary,
    workingDirectory: resolvedWorkingDirectory,
    updatedAt:
        _parseDateTimeValue(decoded['lastUpdated']) ??
        _parseDateTimeValue(decoded['startTime']),
    isSubagent: _readStringField(decoded, 'kind') == 'subagent',
    parsedAny: true,
  );
}

String? _trimWorkingDirectory(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final withoutTrailingSlash = trimmed.length > 1 && trimmed.endsWith('/')
      ? trimmed.replaceFirst(RegExp(r'/+$'), '')
      : trimmed;
  return withoutTrailingSlash.replaceAll(RegExp('/+'), '/');
}

/// Normalizes a working directory for cross-worktree comparisons.
///
/// Paths under `repo.worktrees/<branch>/...` are normalized to `repo/...` so
/// sessions from sibling checkouts can still match the active project scope.
@visibleForTesting
String normalizeWorkingDirectoryForComparison(String value) {
  final trimmed = _trimWorkingDirectory(value);
  if (trimmed == null) return value.trim();

  final segments = trimmed.split('/');
  final normalizedSegments = <String>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (segment.endsWith('.worktrees') && index + 1 < segments.length) {
      normalizedSegments.add(
        segment.substring(0, segment.length - '.worktrees'.length),
      );
      index += 1;
      continue;
    }
    normalizedSegments.add(segment);
  }

  final normalized = normalizedSegments.join('/');
  return trimmed.startsWith('/') && !normalized.startsWith('/')
      ? '/$normalized'
      : normalized;
}

String? _relativeWorkingDirectoryPath(String child, String root) {
  if (child == root) return '';
  final prefix = '$root/';
  if (!child.startsWith(prefix)) return null;
  return child.substring(prefix.length);
}

String _joinWorkingDirectoryPath(String root, String relativePath) =>
    relativePath.isEmpty ? root : '$root/$relativePath';

bool _workingDirectoriesOverlap(String a, String b) =>
    a == b || a.startsWith('$b/') || b.startsWith('$a/');

/// Parses `git worktree list --porcelain` output into root paths.
@visibleForTesting
List<String> parseGitWorktreeRoots(String raw) {
  final roots = <String>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (!line.startsWith('worktree ')) continue;
    final root = _trimWorkingDirectory(line.substring('worktree '.length));
    if (root != null) roots.add(root);
  }
  return roots;
}

/// Builds all directories that should be treated as the active project scope.
///
/// This includes the active directory itself, the normalized `.worktrees`
/// equivalent, the git worktree roots when available, and corresponding
/// subdirectories across sibling worktrees.
@visibleForTesting
List<String> buildRelatedWorkingDirectories(
  String activeWorkingDirectory, {
  String? gitRoot,
  Iterable<String> gitWorktreeRoots = const <String>[],
}) {
  final trimmedActive = _trimWorkingDirectory(activeWorkingDirectory);
  if (trimmedActive == null) return const <String>[];

  final directories = <String>{};

  void addDirectory(String? directory) {
    final trimmed = _trimWorkingDirectory(directory);
    if (trimmed == null) return;
    directories
      ..add(trimmed)
      ..add(normalizeWorkingDirectoryForComparison(trimmed));
  }

  addDirectory(trimmedActive);

  final trimmedGitRoot = _trimWorkingDirectory(gitRoot);
  final relativePath = trimmedGitRoot == null
      ? null
      : _relativeWorkingDirectoryPath(trimmedActive, trimmedGitRoot);

  addDirectory(trimmedGitRoot);

  if (relativePath != null && relativePath.isNotEmpty) {
    for (final root in gitWorktreeRoots) {
      final trimmedRoot = _trimWorkingDirectory(root);
      if (trimmedRoot == null) continue;
      addDirectory(_joinWorkingDirectoryPath(trimmedRoot, relativePath));
    }
  }

  for (final root in gitWorktreeRoots) {
    addDirectory(root);
  }

  return directories.toList(growable: false);
}

/// Whether a discovered session directory belongs to the active project scope.
@visibleForTesting
bool matchesDiscoveredSessionWorkingDirectory(
  String expectedWorkingDirectory,
  String? sessionDirectory, {
  Iterable<String> relatedWorkingDirectories = const <String>[],
}) {
  final trimmedSessionDirectory = _trimWorkingDirectory(sessionDirectory);
  if (trimmedSessionDirectory == null) return false;
  final comparableSessionDirectory = normalizeWorkingDirectoryForComparison(
    trimmedSessionDirectory,
  );
  final candidates = relatedWorkingDirectories.isNotEmpty
      ? relatedWorkingDirectories
      : <String>[expectedWorkingDirectory];
  for (final candidate in candidates) {
    final trimmedCandidate = _trimWorkingDirectory(candidate);
    if (trimmedCandidate == null) continue;
    final comparableCandidate = normalizeWorkingDirectoryForComparison(
      trimmedCandidate,
    );
    if (_workingDirectoriesOverlap(
      comparableCandidate,
      comparableSessionDirectory,
    )) {
      return true;
    }
  }
  return false;
}

/// Resolves a Gemini project directory label to a concrete worktree path.
@visibleForTesting
String? resolveGeminiProjectWorkingDirectory(
  String? projectDirectoryName,
  Iterable<String> relatedWorkingDirectories,
) {
  final trimmedProjectDirectoryName = projectDirectoryName?.trim();
  if (trimmedProjectDirectoryName == null ||
      trimmedProjectDirectoryName.isEmpty) {
    return null;
  }

  for (final directory in relatedWorkingDirectories) {
    final trimmedDirectory = _trimWorkingDirectory(directory);
    if (trimmedDirectory == null) continue;
    if (_pathLastSegment(trimmedDirectory) == trimmedProjectDirectoryName) {
      return trimmedDirectory;
    }
  }
  return null;
}

/// Builds the CLI working-directory scopes Gemini should be queried from.
///
/// When no directory context is available, returns a single `null` scope so the
/// CLI still runs once in the default shell cwd instead of being skipped.
@visibleForTesting
List<String?> buildGeminiCliSessionListScopes(
  String? workingDirectory,
  Iterable<String> relatedWorkingDirectories,
) {
  final scopes = <String?>{};
  final trimmedWorkingDirectory = _trimWorkingDirectory(workingDirectory);
  if (trimmedWorkingDirectory != null) {
    scopes.add(trimmedWorkingDirectory);
  }

  for (final directory in relatedWorkingDirectories) {
    final trimmedDirectory = _trimWorkingDirectory(directory);
    if (trimmedDirectory != null) {
      scopes.add(trimmedDirectory);
    }
  }

  if (scopes.isEmpty) {
    return const <String?>[null];
  }
  return scopes.toList(growable: false);
}

/// Sorts merged discovery sessions by recency before applying a scan cap.
@visibleForTesting
List<ToolSessionInfo> sortAndLimitDiscoveredSessions(
  Iterable<ToolSessionInfo> sessions,
  int limit,
) {
  final sortedSessions = sessions.toList(growable: false)
    ..sort(compareDiscoveredSessionsByRecency);
  return sortedSessions.take(limit).toList(growable: false);
}

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
  /// Each tool's sessions are discovered separately, normalized to drop
  /// noisy placeholder entries, and then sorted globally by recency.
  /// Limits to [maxPerTool] sessions per tool to keep results manageable.
  ///
  /// Returns both the successfully parsed sessions and any tool histories that
  /// could not be loaded, so the UI can distinguish parse failures from an
  /// actually empty history.
  ///
  /// When [workingDirectory] is available, sessions are filtered to that
  /// directory whenever the tool exposes enough path information to do so.
  Future<DiscoveredSessionsResult> discoverSessions(
    SshSession session, {
    String? workingDirectory,
    int maxPerTool = 12,
  }) async {
    final relatedWorkingDirectories = await _resolveRelatedWorkingDirectories(
      session,
      workingDirectory,
    );
    final results = await Future.wait([
      _discoverClaudeSessions(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        maxPerTool,
      ),
      _discoverCodexSessions(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        maxPerTool,
      ),
      _discoverCopilotSessions(session, relatedWorkingDirectories, maxPerTool),
      _discoverGeminiSessions(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        maxPerTool,
      ),
      _discoverOpenCodeSessions(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        maxPerTool,
      ),
    ]);

    final all = results
        .expand((result) => result.sessions)
        .map(
          (info) => normalizeDiscoveredSessionInfo(
            info,
            activeWorkingDirectory: workingDirectory,
          ),
        )
        .whereType<ToolSessionInfo>()
        .toList();

    // Filter to sessions matching the working directory if provided.
    if (workingDirectory != null && workingDirectory.isNotEmpty) {
      final filtered = _limitDiscoveredSessionsPerTool(
        all
            .where(
              (s) => matchesDiscoveredSessionWorkingDirectory(
                workingDirectory,
                s.workingDirectory,
                relatedWorkingDirectories: relatedWorkingDirectories,
              ),
            )
            .toList(),
        maxPerTool,
      );
      // Return filtered results if any match; otherwise return all so the UI
      // still has a fallback when the remote tool doesn't persist directory
      // metadata for its sessions.
      if (filtered.isNotEmpty) {
        return DiscoveredSessionsResult(
          sessions: filtered,
          failedTools: results
              .where(
                (r) => shouldSurfaceDiscoveryFailure(
                  hadError: r.hadError,
                  loadedSessionCount: r.sessions.length,
                ),
              )
              .map((r) => r.toolName),
        );
      }
    }

    return DiscoveredSessionsResult(
      sessions: _limitDiscoveredSessionsPerTool(all, maxPerTool),
      failedTools: results
          .where(
            (r) => shouldSurfaceDiscoveryFailure(
              hadError: r.hadError,
              loadedSessionCount: r.sessions.length,
            ),
          )
          .map((r) => r.toolName),
    );
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

  Future<_ToolDiscoveryResult> _discoverClaudeSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max,
  ) async {
    try {
      // Read more lines than needed to account for duplicate sessionIds
      // (e.g. multiple history entries for the same active session).
      final tailCount = _calculateDiscoveryScanLimit(
        max,
        multiplier: 20,
        minimum: 120,
        maximum: 400,
      );
      final output = await _exec(
        session,
        'tail -n $tailCount ~/.claude/history.jsonl 2>/dev/null',
      );
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Claude Code', []);
      }

      final historyEntries = <Map<String, dynamic>>[];
      final seenIds = <String>{};
      for (final line in output.trim().split('\n').reversed) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          final sessionId = decoded['sessionId'] as String? ?? '';
          if (sessionId.isEmpty || seenIds.contains(sessionId)) continue;
          seenIds.add(sessionId);
          historyEntries.add(decoded);
        } on Object {
          // Ignore malformed lines.
        }
      }

      final scopedHistoryEntries =
          workingDirectory != null && workingDirectory.isNotEmpty
          ? historyEntries
                .where(
                  (entry) => matchesDiscoveredSessionWorkingDirectory(
                    workingDirectory,
                    entry['directory'] as String? ??
                        entry['project'] as String?,
                    relatedWorkingDirectories: relatedWorkingDirectories,
                  ),
                )
                .toList(growable: false)
          : historyEntries;
      final relevantHistoryEntries = scopedHistoryEntries.isNotEmpty
          ? scopedHistoryEntries
          : historyEntries;
      final sessionFilesById = await _findClaudeSessionFiles(
        session,
        relevantHistoryEntries.map(
          (entry) => entry['sessionId'] as String? ?? '',
        ),
      );
      final sessionFileHeadSnapshots = await _readRemoteFileSnapshots(
        session,
        sessionFilesById.values,
        maxLines: 120,
      );
      final sessionFileTailSnapshots = await _readRemoteFileSnapshots(
        session,
        sessionFilesById.values,
        maxLines: 120,
        tail: true,
      );
      final sessions = <ToolSessionInfo>[];
      var hadError = false;
      for (final decoded in relevantHistoryEntries) {
        try {
          final sessionId = decoded['sessionId'] as String? ?? '';
          if (sessionId.isEmpty) continue;

          // timestamp may be int (epoch ms) or String (ISO 8601).
          DateTime? lastActive;
          final rawTs = decoded['timestamp'];
          if (rawTs is int) {
            lastActive = DateTime.fromMillisecondsSinceEpoch(rawTs);
          } else if (rawTs is String) {
            lastActive = DateTime.tryParse(rawTs);
          }

          String? summary;
          final sessionFilePath = sessionFilesById[sessionId] ?? '';
          if (sessionFilePath.isNotEmpty) {
            final headSnapshot = sessionFileHeadSnapshots[sessionFilePath];
            final tailSnapshot = sessionFileTailSnapshots[sessionFilePath];
            final snapshot = tailSnapshot ?? headSnapshot;
            lastActive ??= snapshot?.modifiedAt;
            final combinedContent = switch ((headSnapshot, tailSnapshot)) {
              (null, null) => '',
              (final head?, null) => head.content,
              (null, final tail?) => tail.content,
              (final head?, final tail?) =>
                head.content == tail.content
                    ? head.content
                    : '${head.content}\n${tail.content}',
            };
            final metadata = parseClaudeSessionMetadata(combinedContent);
            if (combinedContent.trim().isNotEmpty && !metadata.parsedAny) {
              hadError = true;
            }
            summary = _firstNonEmpty([
              metadata.customTitle,
              metadata.agentName,
              metadata.lastPrompt,
              metadata.userSummary,
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
        } on Object {
          hadError = true;
          continue;
        }
      }
      return _ToolDiscoveryResult.success(
        'Claude Code',
        sortAndLimitDiscoveredSessions(sessions, tailCount),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Claude Code');
    }
  }

  // ── Codex CLI ──────────────────────────────────────────────────────────
  // Sessions: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl

  Future<_ToolDiscoveryResult> _discoverCodexSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max,
  ) async {
    try {
      final scanLimit = _calculateDiscoveryScanLimit(
        max,
        multiplier: 10,
        maximum: 120,
      );
      final output = await _exec(
        session,
        'find ~/.codex/sessions -name "rollout-*.jsonl" -type f '
        '-exec ls -1t {} + 2>/dev/null | head -n $scanLimit',
      );
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Codex', []);
      }

      final sessionIndex = await _readCodexSessionIndex(session, scanLimit);
      final rolloutPaths = output
          .trim()
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      final rolloutSnapshots = await _readRemoteFileSnapshots(
        session,
        rolloutPaths,
        maxLines: 80,
      );
      final sessions = <ToolSessionInfo>[];
      var hadError = sessionIndex.hadError;

      for (final filePath in rolloutPaths) {
        final fileName = filePath.split('/').last.replaceAll('.jsonl', '');
        final threadId = _extractCodexThreadId(fileName);
        final threadInfo = threadId != null
            ? sessionIndex.entries[threadId]
            : null;

        var summary = threadInfo?.threadName;
        String? sessionWorkingDirectory;
        var lastActive = threadInfo?.updatedAt;

        final snapshot = rolloutSnapshots[filePath];
        if (snapshot == null) {
          hadError = true;
        } else {
          try {
            final metadata = parseCodexRolloutMetadata(snapshot.content);
            if (snapshot.content.trim().isNotEmpty && !metadata.parsedAny) {
              hadError = true;
            }
            summary ??= metadata.summary;
            sessionWorkingDirectory = metadata.workingDirectory;
            lastActive ??= metadata.updatedAt;
          } on Object {
            hadError = true;
          }
          lastActive ??= snapshot.modifiedAt;
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: fileName,
            workingDirectory: sessionWorkingDirectory,
            lastActive: lastActive,
            summary: summary ?? _truncateId(fileName),
          ),
        );
      }
      final scopedSessions =
          workingDirectory != null && workingDirectory.isNotEmpty
          ? sessions
                .where(
                  (info) => matchesDiscoveredSessionWorkingDirectory(
                    workingDirectory,
                    info.workingDirectory,
                    relatedWorkingDirectories: relatedWorkingDirectories,
                  ),
                )
                .toList(growable: false)
          : sessions;
      return _ToolDiscoveryResult.success(
        'Codex',
        sortAndLimitDiscoveredSessions(
          scopedSessions.isNotEmpty ? scopedSessions : sessions,
          scanLimit,
        ),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Codex');
    }
  }

  Future<_CodexSessionIndexResult> _readCodexSessionIndex(
    SshSession session,
    int scanLimit,
  ) async {
    try {
      final output = await _exec(
        session,
        'tail -n ${scanLimit * 5} ~/.codex/session_index.jsonl 2>/dev/null',
      );
      if (output.trim().isEmpty) {
        return const _CodexSessionIndexResult(entries: {});
      }

      final entries = <String, _CodexSessionIndexEntry>{};
      var hadError = false;
      for (final line in output.trim().split('\n').reversed) {
        if (line.trim().isEmpty) continue;
        final decoded = _tryDecodeJsonObject(line);
        if (decoded == null) {
          hadError = true;
          continue;
        }
        final id = _readStringField(decoded, 'id');
        if (id == null || id.isEmpty || entries.containsKey(id)) continue;
        entries[id] = _CodexSessionIndexEntry(
          threadName: _readStringField(decoded, 'thread_name'),
          updatedAt: _parseDateTimeValue(decoded['updated_at']),
        );
      }
      return _CodexSessionIndexResult(entries: entries, hadError: hadError);
    } on Object {
      return const _CodexSessionIndexResult(entries: {}, hadError: true);
    }
  }

  // ── Copilot CLI ────────────────────────────────────────────────────────
  // Sessions: ~/.copilot/session-state/<session-id>/

  Future<_ToolDiscoveryResult> _discoverCopilotSessions(
    SshSession session,
    List<String> relatedWorkingDirectories,
    int max,
  ) async {
    try {
      final scanLimit = _calculateDiscoveryScanLimit(
        max,
        multiplier: 20,
        minimum: 120,
        maximum: 240,
      );
      final workspacePaths = await _listCopilotWorkspacePaths(
        session,
        scanLimit,
        relatedWorkingDirectories,
      );
      if (workspacePaths.isEmpty) {
        return const _ToolDiscoveryResult.success('Copilot CLI', []);
      }

      final workspaceSnapshots = await _readRemoteFileSnapshots(
        session,
        workspacePaths,
      );
      final planPathsNeedingFallback = <String>[];
      final metadataByWorkspacePath =
          <
            String,
            ({String? summary, String? workingDirectory, DateTime? updatedAt})
          >{};
      var hadError = false;

      for (final workspacePath in workspacePaths) {
        final dirPath = workspacePath.replaceFirst(
          RegExp(r'/workspace\.yaml$'),
          '/',
        );
        final snapshot = workspaceSnapshots[workspacePath];
        if (snapshot == null) {
          hadError = true;
          metadataByWorkspacePath[workspacePath] = (
            summary: null,
            workingDirectory: null,
            updatedAt: null,
          );
          planPathsNeedingFallback.add('${dirPath}plan.md');
          continue;
        }

        try {
          final metadata = parseCopilotWorkspaceYamlMetadata(snapshot.content);
          metadataByWorkspacePath[workspacePath] = metadata;
          if (metadata.summary?.isEmpty ?? true) {
            planPathsNeedingFallback.add('${dirPath}plan.md');
          }
        } on Object {
          hadError = true;
          metadataByWorkspacePath[workspacePath] = (
            summary: null,
            workingDirectory: null,
            updatedAt: snapshot.modifiedAt,
          );
          planPathsNeedingFallback.add('${dirPath}plan.md');
        }
      }

      final planSnapshots = await _readRemoteFileSnapshots(
        session,
        planPathsNeedingFallback,
        maxLines: 3,
      );
      final sessions = <ToolSessionInfo>[];

      for (final workspacePath in workspacePaths) {
        final metadata = metadataByWorkspacePath[workspacePath];
        final snapshot = workspaceSnapshots[workspacePath];
        if (metadata == null) {
          hadError = true;
          continue;
        }

        final dirPath = workspacePath.replaceFirst(
          RegExp(r'/workspace\.yaml$'),
          '/',
        );
        final dirName = dirPath.split('/').where((s) => s.isNotEmpty).last;
        final planSnapshot = planSnapshots['${dirPath}plan.md'];
        final fallbackSummary = planSnapshot == null
            ? null
            : _extractPlanSummary(planSnapshot.content);

        sessions.add(
          ToolSessionInfo(
            toolName: 'Copilot CLI',
            sessionId: dirName,
            workingDirectory: metadata.workingDirectory,
            lastActive: metadata.updatedAt ?? snapshot?.modifiedAt,
            summary:
                metadata.summary ?? fallbackSummary ?? _truncateId(dirName),
          ),
        );
      }

      return _ToolDiscoveryResult.success(
        'Copilot CLI',
        sortAndLimitDiscoveredSessions(sessions, scanLimit),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Copilot CLI');
    }
  }

  // ── Gemini CLI ─────────────────────────────────────────────────────────
  // `gemini --list-sessions` outputs a human-readable list scoped to
  // the current project. Each line looks like:
  //   1. Title text (time ago) [session-uuid]
  // Falls back to scanning chat JSON files if the CLI is unavailable.

  Future<_ToolDiscoveryResult> _discoverGeminiSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max,
  ) async {
    try {
      final searchDirectories = buildGeminiCliSessionListScopes(
        workingDirectory,
        relatedWorkingDirectories,
      );

      var hadError = false;
      final sessionsById = <String, ToolSessionInfo>{};

      for (final searchDirectory in searchDirectories) {
        try {
          final cliCommand = searchDirectory == null
              ? 'gemini --list-sessions 2>/dev/null'
              : '[ -d ${_shellQuote(searchDirectory)} ] && '
                    'cd ${_shellQuote(searchDirectory)} && '
                    'gemini --list-sessions 2>/dev/null';
          final cliOutput = await _exec(session, cliCommand);
          if (!cliOutput.contains('[') || !cliOutput.contains(']')) continue;
          final parsed = _parseGeminiCliOutput(cliOutput, searchDirectory);
          for (final info in parsed) {
            _mergeToolSessionInfo(sessionsById, info);
          }
        } on Object {
          hadError = true;
        }
      }

      final fallback = await _discoverGeminiSessionsFromFiles(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        max,
      );
      hadError = hadError || fallback.hadError;
      for (final info in fallback.sessions) {
        _mergeToolSessionInfo(sessionsById, info);
      }

      return _ToolDiscoveryResult.success(
        'Gemini CLI',
        sortAndLimitDiscoveredSessions(sessionsById.values, max * 5),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Gemini CLI');
    }
  }

  /// Parses Gemini CLI `--list-sessions` text output.
  ///
  /// Each session line matches:
  ///   `N. Title text (time ago) [session-uuid]`
  static final _geminiSessionLinePattern = RegExp(
    r'^\s*\d+\.\s+(.+?)\s+\([^)]+\)\s+\[([0-9a-f-]+)\]\s*$',
  );

  List<ToolSessionInfo> _parseGeminiCliOutput(
    String output,
    String? workingDirectory,
  ) {
    final sessions = <ToolSessionInfo>[];
    for (final line in output.split('\n')) {
      final match = _geminiSessionLinePattern.firstMatch(line);
      if (match == null) continue;

      final title = match.group(1)!.trim();
      final id = match.group(2)!.trim();

      sessions.add(
        ToolSessionInfo(
          toolName: 'Gemini CLI',
          sessionId: id,
          workingDirectory: workingDirectory,
          summary: title.length > 80 ? '${title.substring(0, 77)}...' : title,
        ),
      );
    }
    return sessions;
  }

  Future<_ToolDiscoveryResult> _discoverGeminiSessionsFromFiles(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max,
  ) async {
    final scanLimit = _calculateDiscoveryScanLimit(
      max,
      multiplier: 10,
      maximum: 120,
    );
    final output = await _exec(
      session,
      r'find ~/.gemini/tmp \( -name "session-*.json" -o -name "session-*.jsonl" \) '
      '-path "*/chats/*" -type f '
      '-exec ls -1t {} + 2>/dev/null | head -n $scanLimit',
    );
    if (output.trim().isEmpty) {
      return const _ToolDiscoveryResult.success('Gemini CLI', []);
    }

    final sessionPaths = output
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final sessionSnapshots = await _readRemoteFileSnapshots(
      session,
      sessionPaths,
    );

    var hadError = false;
    final sessions = <ToolSessionInfo>[];
    for (final filePath in sessionPaths) {
      final fileName = filePath
          .split('/')
          .last
          .replaceAll('.jsonl', '')
          .replaceAll('.json', '');

      final pathParts = filePath.split('/');
      final chatsIdx = pathParts.indexOf('chats');
      final projectDir = chatsIdx > 0 ? pathParts[chatsIdx - 1] : null;
      final fallbackWorkingDirectory = resolveGeminiProjectWorkingDirectory(
        projectDir,
        relatedWorkingDirectories,
      );

      final snapshot = sessionSnapshots[filePath];
      if (snapshot == null) {
        hadError = true;
        continue;
      }

      try {
        final metadata = parseGeminiSessionMetadata(
          snapshot.content,
          activeWorkingDirectory: workingDirectory,
          fallbackWorkingDirectory: fallbackWorkingDirectory,
        );
        if (snapshot.content.trim().isNotEmpty && !metadata.parsedAny) {
          hadError = true;
          continue;
        }
        if (metadata.isSubagent) continue;

        sessions.add(
          ToolSessionInfo(
            toolName: 'Gemini CLI',
            sessionId:
                metadata.sessionId != null && metadata.sessionId!.isNotEmpty
                ? metadata.sessionId!
                : fileName,
            workingDirectory: metadata.workingDirectory,
            lastActive: metadata.updatedAt ?? snapshot.modifiedAt,
            summary: metadata.summary ?? projectDir ?? _truncateId(fileName),
          ),
        );
      } on Object {
        hadError = true;
      }
    }
    return _ToolDiscoveryResult.success(
      'Gemini CLI',
      sortAndLimitDiscoveredSessions(sessions, scanLimit),
      hadError: hadError,
    );
  }

  // ── OpenCode ───────────────────────────────────────────────────────────
  // `opencode session list --format json` is the cleanest source of truth.
  // It returns renamed titles, directory, and timestamps. Falls back to
  // the SQLite database or JSON files if the CLI is unavailable.

  Future<_ToolDiscoveryResult> _discoverOpenCodeSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max,
  ) async {
    try {
      final scanLimit = _calculateDiscoveryScanLimit(
        max,
        multiplier: 10,
        maximum: 120,
      );
      var hadError = false;
      // Preferred: use the CLI's own JSON output.
      final cliOutput = await _exec(
        session,
        'opencode session list --format json -n $scanLimit 2>/dev/null',
      );
      if (cliOutput.trim().startsWith('[')) {
        try {
          final sessions = _parseOpenCodeCliJson(cliOutput);
          final scopedSessions =
              workingDirectory != null && workingDirectory.isNotEmpty
              ? sessions
                    .where(
                      (info) => matchesDiscoveredSessionWorkingDirectory(
                        workingDirectory,
                        info.workingDirectory,
                        relatedWorkingDirectories: relatedWorkingDirectories,
                      ),
                    )
                    .toList(growable: false)
              : sessions;
          return _ToolDiscoveryResult.success(
            'OpenCode',
            sortAndLimitDiscoveredSessions(
              scopedSessions.isNotEmpty ? scopedSessions : sessions,
              scanLimit,
            ),
          );
        } on Object {
          hadError = true;
          // Fall through to the SQLite fallback.
        }
      }

      // Fallback: query the SQLite database directly.
      // Use ASCII Unit Separator (\x1f) to avoid collision with pipes
      // in session titles or directory paths.
      final dbOutput = await _exec(
        session,
        r'SEP=$(printf "\037"); sqlite3 -separator "$SEP" '
        '~/.local/share/opencode/opencode.db '
        "'SELECT id, title, directory, time_updated "
        'FROM session '
        'WHERE parent_id IS NULL '
        'AND time_archived IS NULL '
        'ORDER BY time_updated DESC '
        "LIMIT $scanLimit;' 2>/dev/null",
      );
      if (dbOutput.trim().isNotEmpty) {
        final sessions = _parseOpenCodeDbOutput(dbOutput);
        final scopedSessions =
            workingDirectory != null && workingDirectory.isNotEmpty
            ? sessions
                  .where(
                    (info) => matchesDiscoveredSessionWorkingDirectory(
                      workingDirectory,
                      info.workingDirectory,
                      relatedWorkingDirectories: relatedWorkingDirectories,
                    ),
                  )
                  .toList(growable: false)
            : sessions;
        return _ToolDiscoveryResult.success(
          'OpenCode',
          sortAndLimitDiscoveredSessions(
            scopedSessions.isNotEmpty ? scopedSessions : sessions,
            scanLimit,
          ),
          hadError: hadError,
        );
      }

      return _ToolDiscoveryResult.success('OpenCode', [], hadError: hadError);
    } on Object {
      return const _ToolDiscoveryResult.failure('OpenCode');
    }
  }

  List<ToolSessionInfo> _parseOpenCodeCliJson(String raw) {
    final decoded = jsonDecode(raw.trim());
    if (decoded is! List) return const [];

    return decoded.whereType<Map<String, dynamic>>().map((entry) {
      final id = entry['id'] as String? ?? '';
      final title = entry['title'] as String? ?? '';
      final directory = entry['directory'] as String?;

      DateTime? lastActive;
      final updated = entry['updated'];
      if (updated is int) {
        lastActive = _dateTimeFromEpoch(updated);
      } else if (updated is String) {
        lastActive = DateTime.tryParse(updated);
      }

      return ToolSessionInfo(
        toolName: 'OpenCode',
        sessionId: id,
        workingDirectory: directory,
        lastActive: lastActive,
        summary: title.isNotEmpty ? title : _truncateId(id),
      );
    }).toList();
  }

  List<ToolSessionInfo> _parseOpenCodeDbOutput(String output) {
    final sessions = <ToolSessionInfo>[];
    for (final line in output.trim().split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\x1f');
      if (parts.length < 3) continue;

      final id = parts[0].trim();
      final title = parts[1].trim();
      final directory = parts[2].trim();
      DateTime? lastActive;
      if (parts.length >= 4) {
        final ts = int.tryParse(parts[3].trim());
        if (ts != null) {
          lastActive = _dateTimeFromEpoch(ts);
        }
      }

      sessions.add(
        ToolSessionInfo(
          toolName: 'OpenCode',
          sessionId: id,
          workingDirectory: directory.isNotEmpty ? directory : null,
          lastActive: lastActive,
          summary: title.isNotEmpty ? title : _truncateId(id),
        ),
      );
    }
    return sessions;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<String> _exec(SshSession session, String command) async {
    final execSession = await session.execute(
      '$_profileSourcingPrefix$command',
    );
    try {
      final results = await Future.wait([
        execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
        execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
      ]).timeout(const Duration(seconds: 10), onTimeout: () => ['', '']);
      return results[0];
    } finally {
      execSession.close();
    }
  }

  Future<List<String>> _listCopilotWorkspacePaths(
    SshSession session,
    int scanLimit,
    Iterable<String> relatedWorkingDirectories,
  ) async {
    final scopedDirectories = relatedWorkingDirectories
        .map(_trimWorkingDirectory)
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final globalCommand =
        'find ~/.copilot/session-state -mindepth 2 -maxdepth 2 '
        '-name workspace.yaml -type f '
        '-exec ls -1t {} + 2>/dev/null | head -n $scanLimit';
    if (scopedDirectories.isEmpty) {
      final output = await _exec(session, globalCommand);
      return output
          .trim()
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
    }

    final scopedCommand = StringBuffer()
      ..write(r'pattern_file=$(mktemp); ')
      ..writeAll(
        scopedDirectories.map(
          (directory) =>
              'printf "%s\\n" ${_shellQuote('cwd: $directory')} '
              r'>> "$pattern_file"; ',
        ),
      )
      ..write(
        r'matching_paths=$(grep -l -x -F -f "$pattern_file" '
        '~/.copilot/session-state/*/workspace.yaml 2>/dev/null); '
        r'rm -f "$pattern_file"; '
        r'if [ -n "$matching_paths" ]; then '
        r'printf "%s\n" "$matching_paths" | xargs ls -1t 2>/dev/null '
        '| head -n $scanLimit; '
        'fi',
      );

    final scopedOutput = await _exec(session, scopedCommand.toString());
    final output = scopedOutput.trim().isNotEmpty
        ? scopedOutput
        : await _exec(session, globalCommand);
    return output
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, _RemoteFileSnapshot>> _readRemoteFileSnapshots(
    SshSession session,
    Iterable<String> paths, {
    int? maxLines,
    bool tail = false,
  }) async {
    final uniquePaths = paths
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniquePaths.isEmpty) {
      return const <String, _RemoteFileSnapshot>{};
    }

    final command = StringBuffer()
      ..write(r'SEP=$(printf "\037"); ')
      ..write('for path in ')
      ..write(uniquePaths.map(_shellQuote).join(' '))
      ..write(r'; do [ -f "$path" ] || continue; ')
      ..write(
        r'mtime=$( (stat -c %Y "$path" 2>/dev/null || '
        r'stat -f %m "$path" 2>/dev/null) | head -1); ',
      )
      ..write(r'printf "%s%s%s%s" "$path" "$SEP" "${mtime:-}" "$SEP"; ');

    if (maxLines == null) {
      command.write(r'cat "$path" 2>/dev/null | base64 | tr -d "\n"; ');
    } else {
      command.write(
        tail
            ? 'tail -n $maxLines '
                  r'"$path" 2>/dev/null | base64 | tr -d "\n"; '
            : "sed -n '1,${maxLines}p' "
                  r'"$path" 2>/dev/null | base64 | tr -d "\n"; ',
      );
    }

    command.write(r'''printf "\n"; done''');

    final output = await _exec(session, command.toString());
    final snapshots = <String, _RemoteFileSnapshot>{};
    for (final line in output.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\x1f');
      if (parts.length < 3) continue;

      final path = parts[0].trim();
      if (path.isEmpty) continue;

      DateTime? modifiedAt;
      final epoch = int.tryParse(parts[1].trim());
      if (epoch != null && epoch > 0) {
        modifiedAt = _dateTimeFromEpoch(epoch);
      }

      try {
        final content = utf8.decode(base64Decode(parts[2].trim()));
        snapshots[path] = _RemoteFileSnapshot(
          content: content,
          modifiedAt: modifiedAt,
        );
      } on FormatException {
        continue;
      }
    }
    return snapshots;
  }

  Future<Map<String, String>> _findClaudeSessionFiles(
    SshSession session,
    Iterable<String> sessionIds,
  ) async {
    final uniqueSessionIds = sessionIds
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueSessionIds.isEmpty) {
      return const <String, String>{};
    }

    final nameFilters = uniqueSessionIds
        .map((id) => '-name ${_shellQuote('$id.jsonl')}')
        .join(' -o ');
    final output = await _exec(
      session,
      'find ~/.claude/projects -type f \\( $nameFilters \\) -print 2>/dev/null',
    );

    final filesById = <String, String>{};
    for (final rawLine in output.split('\n')) {
      final path = rawLine.trim();
      if (path.isEmpty) continue;
      final fileName = path.split('/').last;
      if (!fileName.endsWith('.jsonl')) continue;
      final sessionId = fileName.substring(
        0,
        fileName.length - '.jsonl'.length,
      );
      filesById.putIfAbsent(sessionId, () => path);
    }
    return filesById;
  }

  DateTime _dateTimeFromEpoch(int epoch) => DateTime.fromMillisecondsSinceEpoch(
    epoch > 9999999999 ? epoch : epoch * 1000,
  );

  Future<List<String>> _resolveRelatedWorkingDirectories(
    SshSession session,
    String? workingDirectory,
  ) async {
    final trimmedWorkingDirectory = _trimWorkingDirectory(workingDirectory);
    if (trimmedWorkingDirectory == null) return const <String>[];

    try {
      final gitOutput = await _exec(
        session,
        r'ROOT=$(git -C '
        '${_shellQuote(trimmedWorkingDirectory)}'
        ' rev-parse --show-toplevel 2>/dev/null) && '
        r'[ -n "$ROOT" ] && printf "root=%s\n" "$ROOT" && '
        'git -C '
        '${_shellQuote(trimmedWorkingDirectory)}'
        ' worktree list --porcelain 2>/dev/null',
      );
      if (gitOutput.trim().isEmpty) {
        return buildRelatedWorkingDirectories(trimmedWorkingDirectory);
      }

      String? gitRoot;
      final worktreeLines = StringBuffer();
      for (final line in const LineSplitter().convert(gitOutput)) {
        if (gitRoot == null && line.startsWith('root=')) {
          gitRoot = _trimWorkingDirectory(line.substring('root='.length));
          continue;
        }
        worktreeLines.writeln(line);
      }

      return buildRelatedWorkingDirectories(
        trimmedWorkingDirectory,
        gitRoot: gitRoot,
        gitWorktreeRoots: parseGitWorktreeRoots(worktreeLines.toString()),
      );
    } on Object {
      return buildRelatedWorkingDirectories(trimmedWorkingDirectory);
    }
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  void _mergeToolSessionInfo(
    Map<String, ToolSessionInfo> sessionsById,
    ToolSessionInfo info,
  ) {
    final existing = sessionsById[info.sessionId];
    if (existing == null) {
      sessionsById[info.sessionId] = info;
      return;
    }

    sessionsById[info.sessionId] = ToolSessionInfo(
      toolName: existing.toolName,
      sessionId: existing.sessionId,
      workingDirectory: existing.workingDirectory ?? info.workingDirectory,
      lastActive: existing.lastActive ?? info.lastActive,
      summary: existing.summary ?? info.summary,
    );
  }

  List<ToolSessionInfo> _limitDiscoveredSessionsPerTool(
    List<ToolSessionInfo> sessions,
    int maxPerTool,
  ) {
    final groupedSessions = <String, List<ToolSessionInfo>>{};
    for (final session in sessions) {
      groupedSessions
          .putIfAbsent(session.toolName, () => <ToolSessionInfo>[])
          .add(session);
    }

    final limited = <ToolSessionInfo>[];
    for (final toolSessions in groupedSessions.values) {
      toolSessions.sort(compareDiscoveredSessionsByRecency);
      limited.addAll(toolSessions.take(maxPerTool));
    }
    limited.sort(compareDiscoveredSessionsByRecency);
    return limited;
  }

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
        _pathLastSegment(sessionDirectory) ==
            _pathLastSegment(expectedDirectory);
  }

  static String _truncateId(String id) => _truncateSessionIdValue(id);
}

class _ToolDiscoveryResult {
  const _ToolDiscoveryResult.success(
    this.toolName,
    this.sessions, {
    this.hadError = false,
  });

  const _ToolDiscoveryResult.failure(this.toolName)
    : sessions = const <ToolSessionInfo>[],
      hadError = true;

  final String toolName;
  final List<ToolSessionInfo> sessions;
  final bool hadError;
}

class _CodexSessionIndexResult {
  const _CodexSessionIndexResult({
    required this.entries,
    this.hadError = false,
  });

  final Map<String, _CodexSessionIndexEntry> entries;
  final bool hadError;
}

class _CodexSessionIndexEntry {
  const _CodexSessionIndexEntry({this.threadName, this.updatedAt});

  final String? threadName;
  final DateTime? updatedAt;
}

class _RemoteFileSnapshot {
  const _RemoteFileSnapshot({required this.content, this.modifiedAt});

  final String content;
  final DateTime? modifiedAt;
}

Map<String, dynamic>? _tryDecodeJsonObject(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    return null;
  }
  return null;
}

Map<String, dynamic>? _decodeJsonOrJsonlObject(String raw) {
  final direct = _tryDecodeJsonObject(raw.trim());
  if (direct != null) return direct;

  Map<String, dynamic>? lastObject;
  for (final line in const LineSplitter().convert(raw)) {
    final decoded = _tryDecodeJsonObject(line.trim());
    if (decoded == null) continue;
    lastObject = decoded;
    if (decoded.containsKey('sessionId') || decoded.containsKey('messages')) {
      return decoded;
    }
  }
  return lastObject;
}

Map<String, dynamic>? _readMapField(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (innerKey, innerValue) => MapEntry('$innerKey', innerValue),
    );
  }
  return null;
}

List<dynamic>? _readListField(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  return value is List ? value : null;
}

String? _readStringField(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  return value is String ? value : null;
}

DateTime? _parseDateTimeValue(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}

String? _extractCodexThreadId(String fileName) {
  final match = RegExp(
    r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
  ).firstMatch(fileName);
  return match?.group(1);
}

String? _extractGeminiUserSummary(List<dynamic>? messages) {
  if (messages == null) return null;
  for (final message in messages.whereType<Map>()) {
    final messageMap = message.map((key, value) => MapEntry('$key', value));
    if (_readStringField(messageMap, 'type') != 'user') continue;

    final content = _readListField(messageMap, 'content');
    if (content != null) {
      for (final part in content.whereType<Map>()) {
        final partMap = part.map((key, value) => MapEntry('$key', value));
        final text = _readStringField(partMap, 'text');
        if (text != null && text.trim().isNotEmpty) {
          return _summarizeSessionText(text);
        }
      }
    }

    final displayContent = _readStringField(messageMap, 'displayContent');
    if (displayContent != null && displayContent.trim().isNotEmpty) {
      return _summarizeSessionText(displayContent);
    }
  }
  return null;
}

String? _extractClaudeUserSummary(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.startsWith('/') || trimmed.startsWith('<')) return null;
  return _summarizeSessionText(trimmed);
}

String? _resolveGeminiWorkingDirectory(
  List<dynamic>? directories, {
  String? activeWorkingDirectory,
}) {
  final values = directories
      ?.whereType<String>()
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (values == null || values.isEmpty) return null;

  if (activeWorkingDirectory != null && activeWorkingDirectory.isNotEmpty) {
    for (final value in values) {
      if (value == activeWorkingDirectory ||
          _pathLastSegment(value) == _pathLastSegment(activeWorkingDirectory)) {
        return value;
      }
    }
  }

  if (values.length == 1) return values.first;
  return null;
}

/// Provider for [AgentSessionDiscoveryService].
final agentSessionDiscoveryServiceProvider =
    Provider<AgentSessionDiscoveryService>(
      (ref) => const AgentSessionDiscoveryService(),
    );
