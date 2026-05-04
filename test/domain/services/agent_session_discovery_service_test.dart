import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

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

SSHSession _buildExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _utf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _utf8Stream(stderr));
  when(() => session.write(any())).thenAnswer(_ignoreInvocation);
  when(session.close).thenAnswer(_ignoreInvocation);
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

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
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

  group('discoverSessionsStream caching', () {
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
