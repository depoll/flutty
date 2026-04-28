import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  group('control mode command builders', () {
    test(
      'attach command starts tmux in control mode with safe client flags',
      () {
        expect(
          buildTmuxControlModeAttachCommand('dev\'s session'),
          'tmux -CC attach-session -f '
          'read-only,ignore-size,no-output,wait-exit '
          "-t 'dev'\"'\"'s session'",
        );
      },
    );

    test(
      'subscription command watches all windows in the attached session',
      () {
        const sep = tmuxWindowFieldSeparator;
        expect(
          buildTmuxWindowSubscriptionCommand('flutty-1-42'),
          'refresh-client -B '
          "'flutty-1-42:@*:"
          '#{window_index}$sep#{window_name}$sep#{window_active}$sep'
          '#{pane_current_command}$sep#{pane_current_path}$sep'
          '#{window_flags}$sep#{pane_title}$sep#{window_activity}$sep'
          '#{pane_start_command}$sep'
          "#{@flutty_agent_tool}'",
        );
      },
    );

    test('detectInstalledAgentTools caches empty results', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 20);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(stdout: _doneMarker());

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      final first = await service.detectInstalledAgentTools(session);
      final second = await service.detectInstalledAgentTools(session);

      expect(first, isEmpty);
      expect(second, isEmpty);
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
    });

    test('prefetchInstalledAgentTools warms the detection cache', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 21);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(
        stdout: '/opt/homebrew/bin/gemini\n${_doneMarker()}',
      );

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      await service.prefetchInstalledAgentTools(session);
      final tools = await service.detectInstalledAgentTools(session);

      expect(tools, {AgentLaunchTool.geminiCli});
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
    });

    test(
      'hasSessionOrThrow returns false for a missing tmux session',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 30);
        const service = TmuxService();
        final execSessions = Queue<SSHSession>.of([
          _buildOpenExecSession(
            stdout: 'bash\n/usr/bin/tmux\n${_doneMarker()}',
          ),
          _buildOpenExecSession(stdout: '0\n${_doneMarker()}'),
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        final exists = await service.hasSessionOrThrow(session, 'missing');

        expect(exists, isFalse);
        verify(
          () => client.execute(
            any(that: contains('tmux -u has-session')),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
    );

    test(
      'hasSessionOrThrow propagates indeterminate command failures',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 31);
        const service = TmuxService();
        final execSessions = Queue<SSHSession>.of([
          _buildOpenExecSession(
            stdout: 'bash\n/usr/bin/tmux\n${_doneMarker()}',
          ),
          _buildOpenExecSession(stdout: _doneMarker(2)),
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        await expectLater(
          service.hasSessionOrThrow(session, 'work'),
          throwsA(isA<TmuxCommandException>()),
        );
      },
    );

    test(
      'listWindows serves the last cached snapshot when channels are exhausted',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 32);
        const service = TmuxService();
        const sep = tmuxWindowFieldSeparator;
        var executeCalls = 0;
        final windowLine = [
          '0',
          'shell',
          '1',
          'bash',
          '/tmp/project',
          '*',
          'title',
          '100',
          'bash',
          '',
        ].join(sep);
        final execSession = _buildOpenExecSession(
          stdout: '$windowLine\n${_doneMarker()}',
        );

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          executeCalls += 1;
          if (executeCalls == 1) {
            return execSession;
          }
          return Future<SSHSession>.error(
            SSHChannelOpenError(2, 'open failed'),
          );
        });

        final initial = await service.listWindows(session, 'main');
        final cached = await service.listWindows(session, 'main');

        expect(initial, hasLength(1));
        expect(cached, initial);
        expect(cached.single.name, 'shell');
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      },
    );
  });

  group('parseTmuxWindowChangeEventFromControlLine', () {
    const subscriptionName = 'flutty-1-42';
    const sep = tmuxWindowFieldSeparator;

    test('returns a window snapshot event for matching subscriptions', () {
      final snapshotValue = [
        '1',
        'renamed',
        '1',
        'sleep',
        '/tmp',
        '*',
        'custom-title',
        '1712930000',
        'sleep 30',
        'gemini',
      ].join(sep);
      final event = parseTmuxWindowChangeEventFromControlLine(
        '${r'%subscription-changed flutty-1-42 $1 @1 1 %1 : '}$snapshotValue',
        subscriptionName: subscriptionName,
      );

      expect(event, isA<TmuxWindowSnapshotEvent>());
      final snapshot = event! as TmuxWindowSnapshotEvent;
      expect(snapshot.window.index, 1);
      expect(snapshot.window.name, 'renamed');
      expect(snapshot.window.isActive, isTrue);
      expect(snapshot.window.paneTitle, 'custom-title');
      expect(snapshot.window.paneStartCommand, 'sleep 30');
      expect(snapshot.window.agentTool, AgentLaunchTool.geminiCli);
    });

    test('normalizes the wrapped first control-mode line', () {
      final snapshotValue = [
        '0',
        'shell',
        '1',
        'sleep',
        '/tmp',
        '*',
        'wrapped-title',
        '1712930000',
        'sleep 30',
        '',
      ].join(sep);
      final event = parseTmuxWindowChangeEventFromControlLine(
        '\u001bP1000p'
        '${r'%subscription-changed flutty-1-42 $1 @1 1 %1 : '}'
        '$snapshotValue',
        subscriptionName: subscriptionName,
      );

      expect(event, isA<TmuxWindowSnapshotEvent>());
      final snapshot = event! as TmuxWindowSnapshotEvent;
      expect(snapshot.window.displayTitle, 'wrapped-title');
    });

    test('returns null for other subscriptions', () {
      expect(
        parseTmuxWindowChangeEventFromControlLine(
          r'%subscription-changed other-subscription $1 @1 1 %1 : updated',
          subscriptionName: subscriptionName,
        ),
        isNull,
      );
    });

    test(
      'returns reload events for lifecycle notifications without snapshots',
      () {
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%window-add @1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%window-close @1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%unlinked-window-add @1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%unlinked-window-close @1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%pane-mode-changed %1',
            subscriptionName: subscriptionName,
          ),
          isA<TmuxWindowReloadEvent>(),
        );
      },
    );

    test(
      'ignores noise and notifications that should rely on snapshots instead',
      () {
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%window-renamed @1 🔥 test-emoji',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            r'%session-window-changed $1 @1',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%begin 1 2 0',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '%output %1 hello',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
        expect(
          parseTmuxWindowChangeEventFromControlLine(
            '',
            subscriptionName: subscriptionName,
          ),
          isNull,
        );
      },
    );
  });

  group('diagnosticTmuxControlLineKind', () {
    test('returns only the control marker category', () {
      expect(
        diagnosticTmuxControlLineKind(
          r'%subscription-changed flutty-1-42 $1 @1 1 %1 : private details',
        ),
        'subscription_changed',
      );
      expect(
        diagnosticTmuxControlLineKind('%window-renamed @1 private-name'),
        'window_renamed',
      );
      expect(diagnosticTmuxControlLineKind(''), 'empty');
      expect(diagnosticTmuxControlLineKind('unrecognized payload'), 'other');
    });
  });

  group('shouldScheduleTmuxWindowReloadFallback', () {
    const subscriptionName = 'flutty-1-42';

    test(
      'schedules fallback reloads for window signals that may miss snapshots',
      () {
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            r'%subscription-changed flutty-1-42 $1 @1 1 %1 : malformed',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            r'%session-window-changed $1 @1',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            '%window-add @1',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            '%window-renamed @1 renamed-window',
            subscriptionName: subscriptionName,
          ),
          isTrue,
        );
      },
    );

    test('ignores unrelated control-mode noise', () {
      expect(
        shouldScheduleTmuxWindowReloadFallback(
          r'%subscription-changed other-subscription $1 @1 1 %1 : value',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
      expect(
        shouldScheduleTmuxWindowReloadFallback(
          '%output %1 hello',
          subscriptionName: subscriptionName,
        ),
        isFalse,
      );
    });

    test('preserves add and close reloads through later snapshots', () {
      expect(
        shouldPreserveTmuxWindowReloadThroughSnapshots('%window-add @1'),
        isTrue,
      );
      expect(
        shouldPreserveTmuxWindowReloadThroughSnapshots(
          '%unlinked-window-close @1',
        ),
        isTrue,
      );
      expect(
        shouldPreserveTmuxWindowReloadThroughSnapshots(
          r'%session-window-changed $1 @1',
        ),
        isFalse,
      );
    });
  });

  group('tmux window action helpers', () {
    test('parses the current pane path from display-message output', () {
      expect(parseTmuxCurrentPanePath('/tmp/project\n'), '/tmp/project');
      expect(
        parseTmuxCurrentPanePath('\n  /tmp/workspace  \n'),
        '/tmp/workspace',
      );
      final context = parseTmuxCurrentPaneContext('/tmp/project\x1fzsh\n');
      expect(context?.currentPath, '/tmp/project');
      expect(context?.currentCommand, 'zsh');
      expect(parseTmuxCurrentPanePath(' \n \n'), isNull);
    });

    test('detects only non-control tmux clients as foreground clients', () {
      expect(hasForegroundTmuxClient('1\n1\n'), isFalse);
      expect(hasForegroundTmuxClient('1\n0\n'), isTrue);
      expect(hasForegroundTmuxClient('\n0\n'), isTrue);
      expect(hasForegroundTmuxClient(' \n \n'), isFalse);
    });
  });

  group('tmux exec recovery', () {
    test('listWindows propagates exec channel open timeouts', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService(execOpenTimeout: Duration(milliseconds: 1));

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => Completer<SSHSession>().future);

      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
      'listWindows completes when stdout stays open after the done marker',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(
          stdout:
              '1|editor|1|vim|/tmp|*|vim-title|1712930000\n'
              '${_doneMarker()}',
        );

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSession);

        final windows = await service.listWindows(session, 'main');

        expect(windows, hasLength(1));
        expect(windows.single.index, 1);
        expect(windows.single.name, 'editor');
        verify(execSession.close).called(1);
      },
    );

    test('listWindows coalesces duplicate in-flight reloads', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final openCompleter = Completer<SSHSession>();
      final execSession = _buildOpenExecSession(
        stdout:
            '1|editor|1|vim|/tmp|*|vim-title|1712930000\n'
            '${_doneMarker()}',
      );

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => openCompleter.future);

      final first = service.listWindows(session, 'main');
      final second = service.listWindows(session, 'main');
      openCompleter.complete(execSession);

      final results = await Future.wait([first, second]);

      expect(results[0], hasLength(1));
      expect(results[1], orderedEquals(results[0]));
      expect(
        () => results[0].add(
          const TmuxWindow(index: 2, name: 'other', isActive: false),
        ),
        throwsUnsupportedError,
      );
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
      verify(execSession.close).called(1);
    });

    test('listWindows ignores done-marker text inside tmux fields', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(
        stdout:
            '1|$_execDoneMarker|1|vim|/tmp|*|title $_execDoneMarker:1|1712930000\n'
            '${_doneMarker()}',
      );

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      final windows = await service.listWindows(session, 'main');

      expect(windows, hasLength(1));
      expect(windows.single.name, _execDoneMarker);
      expect(windows.single.paneTitle, 'title $_execDoneMarker:1');
      verify(execSession.close).called(1);
    });

    test(
      'createWindow tags agent windows and targets the created index',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSessions = Queue<SSHSession>.from([
          _buildOpenExecSession(stdout: '4\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: _doneMarker()),
          _buildOpenExecSession(),
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        await service.createWindow(
          session,
          'main',
          command: 'gemini --yolo',
          name: 'gemini',
          workingDirectory: '/tmp/project',
        );

        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u new-window -P -F '#{window_index}' -t "
                "'main' -c '/tmp/project' -n 'gemini'",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u set-option -w -t 'main:4' "
                "@flutty_agent_tool 'gemini'",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u send-keys -t 'main:4' 'gemini --yolo' Enter",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
    );

    test(
      'selectWindow completes when stdout stays open after the done marker',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(stdout: _doneMarker());

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSession);

        await service.selectWindow(session, 'main', 2);

        verify(
          () => client.execute(
            any(
              that: contains(
                'tmux -u select-window -t '
                "'main':2",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(execSession.close).called(1);
      },
    );

    test(
      'killWindow waits for the done marker so failures can surface',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(stdout: _doneMarker());

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSession);

        await service.killWindow(session, 'main', 2);

        verify(
          () => client.execute(
            any(
              that: contains(
                'tmux -u kill-window -t '
                "'main':2",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(execSession.close).called(1);
      },
    );

    test('killWindow propagates missing marker failures', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildClosedExecSession(stdout: 'tmux failed\n');

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      await expectLater(
        service.killWindow(session, 'main', 2),
        throwsA(
          isA<TmuxCommandException>().having(
            (error) => error.message,
            'message',
            contains('closed before tmux command completed'),
          ),
        ),
      );
      verify(execSession.close).called(1);
    });

    test('killWindow propagates non-zero tmux command exit status', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(stdout: _doneMarker(1));

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      await expectLater(
        service.killWindow(session, 'main', 2),
        throwsA(
          isA<TmuxCommandException>().having(
            (error) => error.message,
            'message',
            contains('exit status 1'),
          ),
        ),
      );
      verify(execSession.close).called(1);
    });

    test('detectInstalledAgentTools propagates output timeouts', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService(execOutputTimeout: Duration(milliseconds: 1));
      final execSession = _buildOpenExecSession();

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      await expectLater(
        service.detectInstalledAgentTools(session),
        throwsA(isA<TimeoutException>()),
      );
      verify(execSession.close).called(1);
    });

    test(
      'detectInstalledAgentTools reports EOF before marker separately',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildClosedExecSession(stdout: 'partial output\n');

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSession);

        await expectLater(
          service.detectInstalledAgentTools(session),
          throwsA(isA<TmuxCommandException>()),
        );
        verify(execSession.close).called(1);
      },
    );

    test(
      'detectInstalledAgentTools parses output before an open stdout hangs',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(
          stdout: '/opt/homebrew/bin/claude\n${_doneMarker()}',
        );

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSession);

        final tools = await service.detectInstalledAgentTools(session);

        expect(tools, {AgentLaunchTool.claudeCode});
        verify(execSession.close).called(1);
      },
    );
  });

  group('decideTmuxHeartbeatAction', () {
    const heartbeat = Duration(seconds: 5);

    test('noop while control-mode notifications are flowing', () {
      expect(
        decideTmuxHeartbeatAction(
          silence: Duration.zero,
          heartbeatInterval: heartbeat,
        ),
        TmuxControlHeartbeatAction.noop,
      );
      expect(
        decideTmuxHeartbeatAction(
          silence: const Duration(milliseconds: 4999),
          heartbeatInterval: heartbeat,
        ),
        TmuxControlHeartbeatAction.noop,
      );
    });

    test('synthesizes a refresh once the channel has been silent for the '
        'heartbeat interval', () {
      expect(
        decideTmuxHeartbeatAction(
          silence: heartbeat,
          heartbeatInterval: heartbeat,
        ),
        TmuxControlHeartbeatAction.refresh,
      );
      expect(
        decideTmuxHeartbeatAction(
          silence: const Duration(seconds: 20),
          heartbeatInterval: heartbeat,
        ),
        TmuxControlHeartbeatAction.refresh,
      );
    });

    test(
      'continues refreshing instead of restarting after prolonged silence',
      () {
        expect(
          decideTmuxHeartbeatAction(
            silence: const Duration(minutes: 5),
            heartbeatInterval: heartbeat,
          ),
          TmuxControlHeartbeatAction.refresh,
        );
      },
    );
  });

  group('channel backoff helpers', () {
    test('identifies transient channel-open failures', () {
      expect(
        shouldBackOffTmuxExecChannelAfterFailure(
          SSHChannelOpenError(2, 'open failed'),
        ),
        isTrue,
      );
      expect(
        shouldUseCachedTmuxWindowsAfterListFailure(
          SSHChannelOpenError(2, 'open failed'),
        ),
        isTrue,
      );
      expect(
        shouldBackOffTmuxExecChannelAfterFailure(StateError('tmux missing')),
        isFalse,
      );
    });

    test('backs off control restarts more slowly after channel failures', () {
      expect(
        resolveTmuxControlRestartDelay(0, channelOpenFailure: false),
        const Duration(seconds: 1),
      );
      expect(
        resolveTmuxControlRestartDelay(0, channelOpenFailure: true),
        const Duration(seconds: 5),
      );
      expect(
        resolveTmuxControlRestartDelay(2, channelOpenFailure: true),
        const Duration(seconds: 20),
      );
      expect(
        resolveTmuxControlRestartDelay(4, channelOpenFailure: true),
        const Duration(seconds: 30),
      );
    });

    test('uses capped exec channel cooldowns', () {
      expect(resolveTmuxExecChannelBackoffDelay(1), const Duration(seconds: 2));
      expect(resolveTmuxExecChannelBackoffDelay(2), const Duration(seconds: 4));
      expect(
        resolveTmuxExecChannelBackoffDelay(6),
        const Duration(seconds: 30),
      );
    });
  });
}

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

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

const _execDoneMarker = '__flutty_tmux_exec_done__';

String _doneMarker([int status = 0]) => '$_execDoneMarker:$status\n';

Stream<Uint8List> _openUtf8Stream(String value) =>
    Stream<Uint8List>.multi((controller) {
      if (value.isNotEmpty) {
        scheduleMicrotask(
          () => controller.add(Uint8List.fromList(utf8.encode(value))),
        );
      }
    });

Stream<Uint8List> _closedUtf8Stream(String value) =>
    Stream<Uint8List>.fromIterable(
      value.isEmpty ? const [] : [Uint8List.fromList(utf8.encode(value))],
    );

void _ignoreInvocation(Invocation _) {}

SSHSession _buildOpenExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _openUtf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _openUtf8Stream(stderr));
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildClosedExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _closedUtf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _closedUtf8Stream(stderr));
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}
