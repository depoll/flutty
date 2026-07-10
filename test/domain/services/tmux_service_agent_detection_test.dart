import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  group('buildAgentToolDetectionCommand', () {
    test('runs an interactive instance of the user\'s shell', () {
      // The whole point of the rewrite: invoke `\$SHELL -ic`, falling
      // back to /bin/sh, so PATH additions from ~/.zshrc / ~/.bashrc
      // are picked up. SSH exec channels otherwise only see login
      // profiles and miss tools like `claude` that npm-global users
      // expose from rc files.
      final command = buildAgentToolDetectionCommand();
      expect(command, contains(r'SH="${SHELL:-/bin/sh}"'));
      expect(command, contains(r'"$SH" -ic '));
    });

    test('loops per-binary so it works on POSIX-strict shells (dash)', () {
      // dash and other strict POSIX shells reject `command -v a b c`
      // and print nothing; a per-binary loop avoids that pitfall.
      final command = buildAgentToolDetectionCommand();
      expect(command, contains('for c in '));
      expect(command, contains(r'command -v "$c"'));
    });

    test('queries every supported agent CLI', () {
      final command = buildAgentToolDetectionCommand();
      for (final tool in AgentLaunchTool.values) {
        expect(
          command,
          contains(tool.commandName),
          reason: 'detection command must look up ${tool.commandName}',
        );
      }
    });

    test('windows script queries every supported external agent CLI', () {
      final script = buildWindowsAgentToolDetectionScript();
      expect(script, contains('Get-Command -Name'));
      expect(script, contains('-CommandType Application,ExternalScript'));
      expect(script, contains(r'$__flOut'));
      for (final tool in AgentLaunchTool.values) {
        expect(
          script,
          contains("'${tool.commandName}'"),
          reason: 'Windows detection script must look up ${tool.commandName}',
        );
      }
    });

    test('tolerates missing binaries without failing the outer shell', () {
      final command = buildAgentToolDetectionCommand();
      // 2>/dev/null suppresses noisy "not found" messages from rc files
      // and the inner shell; `|| true` keeps the exit status clean so
      // the SSH exec channel does not surface a misleading error.
      expect(command, contains('2>/dev/null'));
      expect(command, endsWith('|| true'));
    });
  });

  group('parseInstalledAgentTools', () {
    test('returns empty for empty input', () {
      expect(parseInstalledAgentTools(''), isEmpty);
      expect(parseInstalledAgentTools('   \n  \n'), isEmpty);
    });

    test('parses absolute paths to known CLI binaries', () {
      const output =
          '/opt/homebrew/bin/claude\n'
          '/usr/local/bin/codex\n';
      expect(parseInstalledAgentTools(output), {
        AgentLaunchTool.claudeCode,
        AgentLaunchTool.codex,
      });
    });

    test('detects claude installed in ~/.local/bin (the regression case)', () {
      // Reproduces the user-reported regression: claude lives in
      // ~/.local/bin, which is added to PATH from ~/.zshrc rather
      // than ~/.zprofile. The interactive-shell command builder
      // resolves it; the parser must accept the path.
      const output = '/Users/depoll/.local/bin/claude\n';
      expect(parseInstalledAgentTools(output), {AgentLaunchTool.claudeCode});
    });

    test('parses Windows absolute paths and command shim extensions', () {
      const output =
          r'C:\Users\demo\AppData\Roaming\npm\claude.ps1'
          '\n'
          'C:/Users/demo/AppData/Roaming/npm/copilot.cmd\n'
          r'C:\tools\codex.exe'
          '\n'
          r'\\server\share\gemini.bat'
          '\n';
      expect(parseInstalledAgentTools(output), {
        AgentLaunchTool.claudeCode,
        AgentLaunchTool.copilotCli,
        AgentLaunchTool.codex,
        AgentLaunchTool.geminiCli,
      });
    });

    test('ignores bare names (shell builtins, aliases, missing CLIs)', () {
      // `command -v` may print bare names for builtins/aliases or omit
      // unknown commands entirely. Only absolute paths should count.
      const output =
          'claude\n'
          'claude.cmd\n'
          '/usr/local/bin/copilot\n'
          'codex: not found\n';
      expect(parseInstalledAgentTools(output), {AgentLaunchTool.copilotCli});
    });

    test('ignores unknown binaries', () {
      const output = '/usr/bin/cat\n/usr/bin/grep\n/opt/bin/gemini\n';
      expect(parseInstalledAgentTools(output), {AgentLaunchTool.geminiCli});
    });

    test('handles all supported CLIs', () {
      const output =
          '/b/claude\n'
          '/b/copilot\n'
          '/b/codex\n'
          '/b/gemini\n'
          '/b/opencode\n'
          '/b/antigravity\n'
          '/b/cursor-agent\n';
      expect(parseInstalledAgentTools(output), AgentLaunchTool.values.toSet());
    });

    test('tolerates trailing whitespace and CRLF line endings', () {
      const output = '/usr/local/bin/claude  \r\n/opt/bin/opencode\r\n';
      expect(parseInstalledAgentTools(output), {
        AgentLaunchTool.claudeCode,
        AgentLaunchTool.openCode,
      });
    });
  });

  group('agentToolForBinaryName', () {
    test('maps each command name back to its tool', () {
      for (final tool in AgentLaunchTool.values) {
        expect(agentToolForBinaryName(tool.commandName), tool);
      }
    });

    test('maps Windows command shim names back to their tools', () {
      expect(agentToolForBinaryName('copilot.cmd'), AgentLaunchTool.copilotCli);
      expect(agentToolForBinaryName('claude.ps1'), AgentLaunchTool.claudeCode);
      expect(agentToolForBinaryName('codex.exe'), AgentLaunchTool.codex);
    });

    test('returns null for unknown binaries', () {
      expect(agentToolForBinaryName('vim'), isNull);
      expect(agentToolForBinaryName(''), isNull);
    });
  });

  group('Copilot active session metadata', () {
    test(
      'command checks session metadata for agent descendants of pane PIDs',
      () {
        final command = buildAgentActiveSessionMetadataCommand(const {42, 88});

        expect(command, contains('pane_pids=\'42 88\''));
        expect(command, contains('unsetopt nomatch 2>/dev/null || true'));
        expect(command, contains('ps -eo pid=,ppid=,comm=,args='));
        expect(command, contains('flutty_lsof_session_match'));
        expect(command, contains('flutty_claude_session_title'));
        expect(command, contains('flutty_codex_session_title'));
        expect(command, contains('flutty_gemini_session_title'));
        expect(command, contains('flutty_process_cwd'));
        expect(command, contains('flutty_process_start_epoch'));
        expect(command, contains('flutty_file_is_newer_than_process'));
        expect(command, contains('flutty_copilot_lock_match'));
        expect(command, contains('flutty_iso8601_epoch'));
        expect(command, contains('flutty_codex_index_resume_match'));
        expect(command, contains('flutty_codex_logs_resume_match'));
        expect(command, contains('flutty_codex_recent_session_match'));
        expect(command, contains('flutty_gemini_recent_session_match'));
        expect(command, contains('flutty_antigravity_recent_session_match'));
        expect(command, contains('flutty_antigravity_session_title'));
        expect(command, contains('customTitle'));
        expect(command, contains('thread_name'));
        expect(command, contains('summary'));
        expect(command, contains('.claude'));
        expect(command, contains('.codex'));
        expect(command, contains('.gemini'));
        expect(command, contains(r'find "$home/.codex/sessions"'));
        expect(command, contains(r'find "$home/.gemini/tmp"'));
        expect(command, contains('session_index.jsonl'));
        expect(command, contains('logs_2.sqlite'));
        expect(command, contains(r'sqlite3 "$logs_db"'));
        expect(command, contains('thread_id'));
        expect(command, contains(r"process_uuid like 'pid:$pid:%'"));
        expect(command, contains('updated_at'));
        expect(
          command,
          contains(r'process_start_epoch=$(flutty_process_start_epoch "$pid")'),
        );
        expect(command, contains('sessionId'));
        expect(command, contains(r'inuse."$pid".lock'));
        expect(command, contains('workspace.yaml'));
        expect(command, contains(r'[ -d "$state_dir" ]'));
        expect(command, isNot(contains('lock_rows=')));
        expect(command, isNot(contains('inuse.*.lock')));
        expect(
          command,
          isNot(contains('.copilot/session-state/*/inuse.*.lock')),
        );
        expect(command, contains(r'ps -p "$pid" -o etime='));
        expect(command, isNot(contains('exit 0')));
      },
    );

    test(
      'ignores stale Copilot locks when a pane PID is reused',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'monkeyssh-copilot-lock-test-',
        );
        addTearDown(() => home.delete(recursive: true));
        final fakeBin = await Directory(
          '${home.path}/bin',
        ).create(recursive: true);
        final fakePs = File('${fakeBin.path}/ps');
        await fakePs.writeAsString(
          [
            '#!/bin/sh',
            r'case "$*" in',
            '  "-eo pid=,ppid=,comm=,args=")',
            r"    printf '%s\n' '42 1 zsh zsh' '501 42 copilot /opt/copilot'",
            '    ;;',
            '  "-p 501 -o etime=")',
            r"    printf '00:10\n'",
            '    ;;',
            'esac',
            '',
          ].join('\n'),
        );
        final fakeStat = File('${fakeBin.path}/stat');
        await fakeStat.writeAsString(
          [
            '#!/bin/sh',
            r'case "$1" in',
            '  -f)',
            r"    printf 'GNU stat filesystem output\n'",
            '    exit 1',
            '    ;;',
            '  -c)',
            r'    case "$3" in',
            r"      *aaa-stale*) printf '1\n' ;;",
            '      *) date +%s ;;',
            '    esac',
            '    ;;',
            'esac',
            '',
          ].join('\n'),
        );
        final chmod = await Process.run('chmod', [
          '+x',
          fakePs.path,
          fakeStat.path,
        ]);
        expect(chmod.exitCode, 0, reason: chmod.stderr as String?);

        final stateDirectory = Directory('${home.path}/.copilot/session-state');
        final staleSession = await Directory(
          '${stateDirectory.path}/aaa-stale',
        ).create(recursive: true);
        await File(
          '${staleSession.path}/workspace.yaml',
        ).writeAsString('summary: Different Copilot session\n');
        final staleLock = File('${staleSession.path}/inuse.501.lock');
        await staleLock.writeAsString('501');
        await staleLock.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 10)),
        );

        final command = buildAgentActiveSessionMetadataCommand(const {42});
        Future<ProcessResult> runProbe() => Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {
            'HOME': home.path,
            'PATH': '${fakeBin.path}:/usr/bin:/bin',
          },
          includeParentEnvironment: false,
        );

        final staleResult = await runProbe();
        expect(staleResult.exitCode, 0, reason: staleResult.stderr as String?);
        expect(
          parseAgentActiveSessionMetadataOutput(
            staleResult.stdout as String,
            const {42},
          ),
          isEmpty,
        );

        final currentSession = await Directory(
          '${stateDirectory.path}/zzz-current',
        ).create(recursive: true);
        await File(
          '${currentSession.path}/workspace.yaml',
        ).writeAsString('summary: Current Copilot session\n');
        await File(
          '${currentSession.path}/inuse.501.lock',
        ).writeAsString('501');

        final currentResult = await runProbe();
        expect(
          currentResult.exitCode,
          0,
          reason: currentResult.stderr as String?,
        );
        final metadata = parseAgentActiveSessionMetadataOutput(
          currentResult.stdout as String,
          const {42},
        );
        expect(metadata[42]?.sessionId, 'zzz-current');
        expect(metadata[42]?.title, 'Current Copilot session');
      },
      skip: Platform.isWindows ? 'Requires a POSIX shell.' : false,
    );

    test('command prefers Antigravity history title before annotation title', () {
      final command = buildAgentActiveSessionMetadataCommand(const {42});

      expect(
        command.indexOf(
          r'title=$(grep -F "$session_id" "$home/.gemini/antigravity-cli/history.jsonl"',
        ),
        lessThan(
          command.indexOf(
            r'annotation_file="$home/.gemini/antigravity-cli/annotations/${session_id}.pbtxt"',
          ),
        ),
      );
    });

    test('parses live session titles by matched pane PID', () {
      const sep = tmuxWindowFieldSeparator;

      final metadata = parseCopilotActiveSessionMetadataOutput(
        'session-1${sep}50122${sep}42${sep}User named Copilot session\n'
        'session-2${sep}99999${sep}77$sep\n',
        const {42, 88},
      );

      expect(metadata.keys, [42]);
      expect(metadata[42]?.sessionId, 'session-1');
      expect(metadata[42]?.title, 'User named Copilot session');
    });

    test('parses live metadata for every supported agent tool', () {
      const sep = tmuxWindowFieldSeparator;

      final metadata = parseAgentActiveSessionMetadataOutput(
        'claude${sep}claude-1${sep}501${sep}42${sep}medium$sep\n'
        'codex${sep}codex-1${sep}502${sep}43${sep}medium$sep\n'
        'gemini${sep}gemini-1${sep}503${sep}44${sep}medium$sep\n'
        'opencode${sep}opencode-1${sep}504${sep}45${sep}medium$sep\n'
        'antigravity${sep}antigravity-1${sep}506${sep}47${sep}medium${sep}Anti Title\n'
        'copilot${sep}copilot-1${sep}505${sep}46${sep}medium${sep}Title\n',
        const {42, 43, 44, 45, 46, 47},
      );

      expect(metadata[42]?.tool, AgentLaunchTool.claudeCode);
      expect(metadata[43]?.tool, AgentLaunchTool.codex);
      expect(metadata[44]?.tool, AgentLaunchTool.geminiCli);
      expect(metadata[45]?.tool, AgentLaunchTool.openCode);
      expect(metadata[46]?.tool, AgentLaunchTool.copilotCli);
      expect(metadata[46]?.title, 'Title');
      expect(metadata[46]?.confidence, AgentSessionConfidence.medium);
      expect(metadata[47]?.tool, AgentLaunchTool.antigravity);
      expect(metadata[47]?.sessionId, 'antigravity-1');
      expect(metadata[47]?.title, 'Anti Title');
    });

    test(
      'prefers higher confidence when multiple matches exist for a pane',
      () {
        const sep = tmuxWindowFieldSeparator;

        final metadata = parseAgentActiveSessionMetadataOutput(
          'claude${sep}inferred${sep}501${sep}42${sep}medium$sep\n'
          'claude${sep}explicit${sep}502${sep}42${sep}high$sep\n',
          const {42},
        );

        expect(metadata[42]?.sessionId, 'explicit');
        expect(metadata[42]?.confidence, AgentSessionConfidence.high);
      },
    );

    test('does not force refresh when only a Copilot tmux title changes', () {
      const existing = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Old title',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Old title',
      );
      const updated = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'New title',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'New title',
      );

      expect(
        shouldForceAgentSessionMetadataRefreshForSnapshot(const [
          existing,
        ], updated),
        isFalse,
      );
    });

    test('forces refresh when the Copilot pane process changes', () {
      const existing = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Current title',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Current title',
      );
      const updated = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 99,
        name: 'Current title',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Current title',
      );

      expect(
        shouldForceAgentSessionMetadataRefreshForSnapshot(const [
          existing,
        ], updated),
        isTrue,
      );
    });

    test('does not force refresh for unchanged Copilot snapshots', () {
      const existing = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Current title',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Current title',
      );

      expect(
        shouldForceAgentSessionMetadataRefreshForSnapshot(const [
          existing,
        ], existing),
        isFalse,
      );
    });
  });
}
