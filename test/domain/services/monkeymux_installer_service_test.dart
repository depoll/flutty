import 'dart:async';
import 'dart:convert';

// ignore_for_file: public_member_api_docs

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockSshSession extends Mock implements SSHSession {}

class _MockSftpClient extends Mock implements SftpClient {}

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this.assets);

  final Map<String, Uint8List> assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = assets[key];
    if (bytes == null) {
      throw StateError('Missing test asset: $key');
    }
    return ByteData.sublistView(bytes);
  }
}

class _FakeRemoteFileService extends RemoteFileService {
  bool uploaded = false;

  @override
  Future<String> resolveInitialDirectory(SftpClient sftp) async =>
      '/home/proof';

  @override
  Future<void> ensureDirectoryExists(
    SftpClient sftp,
    String remotePath, {
    SftpFileMode? mode,
  }) async {}

  @override
  Future<void> uploadBytes({
    required SftpClient sftp,
    required String remotePath,
    required Uint8List bytes,
  }) async {
    uploaded = true;
  }
}

void main() {
  test(
    'confirmable install replaces in-flight probe that cannot prompt',
    () async {
      final assetBytes = Uint8List.fromList(utf8.encode('monkeymux-binary'));
      final expectedSha = sha256.convert(assetBytes).toString();
      final remoteFileService = _FakeRemoteFileService();
      final installer = MonkeyMuxInstallerService(
        manifestFuture: Future.value(
          MonkeyMuxManifest(
            version: '9.9.9',
            entries: [
              MonkeyMuxManifestEntry(
                platform: 'darwin-arm64',
                asset: 'assets/test/monkeymux',
                sha256: expectedSha,
                size: assetBytes.length,
              ),
            ],
          ),
        ),
        remoteFileService: remoteFileService,
        assetBundle: _FakeAssetBundle({'assets/test/monkeymux': assetBytes}),
      );
      const connectionId = 987654;
      final client = _MockSshClient();
      final sftp = _MockSftpClient();
      final firstSftpMayContinue = Completer<void>();
      var sftpOpenCount = 0;
      when(sftp.close).thenReturn(null);
      when(client.sftp).thenAnswer((_) {
        sftpOpenCount += 1;
        if (sftpOpenCount == 1) {
          return firstSftpMayContinue.future.then((_) => sftp);
        }
        return Future<SftpClient>.value(sftp);
      });
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        final output = _outputForCommand(
          command,
          expectedSha: expectedSha,
          remoteFileService: remoteFileService,
        );
        return _execSession(output);
      });
      final session = SshSession(
        connectionId: connectionId,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'proof',
        ),
      );
      addTearDown(() => installer.clearCache(connectionId));

      final probeOnlyInstall = installer.ensureInstalled(session);
      await _waitUntil(() => sftpOpenCount == 1);

      final acceptedConfirmations = <bool>[];
      final confirmableInstall = installer.ensureInstalled(
        session,
        priority: SshExecPriority.normal,
        confirmInstall: (request) async {
          acceptedConfirmations.add(true);
          return true;
        },
      );

      final installation = await confirmableInstall.timeout(
        const Duration(seconds: 2),
      );
      expect(installation.version, '9.9.9');
      expect(acceptedConfirmations, <bool>[true]);
      expect(sftpOpenCount, 2);

      firstSftpMayContinue.complete();
      await probeOnlyInstall;
    },
  );
}

String _outputForCommand(
  String command, {
  required String expectedSha,
  required _FakeRemoteFileService remoteFileService,
}) {
  if (command.contains('uname -s')) {
    return _markedOutput('Darwin\narm64\n');
  }
  if (command.contains('sha256sum') || command.contains('shasum -a 256')) {
    return _markedOutput(remoteFileService.uploaded ? expectedSha : 'missing');
  }
  return _markedOutput('');
}

String _markedOutput(String output) => '$output\n__monkeymux_exec_done__:0\n';

SSHSession _execSession(String stdoutText) {
  final session = _MockSshSession();
  when(() => session.stdout).thenAnswer(
    (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(stdoutText))),
  );
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(session.close).thenReturn(null);
  return session;
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
