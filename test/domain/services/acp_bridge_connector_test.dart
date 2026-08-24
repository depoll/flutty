// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSshSession extends Mock implements SshSession {}

MonkeyMuxAcpBridgeService _unusedBridgeService() => MonkeyMuxAcpBridgeService(
  installer: MonkeyMuxInstallerService(
    manifestFuture: Future.value(
      const MonkeyMuxManifest(version: 'test', entries: []),
    ),
    remoteFileService: const RemoteFileService(),
  ),
);

void main() {
  test(
    'resolves a tilde working directory to a canonical absolute path',
    () async {
      final sftp = _MockSftpClient();
      final session = _MockSshSession();
      when(session.sftp).thenAnswer((_) async => sftp);
      when(() => session.remoteIsWindows).thenReturn(false);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/Users/demo');
      when(
        () => sftp.absolute('/Users/demo/Code/project'),
      ).thenAnswer((_) async => '/Users/demo/Code/project');
      final connector = MonkeyMuxAcpBridgeConnector(
        bridgeService: _unusedBridgeService(),
        sessionResolver: (_) async => session,
      );

      final resolved = await connector.resolveWorkingDirectory(
        1,
        '~/Code/project',
      );

      expect(resolved, '/Users/demo/Code/project');
    },
  );

  test(
    'returns native Windows syntax before sending cwd to an ACP agent',
    () async {
      final sftp = _MockSftpClient();
      final session = _MockSshSession();
      when(session.sftp).thenAnswer((_) async => sftp);
      when(() => session.remoteIsWindows).thenReturn(false);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/C:/Users/demo');
      when(
        () => sftp.absolute('/C:/Users/demo/Code/project'),
      ).thenAnswer((_) async => '/C:/Users/demo/Code/project');
      final connector = MonkeyMuxAcpBridgeConnector(
        bridgeService: _unusedBridgeService(),
        sessionResolver: (_) async => session,
      );

      final resolved = await connector.resolveWorkingDirectory(
        1,
        '~/Code/project',
      );

      expect(resolved, r'C:\Users\demo\Code\project');
    },
  );

  test(
    'trusts a stored absolute cwd on reconnect without opening SFTP',
    () async {
      var resolvedSession = false;
      final connector = MonkeyMuxAcpBridgeConnector(
        bridgeService: _unusedBridgeService(),
        sessionResolver: (_) async {
          resolvedSession = true;
          throw StateError('SFTP should not be needed');
        },
      );

      final resolved = await connector.resolveWorkingDirectory(
        1,
        '/Users/demo/Code/project',
        trustAbsolute: true,
      );

      expect(resolved, '/Users/demo/Code/project');
      expect(resolvedSession, isFalse);
    },
  );
}
