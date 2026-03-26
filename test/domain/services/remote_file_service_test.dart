import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

class _MockSftpClient extends Mock implements SftpClient {}

void main() {
  group('remote file helpers', () {
    test('joins remote paths correctly', () {
      expect(joinRemotePath('/', 'example.txt'), '/example.txt');
      expect(
        joinRemotePath('/tmp/monkeyssh', 'example.txt'),
        '/tmp/monkeyssh/example.txt',
      );
      expect(
        joinRemotePath('/tmp/monkeyssh/', '/nested/example.txt'),
        '/tmp/monkeyssh/nested/example.txt',
      );
      expect(joinRemotePath('', 'example.txt'), '/example.txt');
    });

    test(
      'tolerates concurrent mkdir races when ensuring directories',
      () async {
        const remotePath = '/tmp/monkeyssh';
        const service = RemoteFileService();
        final sftp = _MockSftpClient();
        var statCalls = 0;

        when(() => sftp.stat(remotePath)).thenAnswer((_) {
          statCalls++;
          if (statCalls == 1) {
            return Future<SftpFileAttrs>.error(
              SftpStatusError(SftpStatusCode.noSuchFile, 'missing'),
            );
          }
          return Future<SftpFileAttrs>.value(
            SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
          );
        });
        when(() => sftp.stat('/tmp')).thenAnswer(
          (_) async => SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        );
        when(() => sftp.mkdir(remotePath)).thenAnswer(
          (_) => Future<void>.error(
            SftpStatusError(SftpStatusCode.failure, 'already exists'),
          ),
        );

        await service.ensureDirectoryExists(sftp, remotePath);

        verify(() => sftp.mkdir(remotePath)).called(1);
        expect(statCalls, 2);
      },
    );

    test('sanitizes upload file names', () {
      expect(
        sanitizeRemoteUploadFileName('/Users/me/My File.png'),
        'My-File.png',
      );
      expect(sanitizeRemoteUploadFileName('   '), 'file');
    });

    test('builds deterministic clipboard upload names', () {
      final timestamp = DateTime.utc(2026, 3, 21, 18, 12, 18, 297);

      expect(
        buildClipboardUploadFileName('my image.png', timestamp, sequence: 2),
        'clipboard-1774116738297-2-my-image.png',
      );
      expect(
        buildClipboardImageFileName(timestamp, sequence: 3),
        'clipboard-1774116738297-3-image.png',
      );
    });

    test('formats file sizes', () {
      expect(formatRemoteFileSize(999), '999 B');
      expect(formatRemoteFileSize(2048), '2.0 KB');
      expect(formatRemoteFileSize(3 * 1024 * 1024), '3.0 MB');
    });

    test('detects binary content', () {
      expect(
        looksLikeBinaryContent(Uint8List.fromList('hello'.codeUnits)),
        isFalse,
      );
      expect(
        looksLikeBinaryContent(Uint8List.fromList([104, 101, 0, 108, 111])),
        isTrue,
      );
    });

    test('escapes uploaded paths for terminal insertion', () {
      expect(shellEscapePosix("/tmp/it's.txt"), r"'/tmp/it'\''s.txt'");
      expect(
        buildTerminalUploadInsertion(['/tmp/a.png', '/tmp/two words.txt']),
        "'/tmp/a.png' '/tmp/two words.txt'",
      );
    });
  });
}
