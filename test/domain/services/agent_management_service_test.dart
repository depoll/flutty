// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockDiscovery extends Mock implements AgentSessionDiscoveryService {}

SSHSession _execOutput(String output, {int exitCode = 0}) {
  final exec = _MockExecSession();
  when(() => exec.stdout).thenAnswer(
    (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
  );
  when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
  when(() => exec.done).thenAnswer((_) async {});
  when(() => exec.exitCode).thenReturn(exitCode);
  when(exec.close).thenReturn(null);
  return exec;
}

SshSession _remoteSession(_MockSshClient client) => SshSession(
  connectionId: 77,
  hostId: 3,
  client: client,
  config: const SshConnectionConfig(
    hostname: 'agent.example.com',
    port: 22,
    username: 'dev',
  ),
);

String _decodePowerShellCommand(String command) {
  const marker = '-EncodedCommand ';
  final encoded = command.substring(command.indexOf(marker) + marker.length);
  final bytes = base64.decode(encoded.trim());
  final units = <int>[];
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    units.add(bytes[index] | (bytes[index + 1] << 8));
  }
  return String.fromCharCodes(units);
}

void main() {
  tearDown(resetQueuedSshExecsForTesting);
  group('parseAgentVersion', () {
    test('parses common CLI version output', () {
      expect(parseAgentVersion('claude 2.1.29 (Claude Code)'), '2.1.29');
      expect(parseAgentVersion('opencode version v1.2.3'), '1.2.3');
      expect(parseAgentVersion('github-copilot/0.0.371'), '0.0.371');
      expect(parseAgentVersion('codex-cli 0.98.0-alpha.3'), '0.98.0-alpha.3');
      expect(parseAgentVersion('no version here'), isNull);
    });
  });

  group('compareAgentVersions', () {
    test('compares numeric segments instead of lexical text', () {
      expect(compareAgentVersions('1.9.0', '1.10.0'), lessThan(0));
      expect(compareAgentVersions('2.0', '2.0.0'), 0);
      expect(compareAgentVersions('2026.8.1', '2026.7.12'), greaterThan(0));
    });

    test('orders prereleases before stable versions', () {
      expect(compareAgentVersions('1.0.0-beta.2', '1.0.0'), lessThan(0));
      expect(compareAgentVersions('v1.0.0', '1.0.0'), 0);
    });
  });

  test('registers every supported CLI and built-in ACP adapter', () {
    expect(agentCliRuntimeDefinitions, hasLength(11));
    expect(agentAcpRuntimeDefinitions, hasLength(10));
    expect(agentStandaloneAcpRuntimeDefinitions, hasLength(4));
    expect(agentRuntimeDefinitions, hasLength(15));
    expect(
      agentStandaloneAcpRuntimeDefinitions.map((definition) => definition.id),
      <String>['acp:claude', 'acp:codex', 'acp:antigravity', 'acp:pi'],
    );
    final antigravityAcp = agentStandaloneAcpRuntimeDefinitions.firstWhere(
      (definition) => definition.id == 'acp:antigravity',
    );
    expect(antigravityAcp.executableNames, contains('npx'));
    expect(
      agentCliRuntimeDefinitions.map((definition) => definition.label),
      containsAll(<String>[
        'Claude Code',
        'Copilot CLI',
        'Codex',
        'Gemini CLI',
        'OpenCode',
        'Antigravity',
        'Cursor Agent',
        'Pi',
        'Hermes',
        'OpenClaw',
        'Grok Build',
      ]),
    );
  });

  group('buildAgentInstallCommand', () {
    test('builds npm install and update commands for POSIX and Windows', () {
      final definition = agentCliRuntimeDefinitions.first;
      final posix = buildAgentInstallCommand(
        definition,
        windows: false,
        update: false,
      );
      expect(posix, contains(r'export PATH="$HOME/.opencode/bin'));
      expect(
        posix,
        endsWith(
          "npm install -g --foreground-scripts --ignore-scripts=false '@anthropic-ai/claude-code'@latest",
        ),
      );
      final windows = buildAgentInstallCommand(
        definition,
        windows: true,
        update: true,
      );
      expect(windows, isNotNull);
      final script = _decodePowerShellCommand(windows!);
      expect(script, contains(r'$PROFILE.CurrentUserAllHosts'));
      expect(
        script,
        contains('npm install -g --foreground-scripts --ignore-scripts=false'),
      );
      expect(script, contains("'@anthropic-ai/claude-code@latest'"));
    });

    test('enables lifecycle scripts for every managed npm install', () {
      final npmDefinitions = agentRuntimeDefinitions.where(
        (definition) => definition.registry == AgentPackageRegistry.npm,
      );

      for (final definition in npmDefinitions) {
        final posix = buildAgentInstallCommand(
          definition,
          windows: false,
          update: false,
        );
        expect(
          posix,
          contains(
            'npm install -g --foreground-scripts --ignore-scripts=false',
          ),
          reason: definition.id,
        );

        final windows = buildAgentInstallCommand(
          definition,
          windows: true,
          update: false,
        );
        expect(
          _decodePowerShellCommand(windows!),
          contains(
            'npm install -g --foreground-scripts --ignore-scripts=false',
          ),
          reason: definition.id,
        );
      }
    });

    test('repair reinstalls broken managed packages', () {
      final openCode = agentCliRuntimeDefinitions.firstWhere(
        (definition) => definition.id == 'cli:opencode',
      );
      final posix = buildAgentInstallCommand(
        openCode,
        windows: false,
        update: false,
        repair: true,
      );
      expect(posix, contains("npm uninstall -g 'opencode-ai'"));
      expect(
        posix,
        endsWith(
          "npm install -g --foreground-scripts --ignore-scripts=false 'opencode-ai'@latest",
        ),
      );

      final windows = _decodePowerShellCommand(
        buildAgentInstallCommand(
          openCode,
          windows: true,
          update: false,
          repair: true,
        )!,
      );
      expect(windows, contains("npm uninstall -g 'opencode-ai'"));
      expect(
        windows,
        contains('npm install -g --foreground-scripts --ignore-scripts=false'),
      );

      final hermes = agentCliRuntimeDefinitions.firstWhere(
        (definition) => definition.id == 'cli:hermes',
      );
      expect(
        buildAgentInstallCommand(
          hermes,
          windows: false,
          update: false,
          repair: true,
        ),
        contains("pipx reinstall 'hermes-agent'"),
      );
    });

    test('uses every supported CLI built-in updater', () {
      final cases = <(String, String, List<String>)>[
        ('cli:claude', '/opt/tools/claude', ['update']),
        ('cli:copilot', '/opt/tools/copilot', ['update']),
        ('cli:codex', '/opt/tools/codex', ['update']),
        ('cli:gemini', '/opt/tools/gemini', ['update']),
        ('cli:opencode', '/opt/tools/opencode', ['upgrade']),
        ('cli:antigravity', '/opt/tools/agy', ['update']),
        ('cli:cursor', '/opt/tools/cursor-agent', ['update']),
        ('cli:pi', '/opt/tools/pi', ['update', '--self']),
        ('cli:hermes', '/opt/tools/hermes', ['update', '--yes']),
        ('cli:openclaw', '/opt/tools/openclaw', ['update', '--yes']),
        ('cli:grok', '/opt/tools/grok', ['update']),
      ];
      expect(cases, hasLength(agentCliRuntimeDefinitions.length));

      for (final entry in cases) {
        final definition = agentCliRuntimeDefinitions.firstWhere(
          (runtime) => runtime.id == entry.$1,
        );
        expect(definition.selfUpdateArguments, entry.$3);
        final quotedArguments = entry.$3
            .map((argument) => "'$argument'")
            .join(' ');
        final posix = buildAgentInstallCommand(
          definition,
          windows: false,
          update: true,
          detectionSource: 'PATH',
          executablePath: entry.$2,
        );
        expect(posix, endsWith("'${entry.$2}' $quotedArguments"));

        final windows = buildAgentInstallCommand(
          definition,
          windows: true,
          update: true,
          detectionSource: 'PATH',
          executablePath: entry.$2,
        );
        final script = _decodePowerShellCommand(windows!);
        expect(script, contains("& '${entry.$2}' $quotedArguments"));
      }
    });

    test('keeps Homebrew updates with the detected package manager', () {
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.label == 'OpenCode',
      );
      expect(
        buildAgentInstallCommand(
          definition,
          windows: false,
          update: true,
          detectionSource: 'Homebrew',
        ),
        endsWith("brew upgrade 'opencode'"),
      );
    });

    test('builds pipx commands with a Python fallback', () {
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.label == 'Hermes',
      );
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        contains('pipx install'),
      );
      final windows = buildAgentInstallCommand(
        definition,
        windows: true,
        update: true,
      );
      expect(
        _decodePowerShellCommand(windows!),
        contains("& py -m pip install --user --upgrade 'hermes-agent'"),
      );
    });

    test('quotes apostrophes safely for POSIX shells', () {
      const definition = AgentRuntimeDefinition(
        id: 'test',
        label: 'Test',
        kind: AgentRuntimeKind.cli,
        executableNames: ['test'],
        registry: AgentPackageRegistry.npm,
        packageName: "it's-agent",
      );
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        endsWith(
          r"npm install -g --foreground-scripts --ignore-scripts=false 'it'\''s-agent'@latest",
        ),
      );
    });

    test('does not guess an installer for unsupported packages', () {
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.label == 'Cursor Agent',
      );
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        isNull,
      );
    });
  });

  group('AgentManagementService', () {
    test('detects npm ownership and an available update', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('command -v')) {
          return _execOutput(
            '__monkeyssh_agent_path__=/usr/local/bin/claude\n',
          );
        }
        if (command.contains('__monkeyssh_agent_source__')) {
          return _execOutput(
            '__monkeyssh_agent_runtime__=cli:claude\n'
            '__monkeyssh_agent_source__=npm global\n'
            '__monkeyssh_agent_installed__=1.0.0\n'
            '__monkeyssh_agent_latest__=1.1.0\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        }
        return _execOutput('', exitCode: 1);
      });

      final runtime = await AgentManagementService(
        discovery,
      ).inspect(session, agentCliRuntimeDefinitions.first);

      expect(runtime.status, AgentRuntimeStatus.updateAvailable);
      expect(runtime.installedVersion, '1.0.0');
      expect(runtime.latestVersion, '1.1.0');
      expect(runtime.detectionSource, 'npm global');
      expect(runtime.managedByPackageManager, isTrue);
    });

    test('marks skipped postinstall installations as repairable', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.id == 'cli:opencode',
      );
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        if (executeCount == 1) {
          return _execOutput(
            '__monkeyssh_agent_path__=/usr/local/bin/opencode\n'
            '__monkeyssh_agent_repair__\n',
          );
        }
        return _execOutput(
          '__monkeyssh_agent_runtime__=cli:opencode\n'
          '__monkeyssh_agent_source__=npm global\n'
          '__monkeyssh_agent_runtime_end__\n',
        );
      });

      final runtime = await AgentManagementService(
        discovery,
      ).inspect(session, definition);

      expect(runtime.status, AgentRuntimeStatus.needsRepair);
      expect(runtime.executablePath, '/usr/local/bin/opencode');
      expect(runtime.message, contains('Required setup scripts'));
    });

    test('detects Antigravity ACP through its npx launcher', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      final definition = agentStandaloneAcpRuntimeDefinitions.firstWhere(
        (runtime) => runtime.id == 'acp:antigravity',
      );
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        if (executeCount == 1) {
          return _execOutput('__monkeyssh_agent_path__=/usr/local/bin/npx\n');
        }
        return _execOutput(
          '__monkeyssh_agent_runtime__=acp:antigravity\n'
          '__monkeyssh_agent_runtime_end__\n',
        );
      });

      final runtime = await AgentManagementService(
        discovery,
      ).inspect(session, definition);

      expect(runtime.status, AgentRuntimeStatus.installed);
      expect(runtime.executablePath, '/usr/local/bin/npx');
      expect(runtime.detectionSource, 'npx on demand');
    });

    test('automatic update checks include CLIs only', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        final output = StringBuffer();
        for (final definition in agentCliRuntimeDefinitions) {
          output
            ..writeln('__monkeyssh_agent_runtime__=${definition.id}')
            ..writeln('__monkeyssh_agent_runtime_end__');
        }
        return _execOutput(output.toString());
      });

      final runtimes = await AgentManagementService(
        discovery,
      ).checkForUpdates(session);

      expect(runtimes, hasLength(agentCliRuntimeDefinitions.length));
      expect(
        runtimes,
        everyElement(
          isA<AgentRuntimeInfo>().having(
            (runtime) => runtime.definition.kind,
            'kind',
            AgentRuntimeKind.cli,
          ),
        ),
      );
      expect(executeCount, 1);
    });

    test('refresh probes all runtimes through one SSH channel', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => discovery.invalidateSession(session)).thenReturn(null);
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        final output = StringBuffer();
        for (final definition in [
          ...agentCliRuntimeDefinitions,
          ...agentStandaloneAcpRuntimeDefinitions,
        ]) {
          output
            ..writeln('__monkeyssh_agent_runtime__=${definition.id}')
            ..writeln('__monkeyssh_agent_runtime_end__');
        }
        return _execOutput(output.toString());
      });

      final runtimes = await AgentManagementService(
        discovery,
      ).refreshAll(session);

      expect(runtimes, hasLength(agentRuntimeDefinitions.length));
      expect(
        runtimes,
        everyElement(
          isA<AgentRuntimeInfo>().having(
            (runtime) => runtime.status,
            'status',
            AgentRuntimeStatus.notInstalled,
          ),
        ),
      );
      expect(executeCount, 1);
    });

    test(
      'refresh batches installed metadata into a second SSH channel',
      () async {
        final client = _MockSshClient();
        final discovery = _MockDiscovery();
        final session = _remoteSession(client);
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
        when(() => discovery.invalidateSession(session)).thenReturn(null);
        var executeCount = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          executeCount += 1;
          final command = invocation.positionalArguments.first as String;
          if (command.contains('__monkeyssh_agent_path__')) {
            final output = StringBuffer();
            for (final definition in [
              ...agentCliRuntimeDefinitions,
              ...agentStandaloneAcpRuntimeDefinitions,
            ]) {
              output.writeln('__monkeyssh_agent_runtime__=${definition.id}');
              if (definition.id == 'cli:copilot') {
                output.writeln(
                  '__monkeyssh_agent_path__=/usr/local/bin/copilot',
                );
              }
              output.writeln('__monkeyssh_agent_runtime_end__');
            }
            return _execOutput(output.toString());
          }
          return _execOutput(
            '__monkeyssh_agent_runtime__=cli:copilot\n'
            '__monkeyssh_agent_source__=npm global\n'
            '__monkeyssh_agent_installed__=1.0.0\n'
            '__monkeyssh_agent_latest__=1.1.0\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        });

        final runtimes = await AgentManagementService(
          discovery,
        ).refreshAll(session);

        final copilot = runtimes.firstWhere(
          (runtime) => runtime.definition.id == 'cli:copilot',
        );
        expect(copilot.status, AgentRuntimeStatus.updateAvailable);
        expect(copilot.detectionSource, 'npm global');
        expect(copilot.installedVersion, '1.0.0');
        expect(copilot.latestVersion, '1.1.0');
        expect(
          runtimes.where((runtime) => runtime.definition.id == 'acp:copilot'),
          isEmpty,
        );
        expect(
          runtimes
              .where(
                (runtime) =>
                    runtime.definition.kind == AgentRuntimeKind.acpAdapter,
              )
              .where((runtime) => runtime.hasUpdate),
          isEmpty,
        );
        expect(executeCount, 2);
      },
    );

    test('streams install output and invalidates provider discovery', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => _execOutput('installed 1 package'));
      when(() => discovery.invalidateSession(session)).thenReturn(null);
      final streamed = StringBuffer();

      final result = await AgentManagementService(discovery).installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: AgentRuntimeInfo(
          definition: agentCliRuntimeDefinitions.first,
          status: AgentRuntimeStatus.updateAvailable,
          detectionSource: 'npm global',
          managedByPackageManager: true,
        ),
        onOutput: streamed.write,
      );

      expect(result.succeeded, isTrue);
      expect(streamed.toString(), contains('installed 1 package'));
      verify(() => discovery.invalidateSession(session)).called(1);
    });
  });

  group('batch probes', () {
    test('parses installed and missing runtimes independently', () {
      final snapshots = parseAgentBatchProbeOutput(
        'profile chatter\n'
        '__monkeyssh_agent_runtime__=cli:claude\n'
        '__monkeyssh_agent_path__=/home/dev/bin/claude\n'
        '__monkeyssh_agent_version__=claude 1.2.3\n'
        '__monkeyssh_agent_runtime_end__\n'
        '__monkeyssh_agent_runtime__=cli:codex\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:claude']?.executablePath, '/home/dev/bin/claude');
      expect(snapshots['cli:claude']?.versionOutput, 'claude 1.2.3');
      expect(snapshots['cli:codex']?.executablePath, isNull);
    });

    test('retains a detected path from an interrupted runtime block', () {
      final snapshots = parseAgentBatchProbeOutput(
        '__monkeyssh_agent_runtime__=cli:claude\n'
        '__monkeyssh_agent_path__=/home/dev/bin/claude\n'
        '__monkeyssh_agent_runtime__=cli:codex\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:claude']?.executablePath, '/home/dev/bin/claude');
      expect(snapshots['cli:codex']?.executablePath, isNull);
    });

    test('marks skipped postinstall scripts for repair', () {
      final snapshots = parseAgentBatchProbeOutput(
        '__monkeyssh_agent_runtime__=cli:opencode\n'
        '__monkeyssh_agent_path__=/home/dev/bin/opencode\n'
        '__monkeyssh_agent_repair__\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:opencode']?.needsRepair, isTrue);
    });

    test('parses package ownership and latest versions', () {
      final snapshots = parseAgentMetadataProbeOutput(
        '__monkeyssh_agent_runtime__=cli:claude\n'
        '__monkeyssh_agent_source__=npm global\n'
        '__monkeyssh_agent_installed__=2.0.0\n'
        '__monkeyssh_agent_latest__=2.1.3\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:claude']?.detectionSource, 'npm global');
      expect(snapshots['cli:claude']?.installedVersionOutput, '2.0.0');
      expect(snapshots['cli:claude']?.latestVersionOutput, '2.1.3');
    });

    test('generated POSIX scripts pass bash syntax validation', () async {
      final definitions = <AgentRuntimeDefinition>[
        ...agentCliRuntimeDefinitions,
        ...agentStandaloneAcpRuntimeDefinitions,
      ];
      final scripts = [
        buildAgentBatchProbeCommand(definitions, windows: false),
        buildAgentMetadataProbeCommand(definitions, windows: false),
        buildAgentInstallCommand(
          agentCliRuntimeDefinitions.first,
          windows: false,
          update: true,
          detectionSource: 'npm global',
        )!,
      ];
      expect(scripts.first, contains('__monkeyssh_agent_repair__'));
      expect(scripts.first, contains('postinstall'));
      expect(scripts.first, contains('--ignore-scripts'));
      for (var index = 0; index < scripts.length; index += 1) {
        final file = File(
          '${Directory.systemTemp.path}/monkeyssh-agent-$index.sh',
        );
        await file.writeAsString(scripts[index]);
        addTearDown(() => file.delete().ignore());
        final result = await Process.run('bash', ['-n', file.path]);
        expect(result.exitCode, 0, reason: 'script $index: ${result.stderr}');
      }
    });

    test('detects versions without waiting for a hanging CLI', () async {
      final root = await Directory.systemTemp.createTemp(
        'monkeyssh-agent-version-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final quick = File('${bin.path}/quick-agent')
        ..writeAsStringSync('#!/bin/sh\necho "quick-agent 1.2.3"\n');
      final hanging = File('${bin.path}/hanging-agent')
        ..writeAsStringSync('#!/bin/sh\nsleep 20\n');
      final broken = File('${bin.path}/broken-agent')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'echo "Error: postinstall script was not run due to --ignore-scripts" >&2\n'
          'exit 1\n',
        );
      await Process.run('chmod', ['+x', quick.path, hanging.path, broken.path]);
      const definitions = <AgentRuntimeDefinition>[
        AgentRuntimeDefinition(
          id: 'cli:quick',
          label: 'Quick',
          kind: AgentRuntimeKind.cli,
          executableNames: ['quick-agent'],
        ),
        AgentRuntimeDefinition(
          id: 'cli:hanging',
          label: 'Hanging',
          kind: AgentRuntimeKind.cli,
          executableNames: ['hanging-agent'],
        ),
        AgentRuntimeDefinition(
          id: 'cli:broken',
          label: 'Broken',
          kind: AgentRuntimeKind.cli,
          executableNames: ['broken-agent'],
        ),
      ];
      final script = File('${root.path}/probe.sh')
        ..writeAsStringSync(
          buildAgentBatchProbeCommand(definitions, windows: false),
        );
      final shells = <String>['bash'];
      if (File('/bin/zsh').existsSync()) shells.add('/bin/zsh');
      for (final shell in shells) {
        final stopwatch = Stopwatch()..start();
        final result = await Process.run(
          shell,
          [script.path],
          environment: {
            'HOME': root.path,
            'PATH': '${bin.path}:/usr/bin:/bin',
            'TMPDIR': root.path,
          },
        );
        stopwatch.stop();
        final snapshots = parseAgentBatchProbeOutput(result.stdout as String);

        expect(
          result.exitCode,
          0,
          reason: '$shell: ${result.stderr as String}',
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 6)),
          reason: shell,
        );
        expect(
          snapshots['cli:quick']?.executablePath,
          quick.path,
          reason: shell,
        );
        expect(
          snapshots['cli:quick']?.versionOutput,
          'quick-agent 1.2.3',
          reason: shell,
        );
        expect(
          snapshots['cli:hanging']?.executablePath,
          hanging.path,
          reason: shell,
        );
        expect(snapshots['cli:hanging']?.versionOutput, isNull, reason: shell);
        expect(
          snapshots['cli:broken']?.executablePath,
          broken.path,
          reason: shell,
        );
        expect(snapshots['cli:broken']?.needsRepair, isTrue, reason: shell);
      }
    });

    test('does not query latest versions for ACP adapters', () {
      final command = buildAgentMetadataProbeCommand([
        agentAcpRuntimeDefinitions[1],
      ], windows: false);

      expect(command, isNot(contains('npm view')));
      expect(command, contains('npm list -g'));
    });

    test('builds one POSIX script containing every requested runtime', () {
      final command = buildAgentBatchProbeCommand(
        agentCliRuntimeDefinitions.take(2).toList(),
        windows: false,
      );

      expect(command, contains('__monkeyssh_agent_runtime__='));
      expect(command, contains("'cli:claude'"));
      expect(command, contains("'cli:copilot'"));
      expect(RegExp('~/.zprofile').allMatches(command), hasLength(1));
    });
  });

  group('buildAgentProbeCommand', () {
    test('sources login profiles and checks candidate paths on POSIX', () {
      final command = buildAgentProbeCommand(
        agentCliRuntimeDefinitions.first,
        windows: false,
      );
      expect(command, contains('~/.zprofile'));
      expect(command, contains("'claude' 'claude-code'"));
      expect(command, contains('command -v'));
      expect(command, contains('__monkeyssh_agent_version__='));
      expect(command, contains("'--version'"));
    });

    test('uses Get-Command and one-line markers on Windows', () {
      final command = buildAgentProbeCommand(
        agentCliRuntimeDefinitions.first,
        windows: true,
      );
      final script = _decodePowerShellCommand(command);
      expect(script, contains(r'$PROFILE.CurrentUserAllHosts'));
      expect(script, contains('Get-Command'));
      expect(
        script,
        contains(r"'__monkeyssh_agent_path__=' + $__flCommand.Source"),
      );
      expect(script, isNot(contains(r'$__flVersion=')));
    });
  });
}
