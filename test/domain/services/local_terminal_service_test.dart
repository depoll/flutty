import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/host_kind.dart';
import 'package:monkeyssh/domain/services/local_terminal_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

bool get _supportsLocalProcess =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

String get _posixOrWindowsShell => Platform.isWindows
    ? (Platform.environment['ComSpec'] ?? 'cmd.exe')
    : '/bin/sh';

String _echoCommand(String message) {
  if (Platform.isWindows) {
    return 'echo $message';
  }
  return 'printf "$message\\n"';
}

String get _exitZeroCommand => Platform.isWindows ? 'exit /B 0' : 'exit 0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalTerminalService', () {
    test('resolves an interactive shell launch on this platform', () async {
      const service = LocalTerminalService();
      expect(service.isSupported, isTrue);

      final launch = await service.resolveShellExecutable();
      expect(launch.executable, isNotEmpty);
      expect(launch.environment['TERM'], 'xterm-256color');
      expect(launch.environment['COLORTERM'], 'truecolor');
      expect(launch.remoteVersion, contains('MonkeySSH_Local'));
    });
  });

  group('LocalTerminalSshSession.exec', () {
    test(
      'drains short command stdout before completing',
      () async {
        final session = await LocalTerminalSshSession.exec(
          command: _echoCommand('monkey-local-exec'),
          environment: const {'TERM': 'xterm-256color'},
          shellExecutable: _posixOrWindowsShell,
        );
        final output = StringBuffer();
        final stdoutDone = session.stdout.forEach((chunk) {
          output.write(utf8.decode(chunk));
        });
        await session.done.timeout(const Duration(seconds: 5));
        await stdoutDone.timeout(const Duration(seconds: 1));
        expect(output.toString(), contains('monkey-local-exec'));
        expect(session.exitCode, 0);
      },
      skip: !_supportsLocalProcess,
    );

    test('resize is a no-op for non-pty exec sessions', () async {
      final session = await LocalTerminalSshSession.exec(
        command: _exitZeroCommand,
        environment: const {},
        shellExecutable: _posixOrWindowsShell,
      );
      session.resizeTerminal(120, 40);
      await session.done.timeout(const Duration(seconds: 5));
      expect(session.exitCode, 0);
    }, skip: !_supportsLocalProcess);
  });

  group('SshService local terminal connect', () {
    late AppDatabase database;
    late SshService sshService;
    late HostRepository hostRepository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      hostRepository = HostRepository(
        database,
        SecretEncryptionService.forTesting(),
      );
      sshService = SshService(hostRepository: hostRepository);
    });

    tearDown(() async {
      await sshService.disconnectAll();
      await database.close();
    });

    test(
      'connectToHost creates a local terminal session without SSH',
      () async {
        final hostId = await database
            .into(database.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'This machine',
                hostKind: Value(HostKind.local.storageValue),
                hostname: localTerminalHostname,
                port: const Value(localTerminalPort),
                username: defaultLocalTerminalUsername(),
              ),
            );

        final result = await sshService.connectToHost(hostId);
        expect(result.success, isTrue, reason: result.error);
        expect(result.connectionId, isNotNull);

        final session = sshService.getSession(result.connectionId!);
        expect(session, isNotNull);
        expect(session!.isLocalTerminal, isTrue);
        expect(session.client, isA<LocalTerminalSshClient>());
        expect(session.remoteSoftwareVersion, contains('MonkeySSH_Local'));

        final client = session.client as LocalTerminalSshClient;
        final bytes = await client.run(_echoCommand('monkey-via-client'));
        expect(utf8.decode(bytes), contains('monkey-via-client'));
      },
      skip: !_supportsLocalProcess && !Platform.isAndroid,
    );
  });
}
