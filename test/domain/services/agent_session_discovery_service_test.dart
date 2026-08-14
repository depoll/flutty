import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_backend.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_connection_backend_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockTerminalConnectionBackendService extends Mock
    implements TerminalConnectionBackendService {}

class _MockTerminalConnectionBackend extends Mock
    implements TerminalConnectionBackend {}

SshSession _buildDiscoverySession(SSHClient client) => SshSession(
  connectionId: 1,
  hostId: 1,
  client: client,
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'demo',
  ),
);

Stream<Uint8List> _utf8Stream(String value) => value.isEmpty
    ? const Stream<Uint8List>.empty()
    : Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(value)));

void _ignoreInvocation(Invocation _) {}

/// Decodes a `powershell ... -EncodedCommand <base64>` command back to its
/// UTF-16LE PowerShell script so Windows-path tests can route mock responses.
String _decodeEncodedPowerShell(String command) {
  const marker = '-EncodedCommand ';
  final index = command.indexOf(marker);
  if (index < 0) return command;
  final bytes = base64.decode(command.substring(index + marker.length).trim());
  final buffer = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    buffer.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
  }
  return buffer.toString();
}

SSHSession _buildExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _utf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _utf8Stream(stderr));
  when(() => session.write(any())).thenAnswer(_ignoreInvocation);
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildOpenMarkerExecSession({String stdout = ''}) {
  final session = _MockExecSession();
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();

  scheduleMicrotask(() {
    stdoutController.add(
      Uint8List.fromList(
        utf8.encode('$stdout\n__flutty_agent_discovery_exec_done__:0\n'),
      ),
    );
  });

  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => stderrController.stream);
  when(() => session.write(any())).thenAnswer(_ignoreInvocation);
  when(session.close).thenAnswer((_) {
    if (!stdoutController.isClosed) unawaited(stdoutController.close());
    if (!stderrController.isClosed) unawaited(stderrController.close());
  });
  return session;
}

SSHSession _buildAcpSessionListExecSession({
  required List<Map<String, Object?>> sessions,
  bool supportsList = true,
}) {
  final session = _MockExecSession();
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();

  void send(Map<String, Object?> payload) {
    stdoutController.add(
      Uint8List.fromList(utf8.encode('${jsonEncode(payload)}\n')),
    );
  }

  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => stderrController.stream);
  when(() => session.write(any())).thenAnswer((invocation) {
    final bytes = invocation.positionalArguments.first as Uint8List;
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'] as int;
    switch (decoded['method']) {
      case 'initialize':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {
              'sessionCapabilities': {
                if (supportsList) 'list': <String, Object?>{},
              },
            },
          },
        });
        return;
      case 'session/list':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'sessions': sessions},
        });
        return;
    }
  });
  when(session.close).thenAnswer((_) {
    if (!stdoutController.isClosed) unawaited(stdoutController.close());
    if (!stderrController.isClosed) unawaited(stderrController.close());
  });
  return session;
}

String _remoteSnapshotLine(String path, String content, {int mtime = 0}) =>
    '$path\x1f$mtime\x1f${base64Encode(utf8.encode(content))}\n';

