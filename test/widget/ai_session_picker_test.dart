import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/widgets/ai_session_picker.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('buildAiSessionProviderEntries', () {
    test('derives loading, failure, and loaded provider states', () {
      const codexSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'session-1',
        summary: 'Fix the tmux menu refresh',
      );

      final entries = buildAiSessionProviderEntries(
        orderedTools: const ['Claude Code', 'Codex', 'Gemini CLI'],
        groupedSessions: const {
          'Codex': <ToolSessionInfo>[codexSession],
        },
        attemptedTools: const ['Codex'],
        failedTools: const ['Claude Code'],
        isLoading: true,
      );

      expect(entries[0].hasFailure, isTrue);
      expect(entries[0].statusLabel, 'Could not load recent sessions');
      expect(entries[1].hasSessions, isTrue);
      expect(entries[1].statusLabel, '1 session');
      expect(entries[2].isLoading, isTrue);
      expect(entries[2].compactStatusLabel, 'loading');
    });
  });

  group('AiSessionPickerDialog', () {
    testWidgets('returns the tapped session', (tester) async {
      const selectedSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'session-1',
        summary: 'Fix the tmux menu refresh',
      );
      ToolSessionInfo? picked;

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showAiSessionPickerDialog(
                  context: context,
                  toolName: 'Codex',
                  sessions: const [selectedSession],
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Fix the tmux menu refresh'), findsOneWidget);

      await tester.tap(find.text('Fix the tmux menu refresh'));
      await tester.pumpAndSettle();

      expect(picked, selectedSession);
    });
  });
}
