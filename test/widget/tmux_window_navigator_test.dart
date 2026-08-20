// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/remote_multiplexer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_mux_window_status_badge.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/premium_badge.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_navigator.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_status_badge.dart';

import '../support/fake_acp_session_manager.dart';

class _TestConfirmMuxWindowCloseNotifier extends ConfirmMuxWindowCloseNotifier {
  @override
  bool build() => true;

  @override
  Future<void> setEnabled({required bool enabled}) async {
    state = enabled;
  }
}

class _ConfirmCloseHost extends ConsumerStatefulWidget {
  const _ConfirmCloseHost();

  @override
  ConsumerState<_ConfirmCloseHost> createState() => _ConfirmCloseHostState();
}

class _ConfirmCloseHostState extends ConsumerState<_ConfirmCloseHost> {
  var _confirmedCount = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(
          onPressed: () async {
            if (await confirmMuxWindowClose(
                  context: context,
                  ref: ref,
                  title: 'shell',
                ) &&
                mounted) {
              setState(() => _confirmedCount++);
            }
          },
          child: const Text('Request close'),
        ),
        Text('confirmed $_confirmedCount'),
      ],
    ),
  );
}

void main() {
  testWidgets('native mux handle shows provider icon without window number', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: buildNativeAcpHandleIcon(
                theme: Theme.of(context),
                tool: AgentLaunchTool.cursorAgent,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('native-acp-handle-icon')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('native-acp-handle-indicator')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('native-acp-handle-index')), findsNothing);
    expect(
      tester
          .widget<AgentToolIcon>(
            find.byKey(const ValueKey('native-acp-handle-icon')),
          )
          .tool,
      AgentLaunchTool.cursorAgent,
    );
  });

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

  testWidgets('Don’t ask me again disables future mux close prompts', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          confirmMuxWindowCloseNotifierProvider.overrideWith(
            _TestConfirmMuxWindowCloseNotifier.new,
          ),
        ],
        child: const MaterialApp(home: _ConfirmCloseHost()),
      ),
    );

    await tester.tap(find.text('Request close'));
    await tester.pumpAndSettle();
    expect(find.text('Close window?'), findsOneWidget);
    expect(find.text('Don’t ask me again'), findsOneWidget);
    await tester.tap(find.text('Don’t ask me again'));
    await tester.tap(find.widgetWithText(FilledButton, 'Close window'));
    await tester.pumpAndSettle();

    expect(find.text('confirmed 1'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_ConfirmCloseHost)),
    );
    expect(container.read(confirmMuxWindowCloseNotifierProvider), isFalse);

    await tester.tap(find.text('Request close'));
    await tester.pumpAndSettle();
    expect(find.text('Close window?'), findsNothing);
    expect(find.text('confirmed 2'), findsOneWidget);
  });

  testWidgets('native mux badges show waiting and running', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AcpMuxWindowStatusBadge(session: fakeAcpSession()),
              AcpMuxWindowStatusBadge(
                session: fakeAcpSession(
                  promptStatus: AcpPromptStatus.streaming,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('waiting'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_bottom), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
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

    testWidgets('shows MonkeyMux terminal shortcuts', (tester) async {
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
      const sessionName = 'main';
      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.watchWindowChanges(session, sessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, sessionName),
      ).thenAnswer((_) async => windows);

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: sessionName,
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('monkeymux-shortcut-hint')),
        findsOneWidget,
      );
      expect(find.textContaining('Ctrl-B: c new'), findsOneWidget);
      expect(find.textContaining('& then y close'), findsOneWidget);
      expect(find.textContaining('d detach'), findsOneWidget);

      final closeButton = find.byTooltip('Close window').first;
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(find.text('Close window?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('windows'), findsOneWidget);
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
      await tester.tap(find.text('New window'));
      await tester.pumpAndSettle();

      expect(find.text('Empty terminal'), findsOneWidget);
      expect(
        tester.getBottomLeft(find.text('Empty terminal')).dy,
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
                        session: session,
                        tmuxSessionName: tmuxSessionName,
                        remoteMuxBackend: RemoteMuxBackend.tmux,
                        remoteMultiplexerService: TmuxRemoteMultiplexerService(
                          tmuxService,
                        ),
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

      await tester.scrollUntilVisible(
        find.text('Recent terminal sessions'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Recent terminal sessions'), findsOneWidget);
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

      await tester.scrollUntilVisible(
        find.text('Recent terminal sessions'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      await tester.tap(find.text('Recent terminal sessions'));
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

    testWidgets('resumes a supported history session as native ACP', (
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
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        startClisInYoloMode: true,
        onActionSelected: (action) => selectedAction = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recent terminal sessions'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      await tester.tap(find.text('Recent terminal sessions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Codex'));
      await tester.pump();
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume codex work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Native chat'));
      await tester.pumpAndSettle();

      expect(selectedAction, isA<TmuxResumeAcpSessionAction>());
      final resumeAction = selectedAction! as TmuxResumeAcpSessionAction;
      expect(resumeAction.providerId, AcpBuiltinProviderIds.codex);
      expect(resumeAction.acpSessionId, codexSession.sessionId);
      expect(resumeAction.workingDirectory, '/home/demo/project');
      verifyNever(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      );
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

      expect(find.text('Could not load tmux windows.'), findsOneWidget);
    });

    test('maps every verified ACP adapter to its terminal tool', () {
      final mapping = nativeAcpProvidersByTool([
        for (final provider in acpBuiltinProviders)
          AcpBuiltinProviderView(provider),
      ]);

      expect(
        mapping[AgentLaunchTool.copilotCli],
        AcpBuiltinProviderIds.copilotCli,
      );
      expect(
        mapping[AgentLaunchTool.claudeCode],
        AcpBuiltinProviderIds.claudeAgent,
      );
      expect(mapping[AgentLaunchTool.codex], AcpBuiltinProviderIds.codex);
      expect(mapping[AgentLaunchTool.openCode], AcpBuiltinProviderIds.openCode);
      expect(
        mapping[AgentLaunchTool.cursorAgent],
        AcpBuiltinProviderIds.cursorAgent,
      );
      expect(
        mapping[AgentLaunchTool.antigravity],
        AcpBuiltinProviderIds.antigravity,
      );
      expect(mapping[AgentLaunchTool.pi], AcpBuiltinProviderIds.pi);
    });

    testWidgets('ACP-capable tool offers a native mode to free users', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showTmuxNewWindowPicker(
                    context: context,
                    isProUser: false,
                    startClisInYoloMode: false,
                    installedToolsFuture: Future.value(const <AgentLaunchTool>{
                      AgentLaunchTool.copilotCli,
                    }),
                    nativeAcpProviderIds: const <AgentLaunchTool, String>{
                      AgentLaunchTool.copilotCli:
                          AcpBuiltinProviderIds.copilotCli,
                    },
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.text('native chat'), findsOneWidget);

      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Native chat'), findsOneWidget);
      expect(find.byType(PremiumBadge), findsOneWidget);

      await tester.tap(find.text('Native chat'));
      await tester.pumpAndSettle();

      expect(result, isA<TmuxNewAcpSessionAction>());
      expect(
        (result! as TmuxNewAcpSessionAction).providerId,
        AcpBuiltinProviderIds.copilotCli,
      );
    });

    testWidgets('terminal/native selector stays above the keyboard', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetViewInsets();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTmuxNewWindowPicker(
                  context: context,
                  isProUser: true,
                  startClisInYoloMode: false,
                  installedToolsFuture: Future.value(const <AgentLaunchTool>{
                    AgentLaunchTool.copilotCli,
                  }),
                  nativeAcpProviderIds: const <AgentLaunchTool, String>{
                    AgentLaunchTool.copilotCli:
                        AcpBuiltinProviderIds.copilotCli,
                  },
                ),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();

      final nativeChat = find.text('Native chat');
      expect(nativeChat, findsOneWidget);
      expect(tester.getBottomLeft(nativeChat).dy, lessThan(844 - 300));
      expect(
        tester
            .widgetList<AnimatedPadding>(find.byType(AnimatedPadding))
            .any(
              (widget) => widget.padding == const EdgeInsets.only(bottom: 300),
            ),
        isTrue,
      );
    });

    testWidgets('Pro user can choose terminal mode for an ACP-capable tool', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showTmuxNewWindowPicker(
                    context: context,
                    isProUser: true,
                    startClisInYoloMode: false,
                    installedToolsFuture: Future.value(const <AgentLaunchTool>{
                      AgentLaunchTool.openCode,
                    }),
                    nativeAcpProviderIds: const <AgentLaunchTool, String>{
                      AgentLaunchTool.openCode: AcpBuiltinProviderIds.openCode,
                    },
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenCode'));
      await tester.pumpAndSettle();
      final terminalTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Terminal'),
      );
      expect(terminalTile.enabled, isTrue);

      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(result, isA<TmuxNewWindowAction>());
      final action = result! as TmuxNewWindowAction;
      expect(action.windowName, 'opencode');
      expect(action.agentTool, AgentLaunchTool.openCode);
    });

    testWidgets('tool without ACP support opens a terminal directly', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showTmuxNewWindowPicker(
                    context: context,
                    isProUser: true,
                    startClisInYoloMode: false,
                    installedToolsFuture: Future.value(const <AgentLaunchTool>{
                      AgentLaunchTool.claudeCode,
                    }),
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Code'));
      await tester.pumpAndSettle();

      expect(find.text('Native chat'), findsNothing);
      expect(result, isA<TmuxNewWindowAction>());
      expect(
        (result! as TmuxNewWindowAction).agentTool,
        AgentLaunchTool.claudeCode,
      );
    });

    testWidgets('tmux navigator remains terminal-only', (tester) async {
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
      TmuxNavigatorAction? selected;

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(() => tmuxService.detectInstalledAgentTools(session)).thenAnswer(
        (_) async => const <AgentLaunchTool>{AgentLaunchTool.copilotCli},
      );

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: tmuxSessionName,
        acpManager: FakeAcpSessionManager(
          sessions: [fakeAcpSession(title: 'Native only')],
        ),
        onActionSelected: (action) => selected = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('agent windows'), findsNothing);

      await tester.tap(find.text('New window'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();

      expect(find.text('Native chat'), findsNothing);
      expect(selected, isA<TmuxNewWindowAction>());
    });

    testWidgets('MonkeyMux exposes the custom ACP provider picker', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showTmuxNewWindowPicker(
                    context: context,
                    isProUser: false,
                    startClisInYoloMode: false,
                    installedToolsFuture: Future.value(
                      const <AgentLaunchTool>{},
                    ),
                    allowNativeAcpProviderPicker: true,
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.text('Custom native chat'), findsOneWidget);

      await tester.tap(find.text('Custom native chat'));
      await tester.pumpAndSettle();

      expect(result, isA<TmuxNewAcpSessionAction>());
      expect((result! as TmuxNewAcpSessionAction).providerId, isNull);
    });

    testWidgets('MonkeyMux navigator lists and opens native ACP sessions', (
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
      final key = fakeAcpKey();
      final manager = FakeAcpSessionManager(
        sessions: [
          fakeAcpSession(
            key: key,
            title: 'Fix authentication',
            cwd: '/home/dev/monkeyssh',
            promptStatus: AcpPromptStatus.streaming,
            plan: const [
              AcpPlanEntry(
                content: 'done',
                priority: AcpPlanPriority.high,
                status: AcpPlanStatus.completed,
              ),
              AcpPlanEntry(
                content: 'next',
                priority: AcpPlanPriority.medium,
                status: AcpPlanStatus.inProgress,
              ),
            ],
          ),
          fakeAcpSession(
            key: fakeAcpKey(acpSessionId: 'failed-session'),
            title: 'Failed native session',
            status: AcpConnectionStatus.failed,
          ),
        ],
        recents: [
          AcpRecentSessionRef(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: 'archived-bridge',
            acpSessionId: 'archived-session',
            title: 'Archived native session',
            cwd: '/home/dev/monkeyssh',
            createdAt: DateTime(2025),
            lastActivityAt: DateTime(2026),
          ),
        ],
      );
      TmuxNavigatorAction? selected;

      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);

      await _pumpNavigatorHost(
        tester,
        tmuxService: tmuxService,
        presetService: presetService,
        discoveryService: discoveryService,
        session: session,
        tmuxSessionName: tmuxSessionName,
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        acpManager: manager,
        onActionSelected: (action) => selected = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('agent windows'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('agent windows'), findsOneWidget);
      expect(find.text('Fix authentication'), findsOneWidget);
      expect(find.text('Failed native session'), findsNothing);
      expect(find.text('Archived native session'), findsNothing);
      final nativeRow = find.byKey(ValueKey('native-acp-session-${key.value}'));
      expect(find.text('Copilot CLI · …/monkeyssh · working'), findsOneWidget);
      expect(
        find.descendant(of: nativeRow, matching: find.text('running')),
        findsOneWidget,
      );
      final numberSlot = find.byKey(
        ValueKey('native-acp-number-slot-${key.value}'),
      );
      expect(numberSlot, findsOneWidget);
      expect(
        find.descendant(of: numberSlot, matching: find.text('4')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: nativeRow,
          matching: find.byIcon(Icons.smart_toy_outlined),
        ),
        findsNothing,
      );
      final agentIcon = tester.widget<AgentToolIcon>(
        find.descendant(of: nativeRow, matching: find.byType(AgentToolIcon)),
      );
      expect(agentIcon.tool, AgentLaunchTool.copilotCli);
      expect(
        find.byKey(ValueKey('native-acp-indicator-${key.value}')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: nativeRow, matching: find.text('NATIVE')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('native-acp-progress-${key.value}')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: nativeRow,
          matching: find.byTooltip('Close window'),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Fix authentication'));
      await tester.pump();
      await tester.tap(find.text('Fix authentication'));
      await tester.pumpAndSettle();

      expect(selected, isA<TmuxOpenAcpSessionAction>());
      expect((selected! as TmuxOpenAcpSessionAction).key, key);
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
  RemoteMuxBackend remoteMuxBackend = RemoteMuxBackend.tmux,
  bool startClisInYoloMode = false,
  ValueChanged<TmuxNavigatorAction?>? onActionSelected,
  FakeAcpSessionManager? acpManager,
}) async {
  final resolvedAcpManager = acpManager ?? FakeAcpSessionManager();
  addTearDown(resolvedAcpManager.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        acpSessionManagerProvider.overrideWithValue(resolvedAcpManager),
        acpProvidersProvider.overrideWith(
          (ref) => Stream.value(<AcpProvider>[
            for (final provider in acpBuiltinProviders)
              AcpBuiltinProviderView(provider),
          ]),
        ),
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
                    session: session,
                    tmuxSessionName: tmuxSessionName,
                    remoteMuxBackend: remoteMuxBackend,
                    remoteMultiplexerService: TmuxRemoteMultiplexerService(
                      tmuxService,
                    ),
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