String _markedDiscoveryOutput(String stdout) =>
    '$stdout\n__flutty_agent_discovery_exec_done__:0\n';

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(SshExecPriority.low);
  });

  group('normalizeWorkingDirectoryForComparison', () {
    test('strips worktree branch segments from comparable paths', () {
      expect(
        normalizeWorkingDirectoryForComparison(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption/lib',
        ),
        '/Users/depoll/Code/flutty/lib',
      );
    });
  });

  group('parseGitWorktreeRoots', () {
    test('extracts worktree paths from porcelain output', () {
      expect(
        parseGitWorktreeRoots('''
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main

worktree /Users/depoll/Code/flutty.worktrees/fix-session-resumption
HEAD 1234567
branch refs/heads/fix/session-resumption
'''),
        [
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        ],
      );
    });
  });

  group('buildRelatedWorkingDirectories', () {
    test('maps the active subdirectory across git worktrees', () {
      expect(
        buildRelatedWorkingDirectories(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption/lib',
          gitRoot: '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
          gitWorktreeRoots: const [
            '/Users/depoll/Code/flutty',
            '/Users/depoll/Code/flutty.worktrees/feature-other',
          ],
        ),
        containsAll(<String>[
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption/lib',
          '/Users/depoll/Code/flutty/lib',
          '/Users/depoll/Code/flutty.worktrees/feature-other/lib',
          '/Users/depoll/Code/flutty.worktrees/feature-other',
        ]),
      );
    });
  });

  group('matchesDiscoveredSessionWorkingDirectory', () {
    test('matches the main checkout from a sibling worktree', () {
      final relatedDirectories = buildRelatedWorkingDirectories(
        '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        gitRoot: '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        gitWorktreeRoots: const [
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/feature-other',
        ],
      );

      expect(
        matchesDiscoveredSessionWorkingDirectory(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
          '/Users/depoll/Code/flutty',
          relatedWorkingDirectories: relatedDirectories,
        ),
        isTrue,
      );
      expect(
        matchesDiscoveredSessionWorkingDirectory(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
          '/tmp/another-repo/flutty',
          relatedWorkingDirectories: relatedDirectories,
        ),
        isFalse,
      );
    });
  });

  group('resolveGeminiProjectWorkingDirectory', () {
    test('maps project folder names back to the right worktree paths', () {
      final relatedDirectories = buildRelatedWorkingDirectories(
        '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        gitRoot: '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        gitWorktreeRoots: const [
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/feature-other',
        ],
      );

      expect(
        resolveGeminiProjectWorkingDirectory('flutty', relatedDirectories),
        '/Users/depoll/Code/flutty',
      );
      expect(
        resolveGeminiProjectWorkingDirectory(
          'feature-other',
          relatedDirectories,
        ),
        '/Users/depoll/Code/flutty.worktrees/feature-other',
      );
    });
  });

  group('resolveAgentSessionScopeWorkingDirectory', () {
    test('keeps the active project path when it already looks valid', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/Code/flutty',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('falls back from Copilot state paths to the terminal cwd', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory:
              '/Users/depoll/.copilot/session-state/970e4099-a97c-456a-a6c2-408095060f72',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('falls back from AI tool home directories to the terminal cwd', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/.copilot',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/.local/share/opencode',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/.gemini',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('prefers a more specific terminal cwd over a broader pane cwd', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('prefers the live terminal cwd when tmux metadata disagrees', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/Code/another-project',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('drops temp-only paths when there is no terminal cwd fallback', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/var/folders/demo/output',
        ),
        isNull,
      );
    });
  });

  group('resolveTmuxAiSessionScopeWorkingDirectory', () {
    test('prefers the live terminal cwd over stale tmux metadata', () {
      expect(
        resolveTmuxAiSessionScopeWorkingDirectory(
          liveTerminalWorkingDirectory: '/Users/depoll/Code/flutty',
          tmuxWorkingDirectory: '/Users/depoll/Code/another-project',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('falls back to tmux metadata only when no live cwd exists', () {
      expect(
        resolveTmuxAiSessionScopeWorkingDirectory(
          tmuxWorkingDirectory: '/Users/depoll/Code/flutty',
        ),
        '/Users/depoll/Code/flutty',
      );
    });
  });

  group('readClaudeHistoryWorkingDirectory', () {
    test('ignores malformed non-string directory metadata', () {
      expect(
        readClaudeHistoryWorkingDirectory({
          'directory': {'path': '/Users/depoll/Code/flutty'},
          'project': 42,
        }),
        isNull,
      );

      expect(
        readClaudeHistoryWorkingDirectory({
          'directory': 42,
          'project': '/Users/depoll/Code/flutty',
        }),
        '/Users/depoll/Code/flutty',
      );
    });
  });

  group('calculateClaudeMetadataSnapshotLimit', () {
    test('caps Claude metadata snapshots to a smaller recent window', () {
      expect(calculateClaudeMetadataSnapshotLimit(6), 40);
      expect(calculateClaudeMetadataSnapshotLimit(24), 80);
      expect(calculateClaudeMetadataSnapshotLimit(48), 80);
    });
  });

  group('calculateRecentSessionMetadataReadLimit', () {
    test('caps other provider metadata reads to a smaller recent window', () {
      expect(calculateRecentSessionMetadataReadLimit(6), 24);
      expect(calculateRecentSessionMetadataReadLimit(12), 36);
      expect(calculateRecentSessionMetadataReadLimit(24), 48);
    });
  });

  group('buildGeminiProjectDirectoryNames', () {
    test('keeps only worktree roots and ignores nested subdirectories', () {
      expect(
        buildGeminiProjectDirectoryNames(const [
          '/Users/depoll/Code/flutty.worktrees/feature-other/lib',
          '/Users/depoll/Code/flutty/lib',
          '/Users/depoll/Code/flutty.worktrees/feature-other',
          '/Users/depoll/Code/flutty',
        ]),
        ['feature-other', 'flutty'],
      );
    });
  });

  group('buildScopedGeminiProjectDirectoryNames', () {
    test('keeps the active worktree name plus the canonical checkout name', () {
      expect(
        buildScopedGeminiProjectDirectoryNames(
          '/Users/depoll/Code/flutty.worktrees/session-resumption-all-providers',
          const [
            '/Users/depoll/Code/flutty',
            '/Users/depoll/Code/flutty.worktrees/session-resumption-all-providers',
            '/Users/depoll/Code/flutty.worktrees/feature-other',
          ],
        ),
        ['session-resumption-all-providers', 'flutty'],
      );
    });
  });

  group('scopeDiscoveredSessionsToWorkingDirectory', () {
    test('keeps providers that have no matching cwd metadata', () {
      final scopedSessions = scopeDiscoveredSessionsToWorkingDirectory(
        [
          ToolSessionInfo(
            toolName: 'Claude Code',
            sessionId: 'claude-match',
            workingDirectory: '/Users/depoll/Code/flutty',
            summary: 'Fix tmux filtering',
            lastActive: DateTime(2026, 4, 20, 12),
          ),
          ToolSessionInfo(
            toolName: 'Claude Code',
            sessionId: 'claude-other',
            workingDirectory: '/tmp/another-repo',
            summary: 'Other project',
            lastActive: DateTime(2026, 4, 20, 11),
          ),
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: 'codex-no-cwd',
            summary: 'Investigate session loading',
            lastActive: DateTime(2026, 4, 20, 10),
          ),
          ToolSessionInfo(
            toolName: 'Copilot CLI',
            sessionId: 'copilot-no-cwd',
            summary: 'Review recent tmux fixes',
            lastActive: DateTime(2026, 4, 20, 9),
          ),
        ],
        '/Users/depoll/Code/flutty.worktrees/feature-other',
        relatedWorkingDirectories: const [
          '/Users/depoll/Code/flutty.worktrees/feature-other',
          '/Users/depoll/Code/flutty',
        ],
      );

      expect(scopedSessions.map((session) => session.sessionId), [
        'claude-match',
        'codex-no-cwd',
        'copilot-no-cwd',
      ]);
    });
  });

  group('sortAndLimitDiscoveredSessions', () {
    test('sorts by recency before applying the cap', () {
      final limitedSessions = sortAndLimitDiscoveredSessions([
        ToolSessionInfo(
          toolName: 'Gemini CLI',
          sessionId: 'older',
          summary: 'older',
          lastActive: DateTime(2026, 4, 12),
        ),
        ToolSessionInfo(
          toolName: 'Gemini CLI',
          sessionId: 'newer',
          summary: 'newer',
          lastActive: DateTime(2026, 4, 13),
        ),
      ], 1);

      expect(limitedSessions.map((session) => session.sessionId), ['newer']);
    });
  });

  group('orderedDiscoveredSessionTools', () {
    test('includes all known providers in a stable order', () {
      final ordered = orderedDiscoveredSessionTools(
        {
          'Claude Code': const <ToolSessionInfo>[],
          'Codex': const <ToolSessionInfo>[],
        },
        const ['Gemini CLI'],
      );

      expect(ordered, [
        'Claude Code',
        'Copilot CLI',
        'Codex',
        'Gemini CLI',
        'OpenCode',
        'Antigravity',
        'Cursor Agent',
        'Pi',
        'Hermes',
        'Grok Build',
      ]);
    });

    test('moves the preferred tool to the front and appends unknown tools', () {
      final ordered = orderedDiscoveredSessionTools(
        const {'Custom Tool': <ToolSessionInfo>[]},
        const ['Custom Tool'],
        preferredToolName: 'Codex',
      );

      expect(ordered, [
        'Codex',
        'Claude Code',
        'Copilot CLI',
        'Gemini CLI',
        'OpenCode',
        'Antigravity',
        'Cursor Agent',
        'Pi',
        'Hermes',
        'Grok Build',
        'Custom Tool',
      ]);
    });
  });

  group('normalizeDiscoveredSessionInfo', () {
    test('drops unnamed sessions without usable fallback context', () {
      const info = ToolSessionInfo(
        toolName: 'Copilot CLI',
        sessionId: '12345678-1234-1234-1234-1234567890ab',
        summary: '12345678…',
      );

      expect(normalizeDiscoveredSessionInfo(info), isNull);
    });

    test('falls back to working directory name when title is missing', () {
      const info = ToolSessionInfo(
        toolName: 'Copilot CLI',
        sessionId: '12345678-1234-1234-1234-1234567890ab',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      final normalized = normalizeDiscoveredSessionInfo(info);
      expect(normalized, isNotNull);
      expect(normalized!.summary, 'flutty');
    });

    test(
      'drops project-name-only summaries in current working directory view',
      () {
        const info = ToolSessionInfo(
          toolName: 'Copilot CLI',
          sessionId: '12345678-1234-1234-1234-1234567890ab',
          workingDirectory: '/Users/depoll/Code/flutty',
          summary: 'flutty',
        );

        expect(
          normalizeDiscoveredSessionInfo(
            info,
            activeWorkingDirectory: '/Users/depoll/Code/flutty',
          ),
          isNull,
        );
      },
    );

    test(
      'drops directory fallback when the active working directory already matches',
      () {
        const info = ToolSessionInfo(
          toolName: 'Gemini CLI',
          sessionId: 'abcdef',
          workingDirectory: '/Users/depoll/Code/flutty',
        );

        expect(
          normalizeDiscoveredSessionInfo(
            info,
            activeWorkingDirectory: '/Users/depoll/Code/flutty',
          ),
          isNull,
        );
      },
    );
  });

  group('buildResumeCommand', () {
    test('resumes Codex with the discovered session UUID', () {
      const info = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(
        AgentSessionDiscoveryService().buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && "
        "codex resume '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d'",
      );
    });

    test('adds yolo mode when resuming supported sessions', () {
      const info = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(
        AgentSessionDiscoveryService().buildResumeCommand(
          info,
          startInYoloMode: true,
        ),
        "cd '/Users/depoll/Code/flutty' && "
        "codex --yolo resume '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d'",
      );
    });

    test('resumes Cursor Agent with the discovered chat id', () {
      const info = ToolSessionInfo(
        toolName: 'Cursor Agent',
        sessionId: 'f21ed2df-500d-46a5-b55f-12b64268491f',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(
        AgentSessionDiscoveryService().buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && "
        "cursor-agent --resume 'f21ed2df-500d-46a5-b55f-12b64268491f'",
      );
    });
  });

  group('compareDiscoveredSessionsByRecency', () {
    test('sorts newest first and leaves untimestamped sessions last', () {
      final sessions = [
        ToolSessionInfo(
          toolName: 'OpenCode',
          sessionId: '3',
          summary: 'older',
          lastActive: DateTime(2026, 4, 10),
        ),
        const ToolSessionInfo(
          toolName: 'Copilot CLI',
          sessionId: '2',
          summary: 'no timestamp',
        ),
        ToolSessionInfo(
          toolName: 'Claude Code',
          sessionId: '1',
          summary: 'newest',
          lastActive: DateTime(2026, 4, 12),
        ),
      ];

      final sortedSessions = sessions.toList()
        ..sort(compareDiscoveredSessionsByRecency);

      expect(sortedSessions.map((session) => session.sessionId), [
        '1',
        '3',
        '2',
      ]);
    });
  });

  group('parseCopilotWorkspaceYamlMetadata', () {
    test('reads multiline summary blocks and updated_at timestamps', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
id: example
cwd: /Users/depoll/Code/flutty
summary: |-
  Fix Handlebar Jitter And Tmux Animation
  With extra detail on the next line
updated_at: 2026-04-14T01:02:03.000Z
''');

      expect(metadata.summary, 'Fix Handlebar Jitter And Tmux Animation');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-14T01:02:03.000Z'));
    });

    test('falls back to repository and branch when summary is missing', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
id: example
cwd: /Users/depoll/Code/flutty
repository: depollsoft/MonkeySSH
branch: main
updated_at: 2026-04-14T01:02:03.000Z
''');

      expect(metadata.summary, 'depollsoft/MonkeySSH (main)');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-14T01:02:03.000Z'));
    });

    test('prefers user-provided session names when summary is missing', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
id: example
name: Fix active session labels
repository: depollsoft/MonkeySSH
branch: main
''');

      expect(metadata.summary, 'Fix active session labels');
    });

    test('normalizes inline summary text to a single display line', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
summary:   Add   PR preview   commit list   
cwd: /tmp/demo
''');

      expect(metadata.summary, 'Add PR preview commit list');
      expect(metadata.workingDirectory, '/tmp/demo');
      expect(metadata.updatedAt, isNull);
    });
  });

  group('buildSqlWorkingDirectoryScopeClause', () {
    test('uses exact prefix predicates instead of LIKE wildcards', () {
      final clause = buildSqlWorkingDirectoryScopeClause(const [
        '/Users/depoll/Code/my_repo',
      ], columnName: 'directory');

      expect(clause, isNotNull);
      expect(clause, isNot(contains('LIKE')));
      expect(
        clause,
        contains(
          "substr(directory, 1, length('/Users/depoll/Code/my_repo') + 1) = '/Users/depoll/Code/my_repo/'",
        ),
      );
    });
  });

  group('DiscoveredSessionsResult', () {
    test('formats a readable failure message', () {
      final result = DiscoveredSessionsResult(
        sessions: const [],
        failedTools: const {'Codex', 'Gemini CLI'},
      );

      expect(
        result.failureMessage,
        'Could not load Codex and Gemini CLI sessions.',
      );
    });

    test('formats single-tool failures and keeps no-failure states quiet', () {
      expect(
        DiscoveredSessionsResult(
          sessions: const [],
          failedTools: const {'Claude Code'},
        ).failureMessage,
        'Could not load Claude Code sessions.',
      );
      expect(
        DiscoveredSessionsResult(sessions: const []).failureMessage,
        isNull,
      );
    });

    test('tracks attempted tools separately for placeholder rows', () {
      final result = DiscoveredSessionsResult(
        sessions: const [],
        attemptedTools: const {'Claude Code', 'Copilot CLI'},
      );

      expect(result.hasFailures, isFalse);
      expect(result.attemptedTools, {'Claude Code', 'Copilot CLI'});
    });
  });

  group('shouldSurfaceDiscoveryFailure', () {
    test('reports tools that failed to load any sessions', () {
      expect(
        shouldSurfaceDiscoveryFailure(hadError: true, loadedSessionCount: 0),
        isTrue,
      );
    });

    test('suppresses partial failures when sessions still loaded', () {
      expect(
        shouldSurfaceDiscoveryFailure(hadError: true, loadedSessionCount: 3),
        isFalse,
      );
    });

    test('suppresses healthy empty discovery results', () {
      expect(
        shouldSurfaceDiscoveryFailure(hadError: false, loadedSessionCount: 0),
        isFalse,
      );
    });
  });

  group('parseCodexRolloutMetadata', () {
    test('prefers the structured user_message event over input_text noise', () {
      final metadata = parseCodexRolloutMetadata('''
{"timestamp":"2026-04-12T21:07:44.781Z","type":"session_meta","payload":{"id":"019d8385-487f-72c1-9abf-766ffc76deff","cwd":"/Users/depoll/Code/flutty"}}
{"timestamp":"2026-04-12T21:07:45.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"input_text","text":"<permissions instructions>"}]}}
{"timestamp":"2026-04-12T21:07:48.390Z","type":"event_msg","payload":{"type":"user_message","message":"rename this session","images":[]}}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, '019d8385-487f-72c1-9abf-766ffc76deff');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.summary, 'rename this session');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:07:44.781Z'));
    });
  });

  group('parseClaudeSessionMetadata', () {
    test('extracts the first real user prompt and ignores slash commands', () {
      final metadata = parseClaudeSessionMetadata('''
{"type":"user","isMeta":false,"message":{"role":"user","content":"/exit"}}
{"type":"user","isMeta":false,"message":{"role":"user","content":"Fix the tmux session list loading bug"}}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.userSummary, 'Fix the tmux session list loading bug');
    });

    test('preserves explicit metadata fields when present', () {
      final metadata = parseClaudeSessionMetadata('''
{"customTitle":"Investigate slow AI session loading","agentName":"Opus","lastPrompt":"ignored"}
''');

      expect(metadata.customTitle, 'Investigate slow AI session loading');
      expect(metadata.agentName, 'Opus');
      expect(metadata.lastPrompt, 'ignored');
    });

    test(
      'prefers the latest metadata fields while keeping the first prompt',
      () {
        final metadata = parseClaudeSessionMetadata('''
{"type":"user","isMeta":false,"message":{"role":"user","content":"Original prompt"}}
{"customTitle":"Initial title","lastPrompt":"older"}
{"customTitle":"Renamed title","lastPrompt":"newer"}
''');

        expect(metadata.userSummary, 'Original prompt');
        expect(metadata.customTitle, 'Renamed title');
        expect(metadata.lastPrompt, 'newer');
      },
    );
  });

  group('parseAntigravitySessionMetadata', () {
    test('uses stored summary, sessionId, workingDirectory, and updatedAt', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "summary": "Fix some bugs",
  "workingDirectory": "/Users/depoll/Code/flutty",
  "updatedAt": "2026-04-12T21:29:53.292Z"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, 'e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3');
      expect(metadata.summary, 'Fix some bugs');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:29:53.292Z'));
    });

    test('prefers history display names over stale summaries', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "display": "Updated session name",
  "summary": "Original summary"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.summary, 'Updated session name');
    });

    test('extracts working directory from nested folderUri', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "Untitled",
  "projectResources": {
    "resources": [
      {
        "gitFolder": {
          "folderUri": "file:///Users/depoll/Code/flutty",
          "allowWrite": true
        }
      }
    ]
  }
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
    });

    test('decodes percent-encoded folderUri paths', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "Untitled",
  "projectResources": {
    "resources": [
      {
        "gitFolder": {
          "folderUri": "file:///Users/depoll/My%20Code/flutty",
          "allowWrite": true
        }
      }
    ]
  }
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.workingDirectory, '/Users/depoll/My Code/flutty');
    });

    test('maps Windows drive-letter folderUri to a backslash path', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "Untitled",
  "projectResources": {
    "resources": [
      {
        "gitFolder": {
          "folderUri": "file:///C:/Users/demo/My%20Repo",
          "allowWrite": true
        }
      }
    ]
  }
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.workingDirectory, r'C:\Users\demo\My Repo');
    });

    test('falls back to name when it is an absolute path', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "/Users/depoll/Code/flutty"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
    });

    test(
      'extracts metadata from a truncated JSON prefix (partial parsing)',
      () {
        final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "/Users/depoll/Code/flutty",
  "folderUri": "file:///Users/depoll/Code/flutty",
  "updatedAt": "2026-04-12T21:29:53.2
''');

        expect(metadata.parsedAny, isTrue);
        expect(metadata.sessionId, 'e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3');
        expect(metadata.summary, '/Users/depoll/Code/flutty');
        expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      },
    );

    test('sets parsedAny to false when no recognized fields are present', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "unknownField": "value"
}
''');

      expect(metadata.parsedAny, isFalse);
    });
  });

  group('parseGrokSessionMetadata', () {
    test('uses generated title, authoritative info, and last activity', () {
      final metadata = parseGrokSessionMetadata('''
{
  "info": {
    "id": "019f6cb5-f7e4-7bc1-bb25-9985af59619e",
    "cwd": "/Users/depoll/Code/flutty"
  },
  "session_summary": "Older summary",
  "generated_title": "Fix Grok session resumption",
  "created_at": "2026-08-14T20:00:00Z",
  "updated_at": "2026-08-14T20:05:00Z",
  "last_active_at": "2026-08-14T20:04:00Z"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, '019f6cb5-f7e4-7bc1-bb25-9985af59619e');
      expect(metadata.summary, 'Fix Grok session resumption');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-08-14T20:04:00Z'));
      expect(metadata.isHidden, isFalse);
    });

    test('falls back to session summary and identifies hidden subagents', () {
      final metadata = parseGrokSessionMetadata('''
{
  "info": {"id": "child", "cwd": "/tmp/repo"},
  "session_summary": "Child work",
  "updated_at": "2026-08-14T20:05:00Z",
  "session_kind": "subagent"
}
''');

      expect(metadata.summary, 'Child work');
      expect(metadata.isHidden, isTrue);
    });

    test('honors an explicit hidden boolean over the session kind', () {
      final visibleSubagent = parseGrokSessionMetadata('''
{
  "info": {"id": "child", "cwd": "/tmp/repo"},
  "session_kind": "subagent",
  "hidden": false
}
''');
      final hiddenRoot = parseGrokSessionMetadata('''
{
  "info": {"id": "root", "cwd": "/tmp/repo"},
  "session_kind": "root",
  "hidden": true
}
''');

      expect(visibleSubagent.isHidden, isFalse);
      expect(hiddenRoot.isHidden, isTrue);
    });

    test('rejects malformed metadata', () {
      expect(parseGrokSessionMetadata('{broken').parsedAny, isFalse);
    });
  });

  group('parsePiSessionMetadata', () {
    test('reads the session header and first user prompt', () {
      final metadata = parsePiSessionMetadata('''
{"type":"session","version":3,"id":"01JYX7","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/flutty"}
{"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"Fix the tmux navigator crash"}}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, '01JYX7');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.summary, 'Fix the tmux navigator crash');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:07:44.781Z'));
    });

    test('prefers the latest session_info name over the first prompt', () {
      final metadata = parsePiSessionMetadata('''
{"type":"session","version":3,"id":"01JYX7","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/tmp/project"}
{"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"initial prompt"}}
{"type":"session_info","id":"b","parentId":"a","name":"Refactor auth"}
{"type":"session_info","id":"c","parentId":"b","name":"Refactor auth module"}
''');

      expect(metadata.summary, 'Refactor auth module');
    });

    test('reads user text from structured content blocks', () {
      final metadata = parsePiSessionMetadata('''
{"type":"session","version":3,"id":"01JYX7","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/tmp/project"}
{"type":"message","message":{"role":"user","content":[{"type":"image"},{"type":"text","text":"Explain this diagram"}]}}
''');

      expect(metadata.summary, 'Explain this diagram');
    });

    test('reports no parsed content for an unreadable transcript', () {
      final metadata = parsePiSessionMetadata('not json at all');

      expect(metadata.parsedAny, isFalse);
      expect(metadata.sessionId, isNull);
    });
  });

  group('parseHermesDbOutput', () {
    test('maps separated columns onto session metadata', () {
      final sessions = parseHermesDbOutput(
        '${<String>['20250305_091523_a1b2c3', 'Refactor auth', '/Users/depoll/Code/flutty', '1783405351'].join('\x1f')}\n',
      );

      expect(sessions, hasLength(1));
      expect(sessions.single.toolName, 'Hermes');
      expect(sessions.single.sessionId, '20250305_091523_a1b2c3');
      expect(sessions.single.summary, 'Refactor auth');
      expect(sessions.single.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        sessions.single.lastActive,
        DateTime.fromMillisecondsSinceEpoch(1783405351000),
      );
    });

    test('tolerates empty titles, cwd, and timestamps', () {
      final sessions = parseHermesDbOutput(
        '20250305_091523_a1b2c3\x1f\x1f\x1f0\n\n',
      );

      expect(sessions, hasLength(1));
      expect(sessions.single.workingDirectory, isNull);
      expect(sessions.single.lastActive, isNull);
      expect(sessions.single.summary, isNotEmpty);
    });

    test('skips malformed rows without an id', () {
      final sessions = parseHermesDbOutput('\x1fno id\x1f/tmp\x1f1\nbroken\n');

      expect(sessions, isEmpty);
    });
  });

  group('parseCursorSessionMetadata', () {
    test('uses title, cwd, and updatedAtMs epoch milliseconds', () {
      final metadata = parseCursorSessionMetadata('''
{
  "schemaVersion": 1,
  "createdAtMs": 1783404550969,
  "hasConversation": true,
  "title": "Copilot Theming Fix",
  "updatedAtMs": 1783405351095,
  "cwd": "/Users/depoll/Code/flutty"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.summary, 'Copilot Theming Fix');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.hasConversation, isTrue);
      expect(
        metadata.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1783405351095),
      );
    });

    test('falls back to createdAtMs when updatedAtMs is absent', () {
      final metadata = parseCursorSessionMetadata('''
{
  "createdAtMs": 1783404550969,
  "title": "New chat",
  "cwd": "/tmp/project"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(
        metadata.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1783404550969),
      );
    });

    test('marks empty chats as not having a conversation', () {
      final metadata = parseCursorSessionMetadata('''
{
  "title": "Empty",
  "hasConversation": false,
  "cwd": "/tmp/project"
}
''');

      expect(metadata.hasConversation, isFalse);
    });

    test('defaults hasConversation to true and parsedAny false on garbage', () {
      final metadata = parseCursorSessionMetadata('not json');
      expect(metadata.parsedAny, isFalse);
      expect(metadata.hasConversation, isTrue);
    });
  });

  group('parseGeminiSessionMetadata', () {
    test('uses stored summary and lastUpdated for main sessions', () {
      final metadata = parseGeminiSessionMetadata('''
{
  "sessionId": "bc1ced23-25ac-4971-8f30-8af35ce2f2f1",
  "summary": "List available commands.",
  "lastUpdated": "2026-04-12T21:29:53.292Z",
  "kind": "main",
  "messages": []
}
''', fallbackWorkingDirectory: '/Users/depoll/Code/flutty');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.isSubagent, isFalse);
      expect(metadata.sessionId, 'bc1ced23-25ac-4971-8f30-8af35ce2f2f1');
      expect(metadata.summary, 'List available commands.');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:29:53.292Z'));
    });

    test('falls back to the first user message and filters subagents', () {
      final metadata = parseGeminiSessionMetadata(
        '''
{
  "sessionId": "session-1",
  "kind": "subagent",
  "messages": [
    {
      "type": "info",
      "content": "Gemini update available"
    },
    {
      "type": "user",
      "content": [{"text": "can i rename this session?"}]
    }
  ]
}
''',
        activeWorkingDirectory: '/Users/depoll/Code/flutty',
        fallbackWorkingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(metadata.parsedAny, isTrue);
      expect(metadata.isSubagent, isTrue);
      expect(metadata.summary, 'can i rename this session?');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
    });

    test('extracts metadata from a truncated large JSON prefix', () {
      final metadata = parseGeminiSessionMetadata('''
{
  "sessionId": "session-large",
  "summary": "Investigate MonkeyMux agent detection hardening",
  "lastUpdated": "2026-04-12T21:29:53.292Z",
  "kind": "main",
  "directories": ["/Users/depoll/Code/flutty"],
  "messages": [
''', activeWorkingDirectory: '/Users/depoll/Code/flutty');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.isSubagent, isFalse);
      expect(metadata.sessionId, 'session-large');
      expect(
        metadata.summary,
        'Investigate MonkeyMux agent detection hardening',
      );
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:29:53.292Z'));
    });
  });

  group('parseAcpSessionListResult', () {
    test('maps ACP session/list metadata to tool session info', () {
      final sessions = parseAcpSessionListResult('OpenCode', {
        'sessions': [
          {
            'sessionId': 'ses_123',
            'cwd': '/Users/depoll/Code/flutty',
            'title': 'Fix ACP discovery',
            'updatedAt': '2026-05-04T05:48:19.955Z',
          },
        ],
      });

      expect(sessions, hasLength(1));
      expect(sessions.single.toolName, 'OpenCode');
      expect(sessions.single.sessionId, 'ses_123');
      expect(sessions.single.workingDirectory, '/Users/depoll/Code/flutty');
      expect(sessions.single.summary, 'Fix ACP discovery');
      expect(
        sessions.single.lastActive,
        DateTime.parse('2026-05-04T05:48:19.955Z'),
      );
    });
  });

  group('parseOpenCodeStorageSessionMetadata', () {
    test('maps JSON storage sessions to unified metadata', () {
      final metadata = parseOpenCodeStorageSessionMetadata(r'''
{
  "id": "ses_123",
  "directory": "C:\\Users\\demo\\repo",
  "title": "Fix Windows discovery",
  "time": {"updated": 1770000000000}
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, 'ses_123');
      expect(metadata.workingDirectory, r'C:\Users\demo\repo');
      expect(metadata.summary, 'Fix Windows discovery');
      expect(
        metadata.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1770000000000),
      );
      expect(metadata.parentId, isNull);
      expect(metadata.isArchived, isFalse);
    });

    test('identifies archived child sessions', () {
      final metadata = parseOpenCodeStorageSessionMetadata('''
{
  "id": "child",
  "parentID": "parent",
  "time": {"archived": 1770000000000}
}
''');

      expect(metadata.parentId, 'parent');
      expect(metadata.isArchived, isTrue);
    });
  });

  group('discoverSessionsStream caching', () {
    test('discovers sessions via PowerShell on Windows remotes', () async {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

      final issuedScripts = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        final script = _decodeEncodedPowerShell(command);
        issuedScripts.add(script);
        // Copilot workspace listing.
        if (script.contains('.copilot/session-state') &&
            !script.contains('[char]0x1f')) {
          return _buildExecSession(
            stdout: 'C:/Users/demo/.copilot/session-state/abc/workspace.yaml\n',
          );
        }
        // Snapshot read of the workspace.yaml.
        if (script.contains('[char]0x1f') &&
            script.contains('workspace.yaml')) {
          final content = base64.encode(
            utf8.encode('id: abc\ncwd: C:\\proj\nsummary: My session\n'),
          );
          return _buildExecSession(
            stdout:
                'C:/Users/demo/.copilot/session-state/abc/workspace.yaml'
                '\x1f1700000000\x1f$content\n',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(session);

      // Every issued command is a PowerShell EncodedCommand, never POSIX.
      final commands = verify(
        () => client.execute(captureAny()),
      ).captured.cast<String>();
      expect(commands, isNotEmpty);
      expect(
        commands.every((command) => command.contains('-EncodedCommand ')),
        isTrue,
      );
      expect(
        issuedScripts.any((script) => script.contains('Get-ChildItem')),
        isTrue,
      );
      final copilot = result.sessions.where(
        (info) => info.toolName == 'Copilot CLI',
      );
      expect(copilot, isNotEmpty);
      expect(copilot.first.summary, 'My session');
    });

    test(
      'OpenCode discovery reads Windows JSON storage without sqlite3',
      () async {
        final client = _MockSshClient();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

        const storagePath =
            'C:/Users/demo/.local/share/opencode/storage/session/project/'
            'ses_123.json';
        final sessionJson = jsonEncode({
          'id': 'ses_123',
          'directory': r'C:\Users\demo\repo',
          'title': 'Review Windows discovery',
          'time': {'updated': 1770000000000},
        });

        when(() => client.execute(any())).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          final script = _decodeEncodedPowerShell(command);
          if (script.contains('opencode session list --format json')) {
            return _buildExecSession();
          }
          if (script.contains('.local/share/opencode/storage/session') &&
              !script.contains('[char]0x1f')) {
            return _buildExecSession(stdout: '$storagePath\n');
          }
          if (script.contains('[char]0x1f') && script.contains(storagePath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(storagePath, sessionJson, mtime: 1),
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery.discoverSessions(
          session,
          workingDirectory: r'C:\Users\demo\repo',
          toolName: 'OpenCode',
        );

        expect(result.sessions, hasLength(1));
        expect(result.sessions.single.toolName, 'OpenCode');
        expect(result.sessions.single.sessionId, 'ses_123');
        expect(result.sessions.single.summary, 'Review Windows discovery');
        expect(result.sessions.single.workingDirectory, r'C:\Users\demo\repo');
        expect(
          verify(() => client.execute(captureAny())).captured.cast<String>(),
          everyElement(contains('-EncodedCommand ')),
        );
      },
    );

    test('Antigravity discovery reads Windows JSON sessions', () async {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

      const antigravityPath = 'C:/Users/demo/.antigravity/sessions/ag-123.json';
      final sessionJson = jsonEncode({
        'id': 'ag-123',
        'summary': 'Review Antigravity history',
        'workingDirectory': r'C:\Users\demo\repo',
        'updatedAt': '2026-07-05T20:15:00.000Z',
      });

      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        final script = _decodeEncodedPowerShell(command);
        if (script.contains('.antigravity/sessions') &&
            !script.contains('[char]0x1f')) {
          return _buildExecSession(stdout: '$antigravityPath\n');
        }
        if (script.contains('[char]0x1f') && script.contains(antigravityPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(antigravityPath, sessionJson, mtime: 1),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        workingDirectory: r'C:\Users\demo\repo',
        toolName: 'Antigravity',
      );

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'Antigravity');
      expect(result.sessions.single.sessionId, 'ag-123');
      expect(result.sessions.single.summary, 'Review Antigravity history');
      expect(result.sessions.single.workingDirectory, r'C:\Users\demo\repo');
    });

    test('Copilot discovery uses ACP session/list when available', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
          );
        }
        if (command.contains('copilot --acp')) {
          return _buildAcpSessionListExecSession(
            sessions: const [
              {
                'sessionId': '12345678-1234-1234-1234-1234567890ab',
                'cwd': '/Users/depoll/Code/flutty',
                'title': 'Fix tmux ACP discovery',
                'updatedAt': '2026-05-04T05:48:19.955Z',
              },
            ],
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        workingDirectory: '/Users/depoll/Code/flutty',
        toolName: 'Copilot CLI',
      );

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'Copilot CLI');
      expect(
        result.sessions.single.sessionId,
        '12345678-1234-1234-1234-1234567890ab',
      );
      expect(result.sessions.single.summary, 'Fix tmux ACP discovery');
      expect(
        commands.where((command) => command.contains('copilot --acp')),
        hasLength(1),
      );
      expect(
        commands.where((command) => command.contains('workspace.yaml')),
        isEmpty,
      );
    });

    test('OpenCode discovery uses ACP session/list when available', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
          );
        }
        if (command.contains('opencode acp')) {
          return _buildAcpSessionListExecSession(
            sessions: const [
              {
                'sessionId': 'ses_123',
                'cwd': '/Users/depoll/Code/flutty',
                'title': 'Review tmux panel',
                'updatedAt': '2026-05-04T05:48:19.955Z',
              },
            ],
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        workingDirectory: '/Users/depoll/Code/flutty',
        toolName: 'OpenCode',
      );

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'OpenCode');
      expect(result.sessions.single.sessionId, 'ses_123');
      expect(result.sessions.single.summary, 'Review tmux panel');
      expect(
        commands.where((command) => command.contains('opencode acp')),
        hasLength(1),
      );
      expect(
        commands.where(
          (command) => command.contains('opencode session list --format json'),
        ),
        isEmpty,
      );
    });

    test('Antigravity discovery uses unified Python script', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
          );
        }
        if (command.contains('python3 -c')) {
          return _buildExecSession(
            stdout: '''
[
  {
    "sessionId": "7b9feba4-ca71-4c6f-8b31-478231f7154d",
    "summary": "Implement antigravity",
    "workingDirectory": "/Users/depoll/Code/flutty",
    "lastActive": "2026-05-22T21:45:35Z"
  }
]
''',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        workingDirectory: '/Users/depoll/Code/flutty',
        toolName: 'Antigravity',
      );

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'Antigravity');
      expect(
        result.sessions.single.sessionId,
        '7b9feba4-ca71-4c6f-8b31-478231f7154d',
      );
      expect(result.sessions.single.summary, 'Implement antigravity');
      expect(
        result.sessions.single.workingDirectory,
        '/Users/depoll/Code/flutty',
      );
      expect(
        result.sessions.single.lastActive,
        DateTime.parse('2026-05-22T21:45:35Z'),
      );
      final pythonCommand = commands.singleWhere(
        (command) => command.contains('python3 -c'),
      );
      expect(
        pythonCommand,
        contains('summary = history_entry.get("display") or title'),
      );

      expect(
        commands.where((command) => command.contains('python3 -c')),
        hasLength(1),
      );
    });

    test(
      'all-provider discovery skips ACP probes for fast panel loads',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        when(() => client.execute(any())).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          commands.add(command);
          if (command.contains('worktree list --porcelain')) {
            return _buildExecSession(
              stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
            );
          }
          if (command.contains('~/.local/share/opencode/opencode.db')) {
            return _buildExecSession(
              stdout:
                  'session-1\x1fOpenCode fast path\x1f/Users/depoll/Code/flutty\x1f1770000000\n',
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery.discoverSessions(
          session,
          workingDirectory: '/Users/depoll/Code/flutty',
        );

        expect(
          result.sessions.map((session) => session.toolName),
          contains('OpenCode'),
        );
        expect(commands.where((command) => command.contains(' acp')), isEmpty);
        expect(
          commands.where(
            (command) =>
                command.contains('~/.local/share/opencode/opencode.db'),
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'MonkeyMux discovery uses control-channel commands and skips ACP exec',
      () async {
        final client = _MockSshClient();
        final backendService = _MockTerminalConnectionBackendService();
        final backend = _MockTerminalConnectionBackend();
        final commands = <String>[];
        final session = _buildDiscoverySession(client)
          ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
          ..remoteMuxSessionName = 'dev';

        when(() => backendService.resolve(session)).thenReturn(backend);
        when(() => backend.capabilities).thenReturn(
          const TerminalBackendCapabilities(
            supportsWindows: true,
            supportsClientCommands: true,
            clientCommandsUseControlChannel: true,
          ),
        );
        when(
          () =>
              backend.runClientCommand(any(), priority: any(named: 'priority')),
        ).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          commands.add(command);
          final output = command.contains('~/.local/share/opencode/opencode.db')
              ? 'session-1\x1fOpenCode mmux\x1f/Users/depoll/Code/flutty\x1f1770000000\n'
              : '';
          return TerminalClientCommandResult(
            output: _markedDiscoveryOutput(output),
            exitCode: 0,
          );
        });

        final discovery = AgentSessionDiscoveryService(
          terminalBackendService: backendService,
        );
        final result = await discovery.discoverSessions(
          session,
          workingDirectory: '/Users/depoll/Code/flutty',
          toolName: 'OpenCode',
        );

        expect(result.sessions.map((session) => session.sessionId), [
          'session-1',
        ]);
        expect(
          commands.where((command) => command.contains('opencode acp')),
          isEmpty,
        );
        expect(
          commands.where(
            (command) =>
                command.contains('~/.local/share/opencode/opencode.db'),
          ),
          hasLength(1),
        );
        verifyNever(() => client.execute(any()));
      },
    );

    test(
      'all-provider stream emits lightweight previews before final aggregate',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        when(() => client.execute(any())).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          commands.add(command);
          if (command.contains('~/.local/share/opencode/opencode.db')) {
            return _buildExecSession(
              stdout: List<String>.generate(
                4,
                (index) =>
                    'session-$index\x1fOpenCode $index\x1f/Users/demo/project\x1f${1770000000 - index}',
              ).join('\n'),
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);

        final results = await discovery
            .discoverSessionsStream(session, maxPerTool: 2)
            .toList();

        expect(results, hasLength(greaterThan(1)));
        expect(
          results.take(results.length - 1),
          everyElement(
            isA<DiscoveredSessionsResult>()
                .having(
                  (result) => result.attemptedTools,
                  'attemptedTools',
                  hasLength(1),
                )
                .having(
                  (result) => result.sessions,
                  'sessions',
                  hasLength(lessThanOrEqualTo(1)),
                ),
          ),
        );
        expect(results.last.attemptedTools, contains('OpenCode'));
        expect(results.last.sessions.map((session) => session.sessionId), [
          'session-0',
        ]);
        expect(
          commands.where((command) => command.contains('LIMIT 12;')),
          isNotEmpty,
        );
      },
    );

    test('parses large remote snapshots off the UI isolate', () async {
      final client = _MockSshClient();
      const geminiPath =
          '/Users/demo/.gemini/tmp/flutty/chats/session-large.json';
      final largeSessionJson = jsonEncode({
        'sessionId': 'session-large',
        'summary': 'Large Gemini session',
        'lastUpdated': '2026-04-12T21:29:53.292Z',
        'kind': 'main',
        'messages': const <Object?>[],
        'padding': List<String>.filled(9000, 'x').join(),
      });

      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('find ~/.gemini/tmp')) {
          return _buildExecSession(stdout: geminiPath);
        }
        if (command.contains(geminiPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(geminiPath, largeSessionJson),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery.discoverSessions(
        session,
        toolName: 'Gemini CLI',
      );

      expect(result.sessions.map((session) => session.sessionId), [
        'session-large',
      ]);
      expect(result.sessions.single.summary, 'Large Gemini session');
    });

    test('returns when SSH exec stdout stays open after done marker', () async {
      final client = _MockSshClient();
      const geminiPath =
          '/Users/demo/.gemini/tmp/flutty/chats/session-open.json';
      final sessionJson = jsonEncode({
        'sessionId': 'session-open',
        'summary': 'Open stream Gemini session',
        'lastUpdated': '2026-04-12T21:29:53.292Z',
        'kind': 'main',
        'messages': const <Object?>[],
      });

      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('find ~/.gemini/tmp')) {
          return _buildOpenMarkerExecSession(stdout: geminiPath);
        }
        if (command.contains(geminiPath)) {
          return _buildOpenMarkerExecSession(
            stdout: _remoteSnapshotLine(geminiPath, sessionJson),
          );
        }
        return _buildOpenMarkerExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery
          .discoverSessions(session, toolName: 'Gemini CLI')
          .timeout(const Duration(seconds: 2));

      expect(result.sessions.map((session) => session.sessionId), [
        'session-open',
      ]);
    });

    test(
      'Codex discovery uses resumable UUID instead of rollout filename',
      () async {
        final client = _MockSshClient();
        const rolloutPath =
            '/Users/demo/.codex/sessions/2026/04/26/'
            'rollout-2026-04-26T15-44-01-'
            '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d.jsonl';
        const sessionId = '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d';
        when(() => client.execute(any())).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          if (command.contains('find ~/.codex/sessions')) {
            return _buildExecSession(stdout: rolloutPath);
          }
          if (command.contains('~/.codex/session_index.jsonl')) {
            return _buildExecSession(
              stdout:
                  '{"id":"$sessionId","thread_name":"Fix tmux titles",'
                  ' "updated_at":"2026-04-26T22:44:35.656609Z"}\n',
            );
          }
          if (command.contains(rolloutPath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(rolloutPath, '''
{"timestamp":"2026-04-26T22:44:20.349Z","type":"session_meta","payload":{"id":"$sessionId","timestamp":"2026-04-26T22:44:01.169Z","cwd":"/Users/depoll/Code/flutty"}}
{"timestamp":"2026-04-26T22:44:48.390Z","type":"event_msg","payload":{"type":"user_message","message":"fix codex resume","images":[]}}
''', mtime: 1777243460),
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery.discoverSessions(
          session,
          toolName: 'Codex',
        );

        expect(result.sessions, hasLength(1));
        expect(result.sessions.single.sessionId, sessionId);
        expect(
          discovery.buildResumeCommand(result.sessions.single),
          "cd '/Users/depoll/Code/flutty' && codex resume '$sessionId'",
        );
      },
    );

    test('Cursor discovery resolves chat id, title, and cwd', () async {
      final client = _MockSshClient();
      const metaPath =
          '/Users/demo/.cursor/chats/7fb0188e9fe01ef050275e8289ce9696/'
          'f21ed2df-500d-46a5-b55f-12b64268491f/meta.json';
      const chatId = 'f21ed2df-500d-46a5-b55f-12b64268491f';
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('find ~/.cursor/chats')) {
          return _buildExecSession(stdout: metaPath);
        }
        if (command.contains(metaPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(metaPath, '''
{"schemaVersion":1,"createdAtMs":1783404550969,"hasConversation":true,"title":"Copilot Theming Fix","updatedAtMs":1783405351095,"cwd":"/Users/depoll/Code/flutty"}
''', mtime: 1777243460),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        toolName: 'Cursor Agent',
      );

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Cursor Agent');
      expect(info.sessionId, chatId);
      expect(info.summary, 'Copilot Theming Fix');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        info.lastActive,
        DateTime.fromMillisecondsSinceEpoch(1783405351095),
      );
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && cursor-agent --resume '$chatId'",
      );
    });

    test('Grok Build discovery resolves resumable summary metadata', () async {
      final client = _MockSshClient();
      const summaryPath =
          '/Users/demo/.grok/sessions/%2FUsers%2Fdepoll%2FCode%2Fflutty/'
          '019f6cb5-f7e4-7bc1-bb25-9985af59619e/summary.json';
      const sessionId = '019f6cb5-f7e4-7bc1-bb25-9985af59619e';
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('GROK_SESSIONS_ROOT')) {
          return _buildExecSession(stdout: summaryPath);
        }
        if (command.contains(summaryPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(summaryPath, '''
{
  "info": {"id": "$sessionId", "cwd": "/Users/depoll/Code/flutty"},
  "session_summary": "Initial Grok task",
  "generated_title": "Add Grok Build support",
  "created_at": "2026-08-14T20:00:00Z",
  "updated_at": "2026-08-14T20:05:00Z",
  "last_active_at": "2026-08-14T20:04:00Z",
  "current_model_id": "grok-code-fast-1",
  "num_messages": 12
}
''', mtime: 1786740000),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        toolName: 'Grok Build',
      );

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Grok Build');
      expect(info.sessionId, sessionId);
      expect(info.summary, 'Add Grok Build support');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(info.lastActive, DateTime.parse('2026-08-14T20:04:00Z'));
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && grok --resume '$sessionId'",
      );
      expect(
        discovery.buildResumeCommand(info, startInYoloMode: true),
        "cd '/Users/depoll/Code/flutty' && grok --yolo --resume '$sessionId'",
      );
    });

    test(
      'Grok Build Windows discovery lets GROK_HOME override default',
      () async {
        final client = _MockSshClient();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

        const summaryPath =
            'C:/grok-home/sessions/C%3A%5Cwork%5Crepo/win-session/summary.json';
        final issuedScripts = <String>[];
        when(() => client.execute(any())).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          final script = _decodeEncodedPowerShell(command);
          issuedScripts.add(script);
          if (script.contains('[char]0x1f') && script.contains(summaryPath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(summaryPath, r'''
{
  "info": {"id": "win-session", "cwd": "C:\\work\\repo"},
  "generated_title": "Resume from custom Grok home",
  "last_active_at": "2026-08-14T20:04:00Z"
}
''', mtime: 1786740000),
            );
          }
          if (script.contains('Get-ChildItem') &&
              script.contains(r'$env:GROK_HOME') &&
              script.contains("'summary.json'")) {
            return _buildExecSession(stdout: '$summaryPath\n');
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery.discoverSessions(
          session,
          toolName: 'Grok Build',
        );

        expect(
          result.sessions,
          hasLength(1),
          reason: issuedScripts.join('\n--- command ---\n'),
        );
        expect(result.sessions.single.sessionId, 'win-session');
        expect(result.sessions.single.summary, 'Resume from custom Grok home');
        final listScripts = issuedScripts
            .where(
              (script) =>
                  script.contains('Get-ChildItem') &&
                  script.contains("'summary.json'"),
            )
            .toList(growable: false);
        expect(listScripts, hasLength(1));
        expect(listScripts.single, contains(r'$env:GROK_HOME'));
        expect(
          listScripts.single,
          contains(
            r'if(![string]::IsNullOrWhiteSpace([string]$__flOverrideBase)){',
          ),
        );
      },
    );

    test('Pi discovery resolves session id, name, and cwd', () async {
      final client = _MockSshClient();
      const sessionPath =
          '/Users/demo/.pi/agent/sessions/--Users-depoll-Code-flutty--/'
          '2026-04-12T21-07-44-781Z_01JYX7ABCD.jsonl';
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('find ~/.pi/agent/sessions')) {
          return _buildExecSession(stdout: sessionPath);
        }
        if (command.contains(sessionPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(sessionPath, '''
{"type":"session","version":3,"id":"01JYX7ABCD","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/flutty"}
{"type":"message","message":{"role":"user","content":"Fix the tmux navigator crash"}}
''', mtime: 1777243460),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(session, toolName: 'Pi');

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Pi');
      expect(info.sessionId, '01JYX7ABCD');
      expect(info.summary, 'Fix the tmux navigator crash');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && pi --session '01JYX7ABCD'",
      );
    });

    test('Hermes discovery reads the state database', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('state.db')) {
          return _buildExecSession(
            stdout: <String>[
              '20250305_091523_a1b2c3',
              'Refactor auth',
              '/Users/depoll/Code/flutty',
              '1783405351',
            ].join('\x1f'),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        toolName: 'Hermes',
      );

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Hermes');
      expect(info.sessionId, '20250305_091523_a1b2c3');
      expect(info.summary, 'Refactor auth');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && "
        "hermes --resume '20250305_091523_a1b2c3'",
      );
      // Gateway chats from messaging platforms must stay out of the picker,
      // and HERMES_HOME must be honoured when set. The SQL is shell-quoted,
      // so assert on tokens that survive escaping.
      final query = commands.firstWhere((c) => c.contains('state.db'));
      expect(query, contains('source IN ('));
      expect(query, contains('cli'));
      expect(query, contains('tui'));
      expect(query, contains('parent_session_id IS NULL'));
      expect(query, contains(r'${HERMES_HOME:-$HOME/.hermes}/state.db'));
    });

    test('toolName limits discovery to the requested provider', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('opencode session list --format json')) {
          return _buildExecSession(
            stdout:
                '[{"id":"session-1","title":"OpenCode only","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
          );
        }
        if (command.contains('find ~/.codex/sessions')) {
          return _buildExecSession(stdout: '/tmp/rollout-should-not-run.jsonl');
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery.discoverSessions(
        session,
        toolName: 'OpenCode',
      );

      expect(result.sessions.map((session) => session.toolName), ['OpenCode']);
      expect(result.sessions.map((session) => session.sessionId), [
        'session-1',
      ]);
      expect(
        commands.where(
          (command) => command.contains('opencode session list --format json'),
        ),
        hasLength(1),
      );
      expect(
        commands.where((command) => command.contains('find ~/.codex/sessions')),
        isEmpty,
      );
    });

    test('prefetchSessions warms the cache for the next visible load', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('opencode session list --format json')) {
          return _buildExecSession(
            stdout:
                '[{"id":"session-1","title":"Prefetched result","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      await discovery.prefetchSessions(session, maxPerTool: 6);
      final commandCountAfterPrefetch = commands.length;
      final result = await discovery.discoverSessionsStream(session).first;

      expect(result.sessions.map((session) => session.sessionId), [
        'session-1',
      ]);
      expect(commands.length, commandCountAfterPrefetch);
    });

    test('reuses fresh results for repeated loads in the same scope', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any())).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('opencode session list --format json')) {
          return _buildExecSession(
            stdout:
                '[{"id":"session-1","title":"Cache result","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final firstResults = await discovery
          .discoverSessionsStream(session)
          .toList();
      final firstCommandCount = commands.length;
      final secondResults = await discovery
          .discoverSessionsStream(session)
          .toList();

      expect(firstResults, isNotEmpty);
      expect(firstResults.last.sessions.map((session) => session.sessionId), [
        'session-1',
      ]);
      expect(secondResults, hasLength(1));
      expect(
        secondResults.single.sessions.map((session) => session.sessionId),
        ['session-1'],
      );
      expect(commands.length, firstCommandCount);
    });

    test(
      'reuses related worktree lookups across max-per-tool refreshes',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        when(() => client.execute(any())).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          commands.add(command);
          if (command.contains('worktree list --porcelain')) {
            return _buildExecSession(
              stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
            );
          }
          if (command.contains('opencode session list --format json')) {
            return _buildExecSession(
              stdout:
                  '[{"id":"session-1","title":"Scoped cache result","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);

        final firstResults = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: '/Users/depoll/Code/flutty',
            )
            .toList();
        final secondResults = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: '/Users/depoll/Code/flutty',
              maxPerTool: 24,
            )
            .toList();

        expect(firstResults.last.sessions.map((session) => session.sessionId), [
          'session-1',
        ]);
        expect(
          secondResults.last.sessions.map((session) => session.sessionId),
          ['session-1'],
        );
        expect(
          commands.where(
            (command) => command.contains('worktree list --porcelain'),
          ),
          hasLength(1),
        );
        expect(
          commands.where(
            (command) =>
                command.contains('opencode session list --format json'),
          ),
          hasLength(2),
        );
      },
    );
  });
}
