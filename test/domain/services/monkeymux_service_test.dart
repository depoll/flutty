// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

void main() {
  group('RemoteMuxBackendPresentation', () {
    test('parses stable storage values', () {
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('auto'),
        RemoteMuxBackend.auto,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('monkey_mux'),
        RemoteMuxBackend.monkeyMux,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('tmux'),
        RemoteMuxBackend.tmux,
      );
      expect(RemoteMuxBackendPresentation.fromStorageValue(''), isNull);
    });

    test('keeps tmux extra flags on tmux startup', () {
      expect(
        resolveRemoteMuxBackendForStartup(
          storedBackend: 'auto',
          tmuxExtraFlags: '-f ~/.tmux.conf',
        ),
        RemoteMuxBackend.tmux,
      );
      expect(
        resolveRemoteMuxBackendForStartup(
          storedBackend: 'auto',
          tmuxExtraFlags: '',
        ),
        RemoteMuxBackend.auto,
      );
    });
  });

  group('buildMonkeyMuxAttachCommand', () {
    test('puts flags before the session and shell-quotes values', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkey mux',
        sessionName: "work'space",
        clientId: 'app 7',
        clipViewport: true,
        workingDirectory: "~/src/it's app",
        windowName: 'Codex agent',
        launchCommand: "codex --model 'gpt-5.4'",
        serverUpdatePolicy: MonkeyMuxServerUpdatePolicy.never,
        startInYoloMode: true,
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkey mux' attach --quiet "
        "--client-id 'app 7' --clip-viewport --update-policy never "
        "--restore-yolo --cwd '~/src/it'\"'\"'s app' --name 'Codex agent' --command "
        "'codex --model '\"'\"'gpt-5.4'\"'\"'' 'work'\"'\"'space'",
      );
    });

    test('passes terminal theme reports as base64 data', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkeymux',
        sessionName: 'work',
        terminalThemeReports: '\x1b]11;rgb:0000/1111/2222\x1b\\',
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkeymux' attach --quiet "
        '--theme-hint-base64 '
        'G10xMTtyZ2I6MDAwMC8xMTExLzIyMjIbXA== '
        "'work'",
      );
    });

    test('passes terminal capability reports as base64 data', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkeymux',
        sessionName: 'work',
        terminalCapabilityReports: 'da1\x1f\x1b[?62;22c',
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkeymux' attach --quiet "
        '--capability-hint-base64 '
        '${base64Encode(utf8.encode('da1\x1f\x1b[?62;22c'))} '
        "'work'",
      );
    });

    test('passes explicit viewport dimensions for raw SSH attach', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: r'C:\Users\me\monkeymux.exe',
        sessionName: 'work',
        terminalColumns: 69,
        terminalRows: 55,
        existingOnly: true,
        windows: true,
      );

      expect(command, contains('--width 69 --height 55'));
      expect(command, contains('--existing'));
      expect(command, endsWith(' work'));
    });

    test('escapes arguments for Windows argv parsing', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: r'C:\Program Files\mm\monkeymux.exe',
        sessionName: 'workspace',
        workingDirectory: r'C:\src\my app\',
        windowName: 'Codex agent',
        launchCommand: 'python -c "print(1)"',
        serverUpdatePolicy: MonkeyMuxServerUpdatePolicy.never,
        windows: true,
      );

      // Values with spaces are wrapped in double quotes; a trailing backslash
      // before the closing quote is doubled and embedded quotes are
      // backslash-escaped so CommandLineToArgvW recovers the exact argument.
      expect(
        command,
        r'"C:\Program Files\mm\monkeymux.exe" attach --quiet '
        '--update-policy never '
        r'--cwd "C:\src\my app\\" --name "Codex agent" '
        r'--command "python -c \"print(1)\"" workspace',
      );
    });

    test('leaves space-free Windows arguments unquoted', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: r'C:\mm\monkeymux.exe',
        sessionName: 'work',
        windows: true,
      );

      expect(command, r'C:\mm\monkeymux.exe attach --quiet work');
    });

    test('uses a unique app client id for each SSH session', () {
      SshSession createSession() => SshSession(
        connectionId: 42,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );

      final first = createSession();
      final second = createSession();

      expect(first.monkeyMuxClientId, startsWith('monkeyssh-42-'));
      expect(second.monkeyMuxClientId, isNot(first.monkeyMuxClientId));
    });
  });

  group('MonkeyMuxServerStatus', () {
    test('detects version mismatches and shutdown capability', () {
      const status = MonkeyMuxServerStatus(
        version: '0.1.13',
        capabilities: {'window-list', 'shutdown', 'client-viewport-clipping'},
      );

      expect(status.supportsShutdown, isTrue);
      expect(status.supportsViewportClipping, isTrue);
      expect(status.needsUpdate('0.1.13'), isFalse);
      expect(status.needsUpdate('0.1.14'), isTrue);
    });
  });

  group('MonkeyMuxImageReplayResult', () {
    test('retries only unserved ids after a transport failure', () {
      final result = MonkeyMuxImageReplayResult(
        served: const {7},
        retryableFailure: true,
      );

      expect(result.retryableUnserved(const {7, 8, 9}), {8, 9});
    });

    test('keeps explicitly non-retryable missing ids suppressed', () {
      final result = MonkeyMuxImageReplayResult(
        served: const {7},
        retryableFailure: false,
      );

      expect(result.retryableUnserved(const {7, 8, 9}), isEmpty);
    });

    test('acknowledged empty batch keeps requested ids retryable', () {
      final result = resolveMonkeyMuxImageReplayBatchForTesting(
        requested: const {7, 8},
        alreadyServed: const <int>{},
        acknowledged: true,
        responseImageIds: const <String>[],
      );

      expect(result.served, isEmpty);
      expect(result.retryableUnserved(const {7, 8}), {7, 8});
    });

    test('partial batch preserves served ids and retries the remainder', () {
      final result = resolveMonkeyMuxImageReplayBatchForTesting(
        requested: const {7, 8, 9},
        alreadyServed: const {7},
        acknowledged: true,
        responseImageIds: const ['8'],
      );

      expect(result.served, {7, 8});
      expect(result.retryableUnserved(const {7, 8, 9}), {9});
    });
  });

  group('MonkeyMux control responses', () {
    test('parse foreground attach state', () {
      final hasForegroundClient = parseMonkeyMuxHasForegroundClientForTesting(
        '{"type":"attach_state","status":"ok","hasForegroundClient":true}',
      );

      expect(hasForegroundClient, isTrue);
    });

    test('parses served image ids from replay acknowledgement', () {
      final response = parseMonkeyMuxImageReplayAckForTesting(
        '{"type":"images_replayed","status":"ok",'
        '"imagesAcknowledged":true,"imageIds":["17","23"]}',
      );

      expect(response?.acknowledged, isTrue);
      expect(response?.imageIds, ['17', '23']);
    });

    test('parses whether focus changed the primary client', () {
      expect(
        parseMonkeyMuxFocusChangedForTesting(
          '{"type":"client_focused","status":"ok","focusChanged":true}',
        ),
        isTrue,
      );
      expect(
        parseMonkeyMuxFocusChangedForTesting(
          '{"type":"client_focused","status":"ok"}',
        ),
        isFalse,
      );
    });

    test('allows one-shot run_command responses to reach server timeout', () {
      expect(
        monkeyMuxOneShotResponseTimeoutForTesting(const <String, Object?>{
          'type': 'run_command',
        }),
        const Duration(seconds: 25),
      );
      expect(
        monkeyMuxOneShotResponseTimeoutForTesting(const <String, Object?>{
          'type': 'list_windows',
        }),
        const Duration(seconds: 10),
      );
    });
  });

  group('parseMonkeyMuxWindowSnapshotForTesting', () {
    test('maps helper agentTool metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Gemini CLI',
        'active': true,
        'currentCommand': 'node',
        'panePid': 1234,
        'agentTool': 'gemini',
      });

      expect(window, isNotNull);
      expect(window!.foregroundAgentTool, AgentLaunchTool.geminiCli);
    });

    test('maps helper terminal progress metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Build',
        'active': false,
        'terminalProgress': {'state': 2, 'percentage': 63},
      });

      expect(window, isNotNull);
      expect(
        window!.terminalProgress,
        const TerminalProgress(
          state: TerminalProgressState.error,
          percentage: 63,
        ),
      );
    });

    test('ignores invalid helper terminal progress metadata', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Build',
        'active': false,
        'terminalProgress': {'state': 1, 'percentage': 101},
      });

      expect(window, isNotNull);
      expect(window!.terminalProgress, isNull);
    });

    test('maps helper terminal mouse mode metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Mouse app',
        'active': true,
        'terminalReportsMouseWheel': true,
        'terminalMouseReportSgr': true,
        'terminalBracketedPasteMode': true,
      });

      expect(window, isNotNull);
      expect(window!.terminalReportsMouseWheel, isTrue);
      expect(window.terminalMouseReportSgr, isTrue);
      expect(window.terminalBracketedPasteMode, isTrue);
    });

    test('maps helper private mode metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Mouse app',
        'active': true,
        'privateModes': {'1002': true, '1006': true, '2004': true},
      });

      expect(window, isNotNull);
      expect(window!.terminalReportsMouseWheel, isTrue);
      expect(window.terminalMouseReportSgr, isTrue);
      expect(window.terminalBracketedPasteMode, isTrue);
    });

    test(
      'leaves bracketed paste mode unknown when helper omits mode metadata',
      () {
        final window = parseMonkeyMuxWindowSnapshotForTesting({
          'id': '@1',
          'index': 0,
          'name': 'Shell',
          'active': true,
        });

        expect(window, isNotNull);
        expect(window!.terminalBracketedPasteMode, isNull);
      },
    );

    test('uses explicit helper bracketed paste mode when present', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Shell',
        'active': true,
        'terminalBracketedPasteMode': false,
        'privateModes': {'2004': true},
      });

      expect(window, isNotNull);
      expect(window!.terminalBracketedPasteMode, isFalse);
    });

    test('surfaces the alert flag so prompts trigger push notifications', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@2',
        'index': 1,
        'name': 'Claude Code',
        'active': false,
        'currentCommand': 'claude',
        'panePid': 4321,
        'flags': '#',
      });

      expect(window, isNotNull);
      expect(window!.flags, '#');
      expect(window.hasAlert, isTrue);
    });

    test('leaves windows without an alert flag un-alerted', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@3',
        'index': 2,
        'name': 'shell',
        'active': false,
        'currentCommand': 'zsh',
      });

      expect(window, isNotNull);
      expect(window!.hasAlert, isFalse);
    });
  });

  group('MonkeyMux agent metadata', () {
    test('refreshes metadata for every supported agent pane', () {
      const windows = [
        TmuxWindow(
          index: 0,
          name: 'Codex',
          isActive: true,
          currentCommand: 'codex',
          panePid: 42,
        ),
        TmuxWindow(
          index: 1,
          name: 'shell',
          isActive: false,
          currentCommand: 'zsh',
          panePid: 43,
        ),
      ];

      expect(shouldRefreshMonkeyMuxAgentMetadataForTesting(windows), isTrue);
      expect(
        shouldRefreshMonkeyMuxAgentMetadataForTesting(const [
          TmuxWindow(
            index: 1,
            name: 'shell',
            isActive: false,
            currentCommand: 'zsh',
            panePid: 43,
          ),
        ]),
        isFalse,
      );
    });

    test('applies all-agent metadata with confidence to matching panes', () {
      const sep = tmuxWindowFieldSeparator;
      const windows = [
        TmuxWindow(
          index: 0,
          name: 'Codex',
          isActive: true,
          currentCommand: 'codex',
          panePid: 42,
        ),
        TmuxWindow(
          index: 1,
          name: 'Gemini',
          isActive: false,
          currentCommand: 'gemini',
          panePid: 43,
        ),
      ];

      final enriched = applyMonkeyMuxAgentMetadataForTesting(
        windows,
        'codex${sep}codex-session${sep}501${sep}42${sep}medium$sep\n'
        'gemini${sep}gemini-session${sep}502${sep}43${sep}medium${sep}Gemini title\n',
      );

      expect(enriched[0].activeAgentSessionId, 'codex-session');
      expect(
        enriched[0].activeAgentSessionConfidence,
        AgentSessionConfidence.medium,
      );
      expect(enriched[1].activeAgentSessionId, 'gemini-session');
      expect(enriched[1].agentSessionTitle, 'Gemini title');
      expect(
        enriched[1].activeAgentSessionConfidence,
        AgentSessionConfidence.medium,
      );
    });

    test('applies live Copilot session titles by pane pid', () {
      const window = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Copilot CLI',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Copilot CLI',
      );

      final windows = applyMonkeyMuxAgentSessionMetadataForTesting(
        const [window],
        const {
          42: (sessionId: 'session-1', title: 'Implement MonkeyMux refresh'),
        },
        refreshedPanePids: const {42},
      );

      expect(windows.single.activeAgentSessionId, 'session-1');
      expect(windows.single.agentSessionTitle, 'Implement MonkeyMux refresh');
      expect(windows.single.displayTitle, 'Implement MonkeyMux refresh');
    });

    test('keeps Copilot session titles after a transient refreshed miss', () {
      const window = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Copilot CLI',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Copilot CLI',
        activeAgentSessionId: 'stale-session',
        agentSessionTitle: 'Stale Copilot session',
      );

      final windows = applyMonkeyMuxAgentSessionMetadataForTesting(
        const [window],
        const {},
        refreshedPanePids: const {42},
      );

      expect(windows.single.activeAgentSessionId, 'stale-session');
      expect(windows.single.agentSessionTitle, 'Stale Copilot session');
      expect(windows.single.displayTitle, 'Stale Copilot session');
    });

    test('keeps existing Copilot metadata when pane was not refreshed', () {
      const window = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Copilot CLI',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Copilot CLI',
        activeAgentSessionId: 'session-1',
        agentSessionTitle: 'Current Copilot session',
      );

      final windows = applyMonkeyMuxAgentSessionMetadataForTesting(const [
        window,
      ], const {});

      expect(windows.single.activeAgentSessionId, 'session-1');
      expect(windows.single.agentSessionTitle, 'Current Copilot session');
    });
  });

  group('MonkeyMux control channel timeout', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    test(
      'listWindows fails instead of hanging when no response arrives',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 900);
        // A control channel that opens successfully but never emits a response
        // line reproduces the stuck window switcher: without a timeout the
        // request completer would never resolve.
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildSilentControlSession(stdoutController);

        when(
          () => installer.ensureInstalled(session),
        ).thenAnswer((_) async => _fakeInstallation);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => controlSession);

        final service = MonkeyMuxService(
          installer: installer,
          agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
          controlResponseTimeout: const Duration(milliseconds: 80),
        );

        // Registering the observer routes listWindows through the persistent
        // control channel, which is the path that previously lacked a timeout.
        final stuckReload = (service..watchWindowChanges(session, 'work'))
            .listWindows(session, 'work');

        await expectLater(stuckReload, throwsA(isA<TimeoutException>()));

        // A subsequent reload succeeds once the control channel responds, proving
        // the timeout unblocks the window switcher instead of wedging it.
        final reconnectController = StreamController<Uint8List>();
        final reconnectSession = _buildRespondingControlSession(
          reconnectController,
          window: _fakeWindowJson,
        );
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => reconnectSession);

        final windows = await service.listWindows(session, 'work');
        expect(windows, hasLength(1));
        expect(windows.single.name, 'Codex');

        await reconnectController.close();
        await stdoutController.close();
        await service.clearCache(900);
      },
    );

    test(
      'refreshWindows starts a new query after an older request fails',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 901);
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildSilentControlSession(stdoutController);
        final requests = <Map<String, Object?>>[];

        when(
          () => installer.ensureInstalled(session),
        ).thenAnswer((_) async => _fakeInstallation);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => controlSession);
        when(() => controlSession.write(any())).thenAnswer((invocation) {
          final data = invocation.positionalArguments.single as List<int>;
          requests.add(jsonDecode(utf8.decode(data)) as Map<String, Object?>);
        });

        final service = MonkeyMuxService(
          installer: installer,
          agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
        )..watchWindowChanges(session, 'work');
        final firstRequest = service.listWindows(session, 'work');
        final freshRequest = service.refreshWindows(session, 'work');
        await pumpEventQueue();

        expect(requests, hasLength(1));
        _respondToControlError(stdoutController, requests.single);
        await expectLater(
          firstRequest,
          throwsA(isA<MonkeyMuxInstallException>()),
        );
        await pumpEventQueue();

        expect(requests, hasLength(2));
        _respondToWindowListRequest(
          stdoutController,
          requests.last,
          terminalBracketedPasteMode: true,
        );
        final windows = await freshRequest;

        expect(windows.single.terminalBracketedPasteMode, isTrue);

        await stdoutController.close();
        await service.clearCache(901);
      },
    );
    test(
      'listWindows fails instead of hanging when the watcher is disposed',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 902);
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildSilentControlSession(stdoutController);

        when(
          () => installer.ensureInstalled(session),
        ).thenAnswer((_) async => _fakeInstallation);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => controlSession);

        final service = MonkeyMuxService(
          installer: installer,
          agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
        );
        final subscription = service
            .watchWindowChanges(session, 'work')
            .listen((_) {});
        final stuckReload = service.listWindows(session, 'work');
        final reloadFailed = expectLater(
          stuckReload,
          throwsA(isA<MonkeyMuxInstallException>()),
        );
        await pumpEventQueue();

        // Tearing down the last window-change listener disposes the shared
        // control channel. The in-flight reload used to stay pending forever,
        // and because it is cached as the shared window-list request every
        // later reload reused it, leaving the switcher on a perpetual spinner.
        await subscription.cancel();
        await reloadFailed;

        final reconnectController = StreamController<Uint8List>();
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async => _buildRespondingControlSession(
            reconnectController,
            window: _fakeWindowJson,
          ),
        );
        final resubscribed = service
            .watchWindowChanges(session, 'work')
            .listen((_) {});

        final windows = await service.listWindows(session, 'work');
        expect(windows, hasLength(1));
        expect(windows.single.name, 'Codex');

        await resubscribed.cancel();
        await reconnectController.close();
        await stdoutController.close();
        await service.clearCache(902);
      },
    );

    test('listWindows recovers after the control channel never opens', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 903);
      final neverOpens = Completer<SSHSession>();

      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      // A channel open that never resolves used to block runCommand before the
      // request deadline was armed, so no timeout could ever fire.
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => neverOpens.future);

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
        controlResponseTimeout: const Duration(milliseconds: 80),
      )..watchWindowChanges(session, 'work');

      await expectLater(
        service.listWindows(session, 'work'),
        throwsA(isA<TimeoutException>()),
      );

      // The wedged start attempt must not be reused: every later reload would
      // await the same dead future and time out without opening a channel.
      final reconnectController = StreamController<Uint8List>();
      final reconnectSession = _buildRespondingControlSession(
        reconnectController,
        window: _fakeWindowJson,
      );
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => reconnectSession);

      final windows = await service.listWindows(session, 'work');
      expect(windows, hasLength(1));
      expect(windows.single.name, 'Codex');

      // A channel that opens after its attempt was abandoned is closed rather
      // than installed over the live one.
      final abandoned = _buildSilentControlSession(
        StreamController<Uint8List>(),
      );
      neverOpens.complete(abandoned);
      await pumpEventQueue();
      verify(abandoned.close).called(1);

      await reconnectController.close();
      await service.clearCache(903);
    });

    test('gives every queued control command a distinct id', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 904);
      final stdoutController = StreamController<Uint8List>();
      final controlSession = _buildSilentControlSession(stdoutController);
      final requests = <Map<String, Object?>>[];

      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => controlSession);
      when(() => controlSession.write(any())).thenAnswer((invocation) {
        final data = invocation.positionalArguments.single as List<int>;
        requests.add(jsonDecode(utf8.decode(data)) as Map<String, Object?>);
      });

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
      )..watchWindowChanges(session, 'work');
      // Commands created in the same tick used to share a microsecond
      // timestamp id, so the second overwrote the first in the pending map and
      // the first caller never received a response.
      final windowList = service.listWindows(session, 'work');
      final panePath = service.currentPanePath(session, 'work');
      await pumpEventQueue();

      expect(requests, hasLength(2));
      expect(requests.first['id'], isNot(requests.last['id']));

      for (final request in requests) {
        _respondToWindowListRequest(
          stdoutController,
          request,
          terminalBracketedPasteMode: false,
        );
      }
      await windowList;
      await panePath;

      await stdoutController.close();
      await service.clearCache(904);
    });
  });

  group('MonkeyMuxService.detectedVersion', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    test('reads the running server version from the control hello', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 909);
      final commands = <String>[];
      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOutputSession(
          '{"type":"hello","status":"ok","version":"0.2.4",'
          '"capabilities":[]}\n',
        );
      });

      final version = await MonkeyMuxService(
        installer: installer,
      ).detectedVersion(session, 'work');

      expect(version, '0.2.4');
      expect(
        commands.single,
        "'/home/tester/.monkeyssh/bin/monkeymux' control --json 'work'",
      );
    });
  });

  group('MonkeyMuxService.installedHelperVersion', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    // `attach` restarts a running server only when its version differs from the
    // version compiled into the helper binary, so the binary — not the bundled
    // manifest label — decides whether an update would actually apply.
    test('reads the version the installed binary reports', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 910);
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOutputSession('0.1.89\n');
      });

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, '0.1.89');
      expect(
        commands.single,
        "'/home/tester/.monkeyssh/bin/monkeymux' version",
      );
    });

    test('quotes the helper path for Windows remotes', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 911);
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOutputSession('0.1.90\r\n');
      });

      final version = await MonkeyMuxService(installer: installer)
          .installedHelperVersion(
            session,
            const MonkeyMuxInstallation(
              executablePath: r'C:\Program Files\mm\monkeymux.exe',
              platform: 'windows-amd64',
              version: '0.1.90',
            ),
          );

      expect(version, '0.1.90');
      expect(commands.single, r'"C:\Program Files\mm\monkeymux.exe" version');
    });

    test('returns null when the probe produces no output', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 912);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => _buildOutputSession(''));

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, isNull);
    });

    test('skips login shell banner text before the version line', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 914);
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (_) async => _buildOutputSession(
          'Welcome to Ubuntu 24.04 LTS\n\nLast login: Mon Jul 20\n0.1.89\n',
        ),
      );

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, '0.1.89');
    });

    test('returns null when no line looks like a version', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 915);
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (_) async => _buildOutputSession('monkeymux: command not found\n'),
      );

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, isNull);
    });

    test('accepts a pre-release version suffix', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 916);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => _buildOutputSession('0.1.90-dev.3\n'));

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, '0.1.90-dev.3');
    });

    test('returns null when the probe fails', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 913);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenThrow(SSHStateError('channel closed'));

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, isNull);
    });
  });
}

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockByteSink extends Mock implements StreamSink<Uint8List> {}

