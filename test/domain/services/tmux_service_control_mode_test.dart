import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  group('control mode command builders', () {
    test('attach command starts tmux in control mode without wait-exit', () {
      expect(
        buildTmuxControlModeAttachCommand('dev\'s session'),
        'tmux -CC attach-session -f '
        'ignore-size,no-output '
        "-t 'dev'\"'\"'s session'",
      );
    });

    test(
      'attach command includes reusable tmux client flags when provided',
      () {
        expect(
          buildTmuxControlModeAttachCommand(
            'main',
            extraFlags: '-x 160 -S /tmp/tmux-socket -n editor',
          ),
          "tmux -S '/tmp/tmux-socket' -CC attach-session -f "
          'ignore-size,no-output '
          "-t 'main'",
        );
      },
    );

    test('extracts only reusable client flags from tmux extra flags', () {
      expect(
        resolveTmuxClientFlagsFromExtraFlags(
          r'-x 160 -S "/tmp/tmux socket" -y 48 \; set status off',
        ),
        "-S '/tmp/tmux socket'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags('-L alerts -f ~/.tmux.conf'),
        r"""-L 'alerts' -f "$HOME"'/.tmux.conf'""",
      );
      expect(resolveTmuxClientFlagsFromExtraFlags('-x 200 -n editor'), isNull);
    });

    test('shell-quotes reusable client flag values', () {
      expect(
        resolveTmuxClientFlagsFromExtraFlags(r'-S "$(touch /tmp/pwn)"'),
        r"-S '$(touch /tmp/pwn)'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags('-L `id` -f /tmp/>out'),
        "-L '`id`' -f '/tmp/>out'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags(
          '-S/tmp/sock;id -Lname&&id -f/tmp/sock|id',
        ),
        "-S '/tmp/sock;id' -L 'name&&id' -f '/tmp/sock|id'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags('-S /tmp/socket ; set status off'),
        "-S '/tmp/socket'",
      );
    });

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
          '#{@flutty_agent_tool}$sep'
          '#{window_id}$sep'
          "#{pane_pid}'",
        );
      },
    );

    test('refresh command redraws non-control clients for a session', () {
      expect(
        buildTmuxRefreshForegroundClientsCommand("dev's session"),
        r'SEP=$(printf "\037"); '
        'tmux -u list-clients -t '
        "'dev'\"'\"'s session' -F "
        r'"#{client_control_mode}${SEP}#{client_name}" '
        '2>/dev/null | '
        r'while IFS="$SEP" read -r control client; do '
        r'[ "$control" = 0 ] || continue; '
        r'[ -n "$client" ] || continue; '
        r'tmux -u refresh-client -t "$client" 2>/dev/null || true; '
        'done',
      );
    });

    test('refresh command reuses tmux client flags', () {
      expect(
        buildTmuxRefreshForegroundClientsCommand(
          'main',
          extraFlags: '-S /tmp/tmux-socket -x 160 -L alerts',
        ),
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'refresh-client -t "$client"',
        ),
      );
    });

    test('theme refresh command updates pane palette before redraw', () {
      final command = buildTmuxRefreshTerminalThemeCommand(
        "dev's session",
        TerminalThemes.dracula,
      );

      expect(
        command,
        contains("tmux -u list-panes -s -t 'dev'\"'\"'s session'"),
      );
      expect(command, contains(r'set-option -p -t "$pane"'));
      expect(
        RegExp(r'tmux -u set-option -p -t "\$pane"').allMatches(command),
        hasLength(1),
      );
      expect(command, contains(r'\; set-option -p -t "$pane"'));
      expect(command, contains("'pane-colours[5]' '#ff79c6'"));
      expect(command, contains("'pane-colours[6]' '#8be9fd'"));
      expect(
        command,
        contains(
          r'#{pane_active}${SEP}#{alternate_on}${SEP}#{pane_current_command}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_start_command}${SEP}#{@flutty_agent_tool}',
        ),
      );
      expect(
        command,
        contains(
          r'{ while IFS="$SEP" read -r pane active alternate pane_command window_name pane_title pane_start_command agent_metadata',
        ),
      );
      expect(command, isNot(contains(r'if [ "$active" = 1 ]')));
      expect(command, isNot(contains('window_active')));
      expect(command, isNot(contains(r'[ "$alternate" = 1 ]')));
      expect(command, isNot(contains(r'[ "$theme_refresh_tui" = 1 ]')));
      expect(command, isNot(contains('theme_refresh_tui=0')));
      expect(command, contains('flutty_set_agent_tool_from_command_name'));
      expect(command, contains('flutty_set_agent_tool_from_exact_name'));
      expect(command, contains('flutty_set_agent_tool_from_command_text'));
      expect(
        command,
        contains(r'flutty_set_agent_tool_from_exact_name "$agent_metadata"'),
      );
      expect(
        command,
        contains(r'flutty_set_agent_tool_from_command_name "$pane_command"'),
      );
      expect(
        command,
        contains(r'flutty_set_agent_tool_from_exact_name "$window_name"'),
      );
      expect(
        command,
        contains(r'flutty_set_agent_tool_from_exact_name "$pane_title"'),
      );
      expect(
        command,
        contains(
          r'flutty_set_agent_tool_from_command_text "$pane_start_command"',
        ),
      );
      expect(command, contains('claude|claude-*'));
      expect(command, contains('copilot|copilot-*'));
      expect(command, contains('codex|codex-*'));
      expect(command, contains('opencode|opencode-*'));
      expect(command, contains('gemini|gemini-*'));
      expect(command, isNot(contains(r'case "$pane_title" in')));
      expect(command, isNot(contains('*Copilot*|*copilot*')));
      expect(command, isNot(contains('*Codex*|*codex*')));
      expect(command, isNot(contains('*OpenCode*|*opencode*')));
      expect(command, isNot(contains('foreground_tui=1')));
      expect(command, isNot(contains(r'[ "$active" = 1 ]')));
      expect(command, contains('flutty_theme_refresh_pane'));
      expect(command, contains(') & ;;'));
      expect(command, contains('done; wait; };'));
      expect(command, contains(r'case "$agent_tool" in'));
      expect(command, contains('codex)'));
      expect(command, contains('opencode|claude|gemini)'));
      final directBranchStart = command.indexOf(r'case "$agent_tool" in');
      expect(directBranchStart, isNonNegative);
      final directBranch = command.substring(directBranchStart);
      expect(directBranch, isNot(contains('copilot)')));
      expect(command, contains(r'send-keys -t "$pane" -H'));
      expect(command, contains(r'refresh-client -t "$client" -r "$pane":'));
      expect(command, contains(r'#{client_control_mode}${SEP}#{client_name}'));
      expect(command, contains(r'while IFS="$SEP" read -r control client'));
      expect(command, contains(r'[ "$control" = 0 ] || continue;'));
      expect(
        command,
        contains(
          buildTerminalThemeModeReport(isDark: TerminalThemes.dracula.isDark),
        ),
      );
      expect(
        command,
        contains(
          buildTerminalThemeOscResponse(
            theme: TerminalThemes.dracula,
            code: '10',
            args: const ['?'],
          ),
        ),
      );
      expect(
        command,
        contains(
          buildTerminalThemeOscResponse(
            theme: TerminalThemes.dracula,
            code: '11',
            args: const ['?'],
          ),
        ),
      );
      expect(command, contains('1b 5b 4f'));
      expect(command, contains('1b 5b 49'));
      final codexBranchStart = directBranch.indexOf('codex)');
      final opencodeBranchStart = directBranch.indexOf(
        'opencode|claude|gemini)',
      );
      expect(codexBranchStart, isNonNegative);
      expect(opencodeBranchStart, greaterThan(codexBranchStart));
      expect(
        directBranch.substring(codexBranchStart, opencodeBranchStart),
        isNot(contains('1b 5b 4f')),
      );
      expect(
        directBranch.indexOf('1b 5b 4f', opencodeBranchStart),
        greaterThan(opencodeBranchStart),
      );
      expect(command, isNot(contains('sleep 0.25')));
      final tmuxCacheReports = [
        buildTerminalThemeModeReport(isDark: TerminalThemes.dracula.isDark),
        ...buildTerminalThemeRefreshReportList(TerminalThemes.dracula),
      ];
      expect(
        RegExp(
          r'refresh-client -t "\$client" -r "\$pane":',
        ).allMatches(command),
        hasLength(tmuxCacheReports.length),
      );
      for (final report in tmuxCacheReports) {
        expect(command, contains(report));
      }
      expect(
        command,
        isNot(contains(r'send-keys -t "$pane" -H 1b 5b 3f 39 39 37')),
      );
      expect(command, isNot(contains(r'send-keys -t "$pane" -H 1b 5d 31 30')));
      expect(command, isNot(contains(r'send-keys -t "$pane" -H 1b 5d 31 31')));
      expect(command, isNot(contains(r'send-keys -t "$pane" -H 1b 5d 34')));
      expect(RegExp('1b 5d 31 30 3b').allMatches(command), isEmpty);
      expect(RegExp('1b 5d 31 31 3b').allMatches(command), isEmpty);
      expect(
        command,
        contains("tmux -u list-clients -t 'dev'\"'\"'s session'"),
      );
    });

    test('theme refresh command reuses tmux client flags', () {
      final command = buildTmuxRefreshTerminalThemeCommand(
        'main',
        TerminalThemes.githubLightDefault,
        extraFlags: '-S /tmp/tmux-socket -x 160 -L alerts',
      );

      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          'list-panes',
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r"""set-option -p -t "$pane" 'pane-colours[0]'""",
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'refresh-client -t "$client" -r "$pane":',
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'send-keys -t "$pane" -H',
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'refresh-client -t "$client"',
        ),
      );
    });

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

    test('isTmuxActiveOrThrow ignores unrelated tmux clients', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 22);
      const service = TmuxService();
      final execSessions = Queue<SSHSession>.of([
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        _buildOpenExecSession(stdout: _doneMarker()),
      ]);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSessions.removeFirst());

      final active = await service.isTmuxActiveOrThrow(session);

      expect(active, isFalse);
      final foregroundCommand =
          verify(
                () => client.execute(
                  captureAny(that: contains('list-clients')),
                  pty: any(named: 'pty'),
                ),
              ).captured.single
              as String;
      expect(foregroundCommand, contains('#{client_pid}'));
      expect(foregroundCommand, contains('#{client_control_mode}'));
      expect(foregroundCommand, contains('connection_pid='));
      expect(foregroundCommand, isNot(contains('exit 0')));
      expect(foregroundCommand, contains('break 2'));
      expect(foregroundCommand, isNot(contains('#{client_tty}')));
      verifyNever(
        () => client.execute(
          any(that: contains('list-sessions')),
          pty: any(named: 'pty'),
        ),
      );
    });

    test('currentSessionName returns the foreground tmux client', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 23);
      const service = TmuxService();
      final execSessions = Queue<SSHSession>.of([
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        _buildOpenExecSession(stdout: 'work\n${_doneMarker()}'),
      ]);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSessions.removeFirst());

      final sessionName = await service.currentSessionName(session);

      expect(sessionName, 'work');
      verify(
        () => client.execute(
          any(that: contains('list-clients')),
          pty: any(named: 'pty'),
        ),
      ).called(1);
      verifyNever(
        () => client.execute(
          any(that: contains('display-message')),
          pty: any(named: 'pty'),
        ),
      );
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

    test('hasSessionOrThrow dedupes concurrent session probes', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 33);
      const service = TmuxService();
      final execSessions = Queue<SSHSession>.of([
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        _buildOpenExecSession(stdout: '1\n${_doneMarker()}'),
      ]);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSessions.removeFirst());

      final results = await Future.wait([
        service.hasSessionOrThrow(session, 'work'),
        service.hasSessionOrThrow(session, 'work'),
      ]);

      expect(results, [isTrue, isTrue]);
      verify(
        () => client.execute(
          any(that: contains('command -v tmux')),
          pty: any(named: 'pty'),
        ),
      ).called(1);
      verify(
        () => client.execute(
          any(that: contains('tmux -u has-session')),
          pty: any(named: 'pty'),
        ),
      ).called(1);
    });

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
          '@4',
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
        expect(cached.single.id, '@4');
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      },
    );

    test('listWindows debounces Copilot metadata refresh bursts', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 34);
      const service = TmuxService(
        agentSessionMetadataRefreshDebounce: Duration(milliseconds: 30),
      );
      final commands = <String>[];
      final windowLines = Queue<String>.of([
        _tmuxWindowLine(id: '@42', panePid: 42, title: 'First'),
        _tmuxWindowLine(id: '@88', panePid: 88, title: 'Second'),
      ]);

      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        if (command.contains('list-windows')) {
          return _buildOpenExecSession(
            stdout: '${windowLines.removeFirst()}\n${_doneMarker()}',
          );
        }
        return _buildOpenExecSession(stdout: _doneMarker());
      });

      try {
        await service.listWindows(session, 'main');
        await service.listWindows(session, 'main');

        expect(
          commands.where(_isCopilotMetadataCommand),
          isEmpty,
          reason: 'metadata refresh should wait for the debounce window',
        );

        await Future<void>.delayed(const Duration(milliseconds: 80));

        final metadataCommands = commands
            .where(_isCopilotMetadataCommand)
            .toList(growable: false);
        expect(metadataCommands, hasLength(1));
        expect(metadataCommands.single, contains("pane_pids='42 88'"));
      } finally {
        await service.clearCache(session.connectionId);
      }
    });

    test('Copilot metadata refreshes wait for exec channel backoff', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 35);
      const service = TmuxService(
        agentSessionMetadataRefreshDebounce: Duration(milliseconds: 10),
      );
      var metadataAttempts = 0;

      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('list-windows')) {
          return _buildOpenExecSession(
            stdout:
                '${_tmuxWindowLine(id: '@42', panePid: 42)}\n${_doneMarker()}',
          );
        }
        if (_isCopilotMetadataCommand(command)) {
          metadataAttempts += 1;
          if (metadataAttempts == 1) {
            return Future<SSHSession>.error(
              SSHChannelOpenError(2, 'open failed'),
            );
          }
          return _buildOpenExecSession(stdout: _doneMarker());
        }
        return _buildOpenExecSession(stdout: _doneMarker());
      });

      try {
        await service.listWindows(session, 'main');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(metadataAttempts, 1);
        expect(
          TmuxService.hasExecChannelBackoffEntry(session.connectionId),
          true,
        );

        await service.listWindows(session, 'main');
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(
          metadataAttempts,
          1,
          reason: 'metadata refreshes should not hammer SSH during backoff',
        );

        await Future<void>.delayed(const Duration(milliseconds: 1800));

        expect(metadataAttempts, 2);
        expect(
          TmuxService.hasExecChannelBackoffEntry(session.connectionId),
          false,
        );
      } finally {
        await service.clearCache(session.connectionId);
      }
    });
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
        '@12',
        '4321',
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
      expect(snapshot.window.id, '@12');
      expect(snapshot.window.panePid, 4321);
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
        '@3',
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
      expect(snapshot.window.id, '@3');
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

    test(
      'hasForegroundClient requires the primary terminal session to match',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 24);
        const service = TmuxService();
        final execSessions = Queue<SSHSession>.of([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: 'other\n${_doneMarker()}'),
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        final hasForegroundClient = await service.hasForegroundClient(
          session,
          'work',
        );

        expect(hasForegroundClient, isFalse);
        final foregroundCommand =
            verify(
                  () => client.execute(
                    captureAny(that: contains('list-clients')),
                    pty: any(named: 'pty'),
                  ),
                ).captured.single
                as String;
        expect(foregroundCommand, contains('#{client_pid}'));
        expect(foregroundCommand, contains('#{client_control_mode}'));
      },
    );
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

    test('listWindows uses only reusable client flags when provided', () async {
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

      await service.listWindows(
        session,
        'main',
        extraFlags: r'-S /tmp/socket -x 160 \; set status off',
      );

      final command =
          verify(
                () => client.execute(captureAny(), pty: any(named: 'pty')),
              ).captured.single
              as String;
      expect(
        command,
        contains("tmux -u -S '/tmp/socket' list-windows -t 'main' -F "),
      );
      expect(command, isNot(contains('set status off')));
    });

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
      'watchWindowChanges attaches with only reusable client flags',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            }
          },
        );
        final execSessions = Queue<SSHSession>.from([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          controlSession,
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        final subscription = service
            .watchWindowChanges(
              session,
              'main',
              extraFlags: r'-S /tmp/socket -x 160 \; set status off',
            )
            .listen((_) {});
        addTearDown(() async {
          await subscription.cancel();
          await service.clearCache(1);
          await stdoutController.close();
        });
        await untilCalled(
          () => client.execute(
            any(that: contains('attach-session')),
            pty: any(named: 'pty'),
          ),
        );
        await untilCalled(() => controlSession.write(any()));

        final command =
            verify(
                  () => client.execute(
                    captureAny(that: contains('attach-session')),
                    pty: any(named: 'pty'),
                  ),
                ).captured.single
                as String;
        expect(
          command,
          contains(
            "/usr/bin/tmux -u -S '/tmp/socket' -CC attach-session -f "
            'ignore-size,no-output ',
          ),
        );
        expect(command, isNot(contains('set status off')));
      },
    );

    test(
      'clearCache detaches an active control-mode watcher before closing it',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 73);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final writes = <String>[];
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            writes.add(value);
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            }
          },
        );
        final execSessions = Queue<SSHSession>.from([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          controlSession,
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));

        await service.clearCache(73);

        expect(writes, contains('detach-client -P\n\n'));
        verify(controlSession.close).called(1);
      },
    );

    test(
      'clearCache waits for disposal that subscription cancel started',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 74);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final stdinCloseCompleter = Completer<void>();
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          stdinClose: stdinCloseCompleter.future,
          onWrite: (value) {
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            }
          },
        );
        final execSessions = Queue<SSHSession>.from([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          controlSession,
        ]);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSessions.removeFirst());

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          if (!stdinCloseCompleter.isCompleted) {
            stdinCloseCompleter.complete();
          }
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));

        await subscription.cancel();
        await Future<void>.delayed(Duration.zero);

        var clearCacheCompleted = false;
        final clearCacheFuture = service.clearCache(74).then((_) {
          clearCacheCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(clearCacheCompleted, isFalse);

        stdinCloseCompleter.complete();
        await clearCacheFuture;

        expect(clearCacheCompleted, isTrue);
        verify(controlSession.close).called(1);
      },
    );

    test(
      'clearCache waits for a starting watcher and detaches it after open',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 75);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>.broadcast();
        final controlOpenCompleter = Completer<SSHSession>();
        final writes = <String>[];
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: writes.add,
        );
        var executeCalls = 0;

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) {
          executeCalls += 1;
          final command = invocation.positionalArguments.single as String;
          if (command.contains('command -v tmux')) {
            return Future.value(
              _buildOpenExecSession(
                stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
              ),
            );
          }
          expect(command, contains('attach-session'));
          return controlOpenCompleter.future;
        });

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          if (!controlOpenCompleter.isCompleted) {
            controlOpenCompleter.complete(controlSession);
          }
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(
          () => client.execute(
            any(that: contains('attach-session')),
            pty: any(named: 'pty'),
          ),
        );

        var clearCacheCompleted = false;
        final clearCacheFuture = service.clearCache(75).then((_) {
          clearCacheCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(clearCacheCompleted, isFalse);

        controlOpenCompleter.complete(controlSession);
        await clearCacheFuture;

        expect(clearCacheCompleted, isTrue);
        expect(writes, contains('detach-client -P\n\n'));
        expect(executeCalls, 2);
        verify(controlSession.close).called(1);
      },
    );

    test('selectWindow uses an active control-mode watcher', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 70);
      const service = TmuxService();
      final stdoutController = StreamController<Uint8List>();
      final writes = <String>[];
      final controlSession = _buildInteractiveExecSession(
        stdoutController: stdoutController,
        onWrite: (value) {
          writes.add(value);
          if (value.startsWith('refresh-client ') ||
              value.startsWith('select-window ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
              ),
            );
          }
        },
      );
      final execSessions = Queue<SSHSession>.from([
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        controlSession,
      ]);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSessions.removeFirst());

      final subscription = service
          .watchWindowChanges(session, 'main')
          .listen((_) {});
      await untilCalled(() => controlSession.write(any()));

      await service.selectWindow(session, 'main', 2);

      expect(writes, contains("select-window -t 'main':2\n"));
      verifyNever(
        () => client.execute(
          any(that: contains('select-window')),
          pty: any(named: 'pty'),
        ),
      );

      await subscription.cancel();
      await stdoutController.close();
    });

    test('createWindow uses an active control-mode watcher', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 71);
      const service = TmuxService();
      final stdoutController = StreamController<Uint8List>();
      final writes = <String>[];
      final controlSession = _buildInteractiveExecSession(
        stdoutController: stdoutController,
        onWrite: (value) {
          writes.add(value);
          if (value.startsWith('refresh-client ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
              ),
            );
          } else if (value.startsWith('new-window ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n4\n%end 1 1 0\n'),
              ),
            );
          } else if (value.startsWith('set-option ') ||
              value.startsWith('send-keys ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
              ),
            );
          }
        },
      );
      final execSessions = Queue<SSHSession>.from([
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        controlSession,
      ]);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSessions.removeFirst());

      final subscription = service
          .watchWindowChanges(session, 'main')
          .listen((_) {});
      await untilCalled(() => controlSession.write(any()));

      await service.createWindow(
        session,
        'main',
        command: 'gemini --yolo',
        name: 'gemini',
        workingDirectory: '/tmp/project',
      );

      expect(
        writes,
        contains(
          "new-window -P -F '#{window_index}' -t 'main' "
          "-c '/tmp/project' -n 'gemini'\n",
        ),
      );
      expect(
        writes,
        contains("set-option -w -t 'main:4' @flutty_agent_tool 'gemini'\n"),
      );
      expect(writes, contains("send-keys -t 'main:4' 'gemini --yolo' Enter\n"));
      verifyNever(
        () => client.execute(
          any(that: contains('new-window')),
          pty: any(named: 'pty'),
        ),
      );

      await subscription.cancel();
      await stdoutController.close();
    });

    test(
      'listWindows uses an active control-mode watcher during exec backoff',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 72);
        const service = TmuxService();
        const sep = tmuxWindowFieldSeparator;
        final stdoutController = StreamController<Uint8List>();
        final writes = <String>[];
        final windowLine = [
          '1',
          'fresh',
          '1',
          'nvim',
          '/tmp/project',
          '*',
          'fresh-title',
          '200',
          'nvim',
          '',
          '@9',
        ].join(sep);
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            writes.add(value);
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            } else if (value.startsWith('list-windows ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 2 1 0\n$windowLine\n%end 2 1 0\n'),
                ),
              );
            }
          },
        );
        var executeCalls = 0;

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          executeCalls += 1;
          if (executeCalls == 1) {
            return _buildOpenExecSession(
              stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
            );
          }
          if (executeCalls == 2) {
            return controlSession;
          }
          if (executeCalls == 3) {
            return Future<SSHSession>.error(
              SSHChannelOpenError(2, 'open failed'),
            );
          }
          throw StateError('Unexpected SSH exec call $executeCalls');
        });

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          await service.clearCache(72);
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          service.hasSessionOrThrow(session, 'main'),
          throwsA(isA<SSHChannelOpenError>()),
        );
        expect(TmuxService.hasExecChannelBackoffEntry(72), isTrue);

        final windows = await service.listWindows(session, 'main');

        expect(windows, hasLength(1));
        expect(windows.single.name, 'fresh');
        expect(windows.single.id, '@9');
        expect(
          writes,
          contains(
            predicate<String>((value) => value.startsWith('list-windows ')),
          ),
        );
        expect(executeCalls, 3);
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
      'selectWindow uses only reusable client flags when provided',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(stdout: _doneMarker());

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execSession);

        await service.selectWindow(
          session,
          'main',
          2,
          extraFlags: r'-S /tmp/socket -x 160 \; set status off',
        );

        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u -S '/tmp/socket' select-window -t 'main':2",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
    );

    test('selectWindow targets stable window IDs when provided', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(stdout: _doneMarker());

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      await service.selectWindow(session, 'main', 2, windowId: '@12');

      verify(
        () => client.execute(
          any(that: contains("tmux -u select-window -t '@12'")),
          pty: any(named: 'pty'),
        ),
      ).called(1);
    });

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

  group('clearCache lifecycle', () {
    // Connection IDs 60-69 reserved for this group to avoid static-cache
    // collisions with other groups in the same test run.

    test(
      'clears installed agent tools cache so subsequent call re-probes SSH',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 60);
        const service = TmuxService();

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async => _buildOpenExecSession(
            stdout: '/opt/homebrew/bin/claude\n${_doneMarker()}',
          ),
        );

        // Seed the agent-tools cache.
        final first = await service.detectInstalledAgentTools(session);
        expect(first, {AgentLaunchTool.claudeCode});
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(60), isTrue);

        // Clear and verify the cache entry is gone.
        await service.clearCache(60);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(60), isFalse);

        // A subsequent call must re-probe via SSH rather than serve stale data.
        final second = await service.detectInstalledAgentTools(session);
        expect(second, {AgentLaunchTool.claudeCode});
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      },
    );

    test(
      'clears tmux path cache so subsequent path probe is re-issued',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 61);
        const service = TmuxService();
        // hasSessionOrThrow issues two SSH execs: (1) the path probe and
        // (2) the has-session command.  A second call skips the probe.
        final execQueue = Queue<SSHSession>.of([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: '1\n${_doneMarker()}'),
          // After clearCache a fresh path probe is issued again.
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: '1\n${_doneMarker()}'),
        ]);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => execQueue.removeFirst());

        // Seed the path cache via a method that calls _cacheTmuxPath.
        await service.hasSessionOrThrow(session, 'work');
        expect(TmuxService.hasTmuxPathCacheEntry(61), isTrue);

        // Clear and verify the cache entry is gone.
        await service.clearCache(61);
        expect(TmuxService.hasTmuxPathCacheEntry(61), isFalse);

        // A subsequent call must re-probe the tmux binary path.
        await service.hasSessionOrThrow(session, 'work');
        expect(TmuxService.hasTmuxPathCacheEntry(61), isTrue);
        verify(
          () => client.execute(
            any(that: contains('command -v tmux')),
            pty: any(named: 'pty'),
          ),
        ).called(2);
      },
    );

    test(
      'clears window snapshot cache so stale windows are not served',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 62);
        const service = TmuxService();
        const sep = tmuxWindowFieldSeparator;
        final windowLine = [
          '0',
          'editor',
          '1',
          'nvim',
          '/home/user/project',
          '*',
          'editor',
          '200',
          'nvim',
          '',
          '@1',
        ].join(sep);

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async =>
              _buildOpenExecSession(stdout: '$windowLine\n${_doneMarker()}'),
        );

        // listWindows populates _windowSnapshotCache when results are non-empty.
        final windows = await service.listWindows(session, 'main');
        expect(windows, hasLength(1));
        expect(TmuxService.hasWindowSnapshotCacheEntry(62), isTrue);

        // After clearCache the snapshot is gone.
        await service.clearCache(62);
        expect(TmuxService.hasWindowSnapshotCacheEntry(62), isFalse);
      },
    );

    test(
      'clears exec-channel backoff so the next exec channel is not throttled',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 63);
        const service = TmuxService();

        // Trigger a channel-open failure so a backoff entry is recorded.
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async =>
              Future<SSHSession>.error(SSHChannelOpenError(2, 'open failed')),
        );
        await expectLater(
          service.listWindows(session, 'main'),
          throwsA(isA<SSHChannelOpenError>()),
        );
        expect(TmuxService.hasExecChannelBackoffEntry(63), isTrue);

        // clearCache must remove the backoff so the next open is attempted.
        await service.clearCache(63);
        expect(TmuxService.hasExecChannelBackoffEntry(63), isFalse);
      },
    );

    test(
      'clearCache for one connection does not affect another connection',
      () async {
        final clientA = _MockSshClient();
        final clientB = _MockSshClient();
        final sessionA = _buildSession(clientA, connectionId: 64);
        final sessionB = _buildSession(clientB, connectionId: 65);
        const service = TmuxService();

        for (final client in [clientA, clientB]) {
          when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
            (_) async => _buildOpenExecSession(
              stdout: '/opt/homebrew/bin/codex\n${_doneMarker()}',
            ),
          );
        }

        await service.detectInstalledAgentTools(sessionA);
        await service.detectInstalledAgentTools(sessionB);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(64), isTrue);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(65), isTrue);

        // Clearing A must not affect B.
        await service.clearCache(64);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(64), isFalse);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(65), isTrue);

        // Clean up B.
        await service.clearCache(65);
      },
    );
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

