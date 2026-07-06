// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/app_review_demo_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

void main() {
  late AppDatabase database;
  late SshService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = SshService(
      hostRepository: HostRepository(
        database,
        SecretEncryptionService.forTesting(),
      ),
    );
  });

  tearDown(() async {
    await service.disconnectAll();
    await database.close();
  });

  test('connectToHost creates a usable local App Review demo session', () async {
    final hostId = await database
        .into(database.hosts)
        .insert(
          HostsCompanion.insert(
            label:
                '${AppReviewDemoService.demoHostLabelPrefix} MonkeyMux workspace',
            hostname: '127.0.0.1',
            port: const Value(2201),
            username: 'reviewer',
            tags: const Value('app-review,demo,monkeymux'),
          ),
        );

    final result = await service.connectToHost(hostId);

    expect(result.success, isTrue);
    expect(result.connectionId, isNotNull);

    final session = service.getSession(result.connectionId!);
    expect(session, isNotNull);

    final shell = await session!.getShell();
    final banner = await session.shellStdoutStream.first.timeout(
      const Duration(seconds: 1),
    );
    expect(banner, contains('MonkeySSH App Review Demo'));

    shell.write(Uint8List.fromList(utf8.encode('pwd\r')));
    final pwdOutput = await session.shellStdoutStream.firstWhere(
      (chunk) => chunk.contains('/home/reviewer/work/monkeyssh-demo'),
    );
    expect(pwdOutput, contains('/home/reviewer/work/monkeyssh-demo'));

    final sftp = await session.sftp();
    final files = await sftp.listdir('/home/reviewer/work/monkeyssh-demo');
    expect(files.map((file) => file.filename), contains('README.md'));

    final mux = MonkeyMuxService(
      installer: MonkeyMuxInstallerService(
        manifestFuture: Future.value(
          const MonkeyMuxManifest(version: 'demo', entries: []),
        ),
        remoteFileService: const RemoteFileService(),
      ),
    );
    final windows = await mux.listWindows(session, 'review-workspace');
    expect(windows, hasLength(4));
    expect(
      windows.singleWhere((window) => window.isActive).name,
      'Copilot CLI',
    );

    await mux.createWindow(
      session,
      'review-workspace',
      command: 'codex --yolo',
      name: 'Codex',
    );
    final withCodex = await mux.listWindows(session, 'review-workspace');
    expect(withCodex, hasLength(5));
    expect(withCodex.singleWhere((window) => window.isActive).name, 'Codex');

    await mux.selectWindow(session, 'review-workspace', 1);
    final selected = await mux.listWindows(session, 'review-workspace');
    expect(
      selected.singleWhere((window) => window.isActive).name,
      'Claude Code',
    );
  });
}
