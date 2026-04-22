import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
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

    test('keeps the discovered count visible while refreshing', () {
      const entry = AiSessionProviderEntry(
        toolName: 'Codex',
        sessions: <ToolSessionInfo>[
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: 'session-1',
            summary: 'Refresh in place',
          ),
        ],
        wasAttempted: true,
        hasFailure: false,
        isLoading: true,
      );

      expect(entry.statusLabel, '1 session');
      expect(entry.compactStatusLabel, '1');
    });
  });

  group('AiSessionProviderList', () {
    testWidgets('live updates provider rows in place', (tester) async {
      final claudeController = StreamController<DiscoveredSessionsResult>();
      final codexController = StreamController<DiscoveredSessionsResult>();
      addTearDown(() async {
        if (!claudeController.isClosed) {
          await claudeController.close();
        }
        if (!codexController.isClosed) {
          await codexController.close();
        }
      });

      await tester.pumpWidget(
        _wrap(
          AiSessionProviderList(
            orderedTools: const ['Claude Code', 'Codex'],
            loadSessionsForTool: (toolName, _) => switch (toolName) {
              'Claude Code' => claudeController.stream,
              'Codex' => codexController.stream,
              _ => Stream<DiscoveredSessionsResult>.value(
                DiscoveredSessionsResult(sessions: const []),
              ),
            },
            itemBuilder: (context, provider) => Text(
              '${provider.toolName}|${provider.compactStatusLabel}|'
              '${provider.isLoading ? 'loading' : 'idle'}|'
              '${provider.hasFailure ? 'error' : 'ok'}',
            ),
          ),
        ),
      );

      expect(find.text('Claude Code|loading|loading|ok'), findsOneWidget);
      expect(find.text('Codex|loading|loading|ok'), findsOneWidget);

      codexController.add(
        DiscoveredSessionsResult(
          sessions: const <ToolSessionInfo>[
            ToolSessionInfo(
              toolName: 'Codex',
              sessionId: 'session-1',
              summary: 'Fix the tmux menu refresh',
            ),
          ],
          attemptedTools: const <String>{'Codex'},
        ),
      );
      await tester.pump();

      expect(find.text('Codex|1|idle|ok'), findsOneWidget);
      expect(find.text('Claude Code|loading|loading|ok'), findsOneWidget);

      await codexController.close();
      await tester.pump();

      expect(find.text('Codex|1|idle|ok'), findsOneWidget);
      expect(find.text('Claude Code|loading|loading|ok'), findsOneWidget);

      claudeController.add(
        DiscoveredSessionsResult(
          sessions: const <ToolSessionInfo>[],
          attemptedTools: const <String>{'Claude Code'},
        ),
      );
      await claudeController.close();
      await tester.pump();

      expect(find.text('Claude Code|no recent|idle|ok'), findsOneWidget);
    });

    testWidgets('keeps the visible provider order stable', (tester) async {
      final controllers = <String, StreamController<DiscoveredSessionsResult>>{
        'Claude Code': StreamController<DiscoveredSessionsResult>(),
        'Codex': StreamController<DiscoveredSessionsResult>(),
      };
      addTearDown(() async {
        for (final controller in controllers.values) {
          if (!controller.isClosed) {
            await controller.close();
          }
        }
      });

      var orderedTools = const ['Claude Code', 'Codex'];

      await tester.pumpWidget(
        _wrap(
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      orderedTools = const ['Codex', 'Claude Code'];
                    });
                  },
                  child: const Text('Reorder'),
                ),
                AiSessionProviderList(
                  orderedTools: orderedTools,
                  loadSessionsForTool: (toolName, _) =>
                      controllers[toolName]!.stream,
                  itemBuilder: (context, provider) => Text(
                    provider.toolName,
                    key: ValueKey<String>(provider.toolName),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final claudeBefore = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Claude Code')),
      );
      final codexBefore = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Codex')),
      );
      expect(claudeBefore.dy, lessThan(codexBefore.dy));

      await tester.tap(find.text('Reorder'));
      await tester.pump();

      final claudeAfter = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Claude Code')),
      );
      final codexAfter = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Codex')),
      );
      expect(claudeAfter.dy, lessThan(codexAfter.dy));
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
                  loadSessions: (_) => Stream<DiscoveredSessionsResult>.value(
                    DiscoveredSessionsResult(
                      sessions: const <ToolSessionInfo>[selectedSession],
                      attemptedTools: const <String>{'Codex'},
                    ),
                  ),
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