String _tmuxWindowLine({
  required String id,
  required int panePid,
  String title = 'Title',
}) => [
  '0',
  'copilot',
  '1',
  'copilot',
  '/tmp/project',
  '*',
  title,
  '100',
  'copilot',
  '',
  id,
  '$panePid',
].join(tmuxWindowFieldSeparator);

bool _isCopilotMetadataCommand(String command) =>
    command.contains('ps -eo pid=,ppid=,comm=,args=');

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockByteSink extends Mock implements StreamSink<Uint8List> {}

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

Uint8List _utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));

void _ignoreInvocation(Invocation _) {}

SSHSession _buildOpenExecSession({
  String stdout = '',
  String stderr = '',
  Future<void>? done,
}) {
  final session = _MockExecSession();
  final doneFuture = done ?? Completer<void>().future;
  when(() => session.stdout).thenAnswer((_) => _openUtf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _openUtf8Stream(stderr));
  when(() => session.done).thenAnswer((_) => doneFuture);
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildClosedExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _closedUtf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _closedUtf8Stream(stderr));
  when(() => session.done).thenAnswer((_) => Future<void>.value());
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildInteractiveExecSession({
  required StreamController<Uint8List> stdoutController,
  void Function(String)? onWrite,
  String stderr = '',
  Future<void>? done,
  Future<void>? stdinClose,
}) {
  final session = _MockExecSession();
  final doneFuture = done ?? Completer<void>().future;
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) => stdinClose ?? Future<void>.value());
  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => _openUtf8Stream(stderr));
  when(() => session.done).thenAnswer((_) => doneFuture);
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer(_ignoreInvocation);
  when(() => session.write(any())).thenAnswer((invocation) {
    final data = invocation.positionalArguments.single as List<int>;
    onWrite?.call(utf8.decode(data));
  });
  return session;
}