class _MockMonkeyMuxInstaller extends Mock
    implements MonkeyMuxInstallerService {}

const _fakeInstallation = MonkeyMuxInstallation(
  executablePath: '/home/tester/.monkeyssh/bin/monkeymux',
  platform: 'linux-amd64',
  version: '0.1.89',
);

const _fakeWindowJson = <String, Object?>{
  'id': '@1',
  'index': 0,
  'name': 'Codex',
  'active': true,
  'currentCommand': 'codex',
};

SshSession _buildSession(SSHClient client, {int connectionId = 1}) =>
    SshSession(
      connectionId: connectionId,
      hostId: 1,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'tester',
      ),
    );

/// Builds an exec session that emits [output] on stdout and then closes.
SSHSession _buildOutputSession(String output) {
  final session = _MockExecSession();
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) async {});
  when(() => session.stdout).thenAnswer(
    (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
  );
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => session.done).thenAnswer((_) async {});
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer((_) {});
  return session;
}

SSHSession _buildSilentControlSession(
  StreamController<Uint8List> stdoutController,
) {
  final session = _MockExecSession();
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) async {});
  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => session.done).thenAnswer((_) => Completer<void>().future);
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer((_) {});
  when(() => session.write(any())).thenAnswer((_) {});
  return session;
}

