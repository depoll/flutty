import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';

void main() {
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
  });

  group('parseCodexRolloutMetadata', () {
    test('prefers the structured user_message event over input_text noise', () {
      final metadata = parseCodexRolloutMetadata('''
{"timestamp":"2026-04-12T21:07:44.781Z","type":"session_meta","cwd":"/Users/depoll/Code/flutty"}
{"timestamp":"2026-04-12T21:07:45.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"input_text","text":"<permissions instructions>"}]}}
{"timestamp":"2026-04-12T21:07:48.390Z","type":"event_msg","payload":{"type":"user_message","message":"rename this session","images":[]}}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.summary, 'rename this session');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:07:44.781Z'));
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
  });
}
