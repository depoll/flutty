// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_navigator.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_status_badge.dart';

void main() {
  group('TmuxWindowStatusBadge', () {
    testWidgets('shows waiting for the active idle window', (tester) async {
      const window = TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: true,
        currentCommand: 'claude',
        idleSeconds: 120,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      expect(find.text('waiting'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_bottom), findsOneWidget);
    });

    testWidgets('shows running for the active window by default', (
      tester,
    ) async {
      const window = TmuxWindow(index: 0, name: 'vim', isActive: true);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      expect(find.text('running'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('uses high-contrast container colors for alert badges', (
      tester,
    ) async {
      const scheme = ColorScheme.light(
        errorContainer: Color(0xFF112233),
        onErrorContainer: Color(0xFFF1E2D3),
      );
      const window = TmuxWindow(
        index: 2,
        name: 'logs',
        isActive: false,
        flags: '#!',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: const Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      final badge = tester.widget<DecoratedBox>(
        find.byType(DecoratedBox).first,
      );
      final decoration = badge.decoration as BoxDecoration;
      final icon = tester.widget<Icon>(find.byIcon(Icons.notifications_active));
      final text = tester.widget<Text>(find.text('alert'));

      expect(decoration.color, scheme.errorContainer);
      expect(icon.color, scheme.onErrorContainer);
      expect(text.style?.color, scheme.onErrorContainer);
    });
  });

  group('tmux navigator UI', () {
    final windows = [
      const TmuxWindow(
        index: 0,
        name: 'vim',
        isActive: true,
        currentCommand: 'vim',
        currentPath: '/home/user/project',
        paneTitle: '✨ Editing main.dart',
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

      expect(find.text('✨ Editing main.dart'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('htop'), findsOneWidget);
      expect(find.text('running'), findsNWidgets(3));
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
      expect(find.text('✨ Editing main.dart'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
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

    testWidgets('new window picker stays above the visible keyboard', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetViewInsets();
      });

      final tmuxService = _MockTmuxService();
      final presetService = _MockAgentLaunchPresetService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final session = SshSession(
        connectionId: 1,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );
      const tmuxSessionName = 'main';

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => {AgentLaunchTool.claudeCode});
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: tmuxSessionName,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Window'));
      await tester.pumpAndSettle();

      expect(find.text('Empty window'), findsOneWidget);
      expect(
        tester.getBottomLeft(find.text('Empty window')).dy,
        lessThan(844 - 240),
      );
      final keyboardPadding = tester
          .widgetList<AnimatedPadding>(find.byType(AnimatedPadding))
          .where(
            (widget) => widget.padding == const EdgeInsets.only(bottom: 240),
          );
      expect(keyboardPadding, isNotEmpty);
    });

    testWidgets('loads AI session providers only after expanding the section', (
      tester,
    ) async {
      final tmuxService = _MockTmuxService();
      final presetService = _MockAgentLaunchPresetService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final session = SshSession(
        connectionId: 1,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );
      const tmuxSessionName = 'main';

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tmuxServiceProvider.overrideWithValue(tmuxService),
            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
            agentSessionDiscoveryServiceProvider.overrideWithValue(
              discoveryService,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () {
                    unawaited(
                      showTmuxNavigator(
                        context: context,
                        ref: ref,
                        session: session,
                        tmuxSessionName: tmuxSessionName,
                        isProUser: true,
                        startClisInYoloMode: false,
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Recent AI Sessions'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);
      verifyNever(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      );
      verifyNever(() => tmuxService.detectInstalledAgentTools(session));

      await tester.ensureVisible(find.text('Recent AI Sessions'));
      await tester.pump();
      await tester.tap(find.text('Recent AI Sessions'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      verify(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).called(1);
    });

    testWidgets('passes host yolo mode when resuming an AI session', (
      tester,
    ) async {
      final tmuxService = _MockTmuxService();
      final presetService = _MockAgentLaunchPresetService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final session = SshSession(
        connectionId: 1,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );
      const tmuxSessionName = 'main';
      const codexSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'codex-session',
        workingDirectory: '/home/demo/project',
        summary: 'Resume codex work',
      );
      TmuxNavigatorAction? selectedAction;

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer((invocation) {
        final toolName = invocation.namedArguments[#toolName] as String?;
        return Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(
            sessions: toolName == 'Codex'
                ? const <ToolSessionInfo>[codexSession]
                : const <ToolSessionInfo>[],
            attemptedTools: toolName == null ? const <String>[] : [toolName],
          ),
        );
      });
      when(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).thenReturn("codex --yolo resume 'codex-session'");

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: tmuxSessionName,
        startClisInYoloMode: true,
        onActionSelected: (action) => selectedAction = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Recent AI Sessions'));
      await tester.pump();
      await tester.tap(find.text('Recent AI Sessions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Codex'));
      await tester.pump();
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume codex work'));
      await tester.pumpAndSettle();

      expect(selectedAction, isA<TmuxResumeSessionAction>());
      final resumeAction = selectedAction! as TmuxResumeSessionAction;
      expect(resumeAction.resumeCommand, "codex --yolo resume 'codex-session'");
      expect(resumeAction.workingDirectory, '/home/demo/project');
      verify(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).called(1);
    });

    testWidgets('recovers from a transient empty window reload', (
      tester,
    ) async {
      final tmuxService = _MockTmuxService();
      final presetService = _MockAgentLaunchPresetService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final session = SshSession(
        connectionId: 1,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );
      const tmuxSessionName = 'main';
      var listWindowsCallCount = 0;

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(() => tmuxService.listWindows(session, tmuxSessionName)).thenAnswer((
        _,
      ) {
        if (listWindowsCallCount++ == 0) {
          return Future<List<TmuxWindow>>.value(const <TmuxWindow>[]);
        }
        return Future<List<TmuxWindow>>.value(windows);
      });
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: tmuxSessionName,
      );

      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(find.text('✨ Editing main.dart'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('✨ Editing main.dart'), findsOneWidget);
    });

    testWidgets('stops showing an indefinite spinner after repeated empties', (
      tester,
    ) async {
      final tmuxService = _MockTmuxService();
      final presetService = _MockAgentLaunchPresetService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final session = SshSession(
        connectionId: 1,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );
      const tmuxSessionName = 'main';

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => const <TmuxWindow>[]);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: tmuxSessionName,
      );

      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(
        find.text(
          'Could not load tmux windows. Check that tmux is still running, then try again.',
        ),
        findsOneWidget,
      );
    });
  });
}

Future<void> _pumpNavigatorHost(
  WidgetTester tester, {
  required TmuxService tmuxService,
  required AgentLaunchPresetService presetService,
  required AgentSessionDiscoveryService discoveryService,
  required SshSession session,
  required String tmuxSessionName,
  bool startClisInYoloMode = false,
  ValueChanged<TmuxNavigatorAction?>? onActionSelected,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tmuxServiceProvider.overrideWithValue(tmuxService),
        agentLaunchPresetServiceProvider.overrideWithValue(presetService),
        agentSessionDiscoveryServiceProvider.overrideWithValue(
          discoveryService,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () {
                unawaited(
                  showTmuxNavigator(
                    context: context,
                    ref: ref,
                    session: session,
                    tmuxSessionName: tmuxSessionName,
                    isProUser: true,
                    startClisInYoloMode: startClisInYoloMode,
                  ).then((action) => onActionSelected?.call(action)),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.pump();
  await tester.pump();
}

class _MockTmuxService extends Mock implements TmuxService {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

class _MockAgentSessionDiscoveryService extends Mock
    implements AgentSessionDiscoveryService {}

class _MockSshClient extends Mock implements SSHClient {}

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
              title: Text(w.displayTitle),
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
                  window.displayTitle,
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
