// ignore_for_file: public_member_api_docs

import 'dart:convert';
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
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        "npm install -g '@anthropic-ai/claude-code'@latest",
      );
      final windows = buildAgentInstallCommand(
        definition,
        windows: true,
        update: true,
      );
      expect(windows, isNotNull);
      final script = _decodePowerShellCommand(windows!);
      expect(script, contains(r'$PROFILE.CurrentUserAllHosts'));
      expect(script, contains("'@anthropic-ai/claude-code@latest'"));
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
        "brew upgrade 'opencode'",
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
        r"npm install -g 'it'\''s-agent'@latest",
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
            '__monkeyssh_agent_path__=/usr/local/bin/claude\n'
            '__monkeyssh_agent_version__=claude 1.0.0\n',
          );
        }
        if (command.contains('npm list -g')) {
          return _execOutput('@anthropic-ai/claude-code@1.0.0');
        }
        if (command.contains('npm view')) {
          return _execOutput('1.1.0');
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
      expect(command, contains('tr'));
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
      expect(script, contains(r'$__flVersion='));
      expect(script, contains('-join " "'));
    });
  });
}
