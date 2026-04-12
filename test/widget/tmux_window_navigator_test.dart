// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';

void main() {
  group('tmux navigator UI', () {
    final windows = [
      const TmuxWindow(
        index: 0,
        name: 'vim',
        isActive: true,
        currentCommand: 'vim',
        currentPath: '/home/user/project',
      ),
      const TmuxWindow(
        index: 1,
        name: 'claude',
        isActive: false,
        currentCommand: 'claude',
        idleSeconds: 120,
      ),
      const TmuxWindow(index: 2, name: 'bash', isActive: false),
      const TmuxWindow(
        index: 3,
        name: 'htop',
        isActive: false,
        currentCommand: 'htop',
      ),
    ];

    testWidgets('renders window list with correct statuses', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _MockWindowList(windows: windows)),
        ),
      );

      expect(find.text('vim'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('htop'), findsOneWidget);
      // Only "waiting" shows as a status — active/running are silent.
      expect(find.text('waiting'), findsOneWidget);
    });

    testWidgets('renders tmux badge with window chips', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF00796B),
            useMaterial3: true,
          ),
          home: Scaffold(body: _MockTmuxBadge(windows: windows.sublist(0, 3))),
        ),
      );

      expect(find.text('tmux:'), findsOneWidget);
      expect(find.text('vim'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
    });

    testWidgets('recent session tile shows time ago', (tester) async {
      final session = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc123',
        summary: 'Fix auth middleware',
        lastActive: DateTime.now().subtract(const Duration(hours: 2)),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListTile(
              title: Text(session.summary!),
              subtitle: Text('${session.toolName} · ${session.timeAgoLabel}'),
              trailing: TextButton(
                onPressed: () {},
                child: const Text('Resume'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Fix auth middleware'), findsOneWidget);
      expect(find.text('Claude Code · 2h ago'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
    });
  });
}

class _MockWindowList extends StatelessWidget {
  const _MockWindowList({required this.windows});
  final List<TmuxWindow> windows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: windows
          .map(
            (w) => ListTile(
              dense: true,
              leading: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: w.isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${w.index}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: w.isActive
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(w.name),
              trailing: Text(w.statusLabel),
              selected: w.isActive,
            ),
          )
          .toList(),
    );
  }
}

class _MockTmuxBadge extends StatelessWidget {
  const _MockTmuxBadge({required this.windows});
  final List<TmuxWindow> windows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(
              Icons.window_outlined,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              'tmux:',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            for (final window in windows) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: window.isActive
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  window.name,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: window.isActive
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: window.isActive
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }
}
