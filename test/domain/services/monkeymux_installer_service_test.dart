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
  _FakeRemoteFileService({this.homeDirectory = '/home/proof'});

  final String homeDirectory;
  bool uploaded = false;
  int uploadCount = 0;

  @override
  Future<String> resolveInitialDirectory(SftpClient sftp) async =>
      homeDirectory;

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
    bool applyPrivateMode = true,
  }) async {
    uploaded = true;
    uploadCount++;
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
      final acceptedConfirmations = <bool>[];
      final confirmationMayFinish = Completer<void>();
      final supersededProbeReachedShaCheck = Completer<void>();
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
        if (acceptedConfirmations.isNotEmpty &&
            !supersededProbeReachedShaCheck.isCompleted &&
            (command.contains('sha256sum') ||
                command.contains('shasum -a 256'))) {
          supersededProbeReachedShaCheck.complete();
        }
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
      MonkeyMuxInstallation? probeOnlyInstallation;
      Object? probeOnlyError;
      final observedProbeOnlyInstall = probeOnlyInstall.then<void>(
        (installation) => probeOnlyInstallation = installation,
        onError: (Object error) => probeOnlyError = error,
      );
      await _waitUntil(() => sftpOpenCount == 1);

      final confirmableInstall = installer.ensureInstalled(
        session,
        priority: SshExecPriority.normal,
        confirmInstall: (request) async {
          acceptedConfirmations.add(true);
          await confirmationMayFinish.future;
          return true;
        },
      );
      await _waitUntil(() => acceptedConfirmations.length == 1);

      firstSftpMayContinue.complete();
      await supersededProbeReachedShaCheck.future.timeout(
        const Duration(seconds: 2),
      );
      expect(probeOnlyInstallation, isNull);
      expect(probeOnlyError, isNull);

      confirmationMayFinish.complete();

      final installation = await confirmableInstall.timeout(
        const Duration(seconds: 2),
      );
      expect(installation.version, '9.9.9');
      expect(installation.installedDuringCall, isTrue);
      expect(acceptedConfirmations, <bool>[true]);
      expect(sftpOpenCount, 2);

      await observedProbeOnlyInstall.timeout(const Duration(seconds: 2));
      expect(probeOnlyError, isNull);
      expect(probeOnlyInstallation?.version, '9.9.9');
    },
  );

  test('reused helper is not marked as installed during the call', () async {
    final assetBytes = Uint8List.fromList(utf8.encode('monkeymux-binary'));
    final expectedSha = sha256.convert(assetBytes).toString();
    final remoteFileService = _FakeRemoteFileService()..uploaded = true;
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
    const connectionId = 246810;
    final client = _MockSshClient();
    final sftp = _MockSftpClient();
    final commands = <String>[];
    when(sftp.close).thenReturn(null);
    when(client.sftp).thenAnswer((_) async => sftp);
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      final command = invocation.positionalArguments.single as String;
      commands.add(command);
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

    final installation = await installer.ensureInstalled(session);

    expect(installation.version, '9.9.9');
    expect(installation.installedDuringCall, isFalse);
    expect(remoteFileService.uploadCount, 0);
    expect(
      commands,
      contains(
        allOf(
          contains('.local/bin/monkeymux'),
          contains('ln -s'),
          contains('.monkeyssh/bin/monkeymux/'),
        ),
      ),
    );
  });

  test('installs the Windows helper via SFTP and native paths', () async {
    final assetBytes = Uint8List.fromList(
      utf8.encode('monkeymux-windows-binary'),
    );
    final expectedSha = sha256.convert(assetBytes).toString();
    final remoteFileService = _FakeRemoteFileService(
      homeDirectory: '/C:/Users/proof',
    );
    final installer = MonkeyMuxInstallerService(
      manifestFuture: Future.value(
        MonkeyMuxManifest(
          version: '9.9.9',
          entries: [
            MonkeyMuxManifestEntry(
              platform: 'windows-amd64',
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
    const connectionId = 135791;
    final client = _MockSshClient();
    final sftp = _MockSftpClient();
    when(sftp.close).thenReturn(null);
    when(
      () => client.remoteVersion,
    ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
    when(client.sftp).thenAnswer((_) async => sftp);
    final renames = <(String, String)>[];
    final commands = <String>[];
    when(() => sftp.remove(any())).thenAnswer((_) async {});
    when(() => sftp.rename(any(), any())).thenAnswer((invocation) async {
      renames.add((
        invocation.positionalArguments[0] as String,
        invocation.positionalArguments[1] as String,
      ));
    });
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      final command = invocation.positionalArguments.single as String;
      commands.add(command);
      return _execSession(
        _windowsOutputForCommand(
          command,
          expectedSha: expectedSha,
          remoteFileService: remoteFileService,
        ),
      );
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

    final installation = await installer.ensureInstalled(
      session,
      confirmInstall: (_) async => true,
    );

    expect(installation.platform, 'windows-amd64');
    expect(installation.isWindows, isTrue);
    expect(
      installation.executablePath,
      r'C:\Users\proof\.monkeyssh\bin\monkeymux\9.9.9\windows-amd64\'
      'monkeymux.exe',
    );
    expect(installation.installedDuringCall, isTrue);
    expect(remoteFileService.uploadCount, 1);
    expect(renames, hasLength(1));
    expect(
      renames.single.$2,
      '/C:/Users/proof/.monkeyssh/bin/monkeymux/9.9.9/windows-amd64/'
      'monkeymux.exe',
    );
    final launcherCommand = commands.singleWhere(
      (command) => command.contains('powershell -NoProfile -NonInteractive'),
    );
    final launcherScript = _decodePowerShellCommand(launcherCommand);
    expect(launcherScript, contains(r'.local\bin\monkeymux.cmd'));
    expect(launcherScript, contains('%~dp0.monkeymux-current'));
    expect(launcherScript, contains(r'%~dp0..\..\.monkeyssh\bin\monkeymux'));
    expect(launcherScript, isNot(contains('%USERPROFILE%')));
    expect(launcherScript, contains(r'9.9.9\windows-amd64\monkeymux.exe'));
    expect(launcherScript, contains('[System.IO.File]::Replace'));
    expect(launcherScript, contains(r'$exists = Test-Path -LiteralPath $path'));
    expect(
      launcherScript,
      contains(r'if ($exists -and $first -ne $managedMarker)'),
    );
    expect(launcherScript, isNot(contains(r'if ($null -eq $first)')));
    expect(
      launcherScript.indexOf(r'-Destination $pointer'),
      lessThan(launcherScript.indexOf(r'-Destination $path')),
    );
    expect(launcherScript, isNot(contains('Copy-Item')));
  });

  test('launcher failure does not block a verified helper', () async {
    final assetBytes = Uint8List.fromList(utf8.encode('monkeymux-binary'));
    final expectedSha = sha256.convert(assetBytes).toString();
    final remoteFileService = _FakeRemoteFileService()..uploaded = true;
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
    const connectionId = 975310;
    final client = _MockSshClient();
    final sftp = _MockSftpClient();
    when(sftp.close).thenReturn(null);
    when(client.sftp).thenAnswer((_) async => sftp);
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      final command = invocation.positionalArguments.single as String;
      if (command.contains('.local/bin/monkeymux')) {
        throw StateError('launcher directory is read-only');
      }
      return _execSession(
        _outputForCommand(
          command,
          expectedSha: expectedSha,
          remoteFileService: remoteFileService,
        ),
      );
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

    final installation = await installer.ensureInstalled(session);

    expect(installation.version, '9.9.9');
    expect(installation.installedDuringCall, isFalse);
  });
}

/// Routes remote commands issued on a Windows host to canned raw output (the
/// Windows deploy path never uses the POSIX completion-marker wrapper).
String _windowsOutputForCommand(
  String command, {
  required String expectedSha,
  required _FakeRemoteFileService remoteFileService,
}) {
  if (command.contains('echo %OS%')) {
    return 'Windows_NT AMD64 \r\n';
  }
  if (command.contains('certutil')) {
    final digest = remoteFileService.uploaded ? expectedSha : '';
    return 'SHA256 hash of file:\r\n$digest\r\n'
        'CertUtil: -hashfile command completed successfully.\r\n';
  }
  if (command.contains('powershell -NoProfile -NonInteractive')) {
    return 'MONKEYMUX_LAUNCHER_MANAGED\r\n';
  }
  return '';
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

String _decodePowerShellCommand(String command) {
  final encoded = command.split(' ').last;
  final bytes = base64Decode(encoded);
  final codeUnits = <int>[
    for (var index = 0; index < bytes.length; index += 2)
      bytes[index] | (bytes[index + 1] << 8),
  ];
  return String.fromCharCodes(codeUnits);
}

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
