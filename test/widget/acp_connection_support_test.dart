// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_connection_support.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecChannel extends Mock implements SSHSession {}

void main() {
  test('ACP executable prewarm is reused during the launch window', () async {
    final client = _MockSshClient();
    final executedCommands = <String>[];
    when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      executedCommands.add(invocation.positionalArguments.single as String);
      final channel = _MockExecChannel();
      final output = [
        'cursor-agent\u001f/Users/demo/.local/bin/cursor-agent',
        'npx\u001f/opt/homebrew/bin/npx',
      ].join('\n');
      when(() => channel.stdout).thenAnswer(
        (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
      );
      when(
        () => channel.stderr,
      ).thenAnswer((_) => const Stream<Uint8List>.empty());
      when(() => channel.done).thenAnswer((_) async {});
      when(() => channel.exitCode).thenReturn(0);
      when(channel.close).thenReturn(null);
      return channel;
    });
    final session = SshSession(
      connectionId: 91,
      hostId: 3,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.test',
        port: 22,
        username: 'dev',
      ),
    );

    await prewarmAcpRemoteExecutables(session);
    await prewarmAcpRemoteExecutables(session);

    expect(executedCommands, hasLength(1));
    expect(executedCommands.single, contains('cursor-agent'));
    expect(executedCommands.single, contains('claude-agent-acp'));
    expect(executedCommands.single, contains('npx'));
  });
}
