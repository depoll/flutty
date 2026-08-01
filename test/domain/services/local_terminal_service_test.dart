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
      },
      skip:
          !Platform.isMacOS &&
          !Platform.isLinux &&
          !Platform.isWindows &&
          !Platform.isAndroid,
    );

    test(
      'local exec runs a short command without a PTY plugin',
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
        final session = sshService.getSession(result.connectionId!);
        final client = session!.client as LocalTerminalSshClient;
        final output = utf8.decode(await client.run('echo monkey-local-exec'));
        expect(output, contains('monkey-local-exec'));
      },
      skip: !Platform.isMacOS && !Platform.isLinux && !Platform.isWindows,
    );
  });
}
