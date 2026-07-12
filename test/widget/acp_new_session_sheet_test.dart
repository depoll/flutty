// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/acp_new_session_sheet.dart';

import '../support/fake_acp_session_manager.dart';

class _FakeActiveSessions extends ActiveSessionsNotifier {
  _FakeActiveSessions({
    this.result = const SshConnectionResult(success: true, connectionId: 1),
  });

  final SshConnectionResult result;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{};

  @override
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    if (!result.success) {
      reportConnectionAttemptError(hostId, result.error ?? 'Connection failed');
    }
    return result;
  }
}

class _MockSshService extends Mock implements SshService {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

Host _host({
  int id = 1,
  String? tmuxWorkingDirectory,
  String? remoteMuxBackend,
}) => Host(
  id: id,
  label: 'Alpha',
  hostname: 'alpha.example.com',
  port: 22,
  username: 'root',
  password: null,
  keyId: null,
  groupId: null,
  jumpHostId: null,
  isFavorite: false,
  color: null,
  notes: null,
  tags: null,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  lastConnectedAt: null,
  terminalThemeLightId: null,
  terminalThemeDarkId: null,
  terminalFontFamily: null,
  autoConnectCommand: null,
  autoConnectSnippetId: null,
  autoConnectRequiresConfirmation: false,
  tmuxSessionName: null,
  tmuxWorkingDirectory: tmuxWorkingDirectory,
  tmuxExtraFlags: null,
  remoteMuxBackend: remoteMuxBackend,
  sortOrder: 0,
);

/// Pumps a launcher button that opens the new-session sheet, capturing the
/// returned key. Returns a getter for the captured key.
Future<AcpSessionKey? Function()> _pumpAndLaunch(
  WidgetTester tester,
  FakeAcpSessionManager manager, {
  AgentLaunchPreset? preset,
  int? initialHostId = 1,
  String? initialProviderId = AcpBuiltinProviderIds.copilotCli,
  bool startSession = true,
  SshConnectionResult connectionResult = const SshConnectionResult(
    success: true,
    connectionId: 1,
  ),
}) async {
  AcpSessionKey? returned;
  var completed = false;
  final ssh = _MockSshService();
  final presetService = _MockAgentLaunchPresetService();
  when(() => ssh.allSessions).thenReturn(const <SshSession>[]);
  when(() => ssh.getSessionsForHost(any())).thenReturn(const <SshSession>[]);
  when(
    () => presetService.getPresetForHost(any()),
  ).thenAnswer((_) async => preset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        acpSessionManagerProvider.overrideWithValue(manager),
        activeSessionsProvider.overrideWith(
          () => _FakeActiveSessions(result: connectionResult),
        ),
        sshServiceProvider.overrideWithValue(ssh),
        agentLaunchPresetServiceProvider.overrideWithValue(presetService),
        allHostsProvider.overrideWith((ref) => Stream.value(<Host>[_host()])),
        acpProvidersProvider.overrideWith(
          (ref) => Stream.value(<AcpProvider>[
            for (final builtin in acpBuiltinProviders)
              AcpBuiltinProviderView(builtin),
          ]),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                returned = await showAcpNewSessionSheet(
                  context,
                  initialHostId: initialHostId,
                  initialProviderId: initialProviderId,
                );
                completed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (startSession) {
    await tester.tap(find.widgetWithText(FilledButton, 'Start session'));
    await tester.pumpAndSettle();
  }
  return () => completed ? returned : null;
}

void main() {
  final key = fakeAcpKey();

  test('launch defaults prefer a host saved agent and MonkeyMux setup', () {
    final plainHost = _host(id: 1);
    final configuredHost = _host(
      id: 2,
      tmuxWorkingDirectory: '/mux-default',
      remoteMuxBackend: RemoteMuxBackend.monkeyMux.storageValue,
    );
    final defaults = resolveAcpSessionLaunchDefaults(
      hosts: [plainHost, configuredHost],
      providers: [
        for (final builtin in acpBuiltinProviders)
          AcpBuiltinProviderView(builtin),
      ],
      recents: const [],
      activeHostIds: const {},
      presets: const {
        2: AgentLaunchPreset(
          tool: AgentLaunchTool.openCode,
          workingDirectory: '/saved-agent-worktree',
          tmuxSessionName: 'agents',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        ),
      },
    );

    expect(defaults.hostId, 2);
    expect(defaults.providerId, AcpBuiltinProviderIds.openCode);
    expect(defaults.cwd, '/saved-agent-worktree');
  });

  testWidgets('shows the initial configuration stage after launch', (
    tester,
  ) async {
    final session = fakeAcpSession(
      key: key,
      configOptions: const [
        AcpSelectConfigOption(
          id: 'style',
          name: 'Style',
          currentValue: 'a',
          options: [
            AcpConfigValue(value: 'a', name: 'Alpha'),
            AcpConfigValue(value: 'b', name: 'Beta'),
          ],
        ),
      ],
    );
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    await _pumpAndLaunch(tester, manager);

    expect(find.text('configure session'), findsOneWidget);
    expect(find.text('Style'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open chat'), findsOneWidget);
  });

  testWidgets('applying a select option calls the config setter', (
    tester,
  ) async {
    final session = fakeAcpSession(
      key: key,
      configOptions: const [
        AcpSelectConfigOption(
          id: 'style',
          name: 'Style',
          currentValue: 'a',
          options: [
            AcpConfigValue(value: 'a', name: 'Alpha'),
            AcpConfigValue(value: 'b', name: 'Beta'),
          ],
        ),
      ],
    );
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    final result = await _pumpAndLaunch(tester, manager);

    await tester.tap(find.text('Style'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(manager.configOptionSets, contains(('style', 'b')));

    await tester.tap(find.widgetWithText(FilledButton, 'Open chat'));
    await tester.pumpAndSettle();
    expect(result(), key);
  });

  testWidgets('toggling a boolean option calls the config setter', (
    tester,
  ) async {
    final session = fakeAcpSession(
      key: key,
      configOptions: const [
        AcpBooleanConfigOption(
          id: 'verbose',
          name: 'Verbose',
          currentValue: false,
        ),
      ],
    );
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    await _pumpAndLaunch(tester, manager);

    await tester.tap(find.text('Verbose'));
    await tester.pumpAndSettle();

    expect(manager.configOptionSets, contains(('verbose', true)));
  });

  testWidgets('choosing a legacy model applies through the model setter', (
    tester,
  ) async {
    final session = fakeAcpSession(
      key: key,
      modelState: const AcpModelState(
        currentModelId: 'm1',
        availableModels: [
          AcpModelInfo(id: 'm1', name: 'Model One'),
          AcpModelInfo(id: 'm2', name: 'Model Two'),
        ],
      ),
    );
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    await _pumpAndLaunch(tester, manager);

    await tester.tap(find.widgetWithText(ListTile, 'Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model Two'));
    await tester.pumpAndSettle();

    expect(manager.modelSets, contains('m2'));
  });

  testWidgets('choosing a legacy mode applies through the mode setter', (
    tester,
  ) async {
    final session = fakeAcpSession(
      key: key,
      modeState: const AcpSessionModeState(
        currentModeId: 'code',
        availableModes: [
          AcpSessionMode(id: 'code', name: 'Code'),
          AcpSessionMode(id: 'ask', name: 'Ask'),
        ],
      ),
    );
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    await _pumpAndLaunch(tester, manager);

    await tester.tap(find.widgetWithText(ListTile, 'Mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    expect(manager.modeSets, contains('ask'));
  });

  testWidgets('with no adjustable settings, offers a Skip / Open chat path', (
    tester,
  ) async {
    final session = fakeAcpSession(key: key);
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    final result = await _pumpAndLaunch(tester, manager);

    expect(find.text('configure session'), findsOneWidget);
    expect(
      find.text('This agent exposes no adjustable settings.'),
      findsOneWidget,
    );
    final skip = find.widgetWithText(FilledButton, 'Skip · Open chat');
    expect(skip, findsOneWidget);

    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(result(), key);
  });

  testWidgets(
    'defaults to the host saved agent provider and working directory',
    (tester) async {
      final manager = FakeAcpSessionManager();
      final ssh = _MockSshService();
      final presetService = _MockAgentLaunchPresetService();
      final host = _host(
        tmuxWorkingDirectory: '/mux-default',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux.storageValue,
      );
      when(() => ssh.allSessions).thenReturn(const <SshSession>[]);
      when(
        () => ssh.getSessionsForHost(any()),
      ).thenReturn(const <SshSession>[]);
      when(() => presetService.getPresetForHost(host.id)).thenAnswer(
        (_) async => const AgentLaunchPreset(
          tool: AgentLaunchTool.openCode,
          workingDirectory: '/saved-agent-worktree',
          tmuxSessionName: 'agents',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            acpSessionManagerProvider.overrideWithValue(manager),
            activeSessionsProvider.overrideWith(_FakeActiveSessions.new),
            sshServiceProvider.overrideWithValue(ssh),
            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
            allHostsProvider.overrideWith((ref) => Stream.value(<Host>[host])),
            acpProvidersProvider.overrideWith(
              (ref) => Stream.value(<AcpProvider>[
                for (final builtin in acpBuiltinProviders)
                  AcpBuiltinProviderView(builtin),
              ]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showAcpNewSessionSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final openCodeChip = tester.widget<InputChip>(
        find.descendant(
          of: find.byKey(
            const ValueKey('provider-${AcpBuiltinProviderIds.openCode}'),
          ),
          matching: find.byType(InputChip),
        ),
      );
      expect(openCodeChip.selected, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/saved-agent-worktree',
      );
    },
  );

  testWidgets('selecting a recent session exposes a Resume session button', (
    tester,
  ) async {
    final now = DateTime(2026);
    final recent = AcpRecentSessionRef(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      bridgeId: 'bridge-1',
      acpSessionId: 'session-1',
      cwd: '/home/repo',
      createdAt: now,
      lastActivityAt: now,
    );
    final manager = FakeAcpSessionManager(recents: [recent]);
    await _pumpAndLaunch(
      tester,
      manager,
      initialHostId: 1,
      initialProviderId: AcpBuiltinProviderIds.copilotCli,
      startSession: false,
    );

    await tester.tap(find.text('Resume …/repo'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Resume session'), findsOneWidget);
  });

  testWidgets('surfaces the saved-host SSH failure before starting an agent', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager();
    await _pumpAndLaunch(
      tester,
      manager,
      startSession: false,
      connectionResult: const SshConnectionResult(
        success: false,
        error: 'Authentication failed. Check this host’s credentials.',
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Connection failed'), findsOneWidget);
    expect(
      find.text('Authentication failed. Check this host’s credentials.'),
      findsWidgets,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();

    expect(
      find.text('Authentication failed. Check this host’s credentials.'),
      findsOneWidget,
    );
  });
}