SSHSession _buildRespondingControlSession(
  StreamController<Uint8List> stdoutController, {
  required Map<String, Object?> window,
}) {
  final session = _MockExecSession();
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) async {});
  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => session.done).thenAnswer((_) => Completer<void>().future);
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer((_) {});
  when(() => session.write(any())).thenAnswer((invocation) {
    final data = invocation.positionalArguments.single as List<int>;
    final request = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
    final response = jsonEncode({
      'id': request['id'],
      'type': 'window_list',
      'status': 'ok',
      'windows': [window],
    });
    scheduleMicrotask(
      () =>
          stdoutController.add(Uint8List.fromList(utf8.encode('$response\n'))),
    );
  });
  return session;
}

void _respondToWindowListRequest(
  StreamController<Uint8List> stdoutController,
  Map<String, Object?> request, {
  required bool terminalBracketedPasteMode,
}) {
  final response = jsonEncode({
    'id': request['id'],
    'type': 'window_list',
    'status': 'ok',
    'windows': [
      {
        ..._fakeWindowJson,
        'terminalBracketedPasteMode': terminalBracketedPasteMode,
      },
    ],
  });
  stdoutController.add(Uint8List.fromList(utf8.encode('$response\n')));
}

void _respondToControlError(
  StreamController<Uint8List> stdoutController,
  Map<String, Object?> request,
) {
  final response = jsonEncode({
    'id': request['id'],
    'type': 'error',
    'status': 'error',
    'error': 'stale request failed',
  });
  stdoutController.add(Uint8List.fromList(utf8.encode('$response\n')));
}
