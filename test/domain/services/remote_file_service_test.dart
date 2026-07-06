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
      'joins Windows drive-letter SFTP paths without forcing POSIX root',
      () {
        expect(
          joinRemotePath('C:/Users/demo', 'Documents/notes.txt'),
          'C:/Users/demo/Documents/notes.txt',
        );
        expect(
          joinRemotePath('C:/Users/demo', r'Documents\notes.txt'),
          'C:/Users/demo/Documents/notes.txt',
        );
        expect(
          joinRemotePath('/C:/Users/demo', 'Documents/notes.txt'),
          '/C:/Users/demo/Documents/notes.txt',
        );
      },
    );

    test('normalizes Windows drive-letter SFTP paths', () {
      expect(
        normalizeSftpAbsolutePath(r'C:\Users\demo\..\Public'),
        'C:/Users/Public',
      );
      expect(
        normalizeSftpAbsolutePath('/C:/Users/demo/../Public'),
        '/C:/Users/Public',
      );
      expect(sftpPathRoot('C:/Users/demo'), 'C:/');
      expect(sftpPathRoot('/C:/Users/demo'), '/C:/');
      expect(isSftpPathRoot('C:/'), isTrue);
      expect(isSftpPathRoot('/C:/'), isTrue);
    });

    test('resolves Windows drive-letter SFTP parents', () {
      expect(parentSftpPath('C:/Users/demo'), 'C:/Users');
      expect(parentSftpPath('C:/Users'), 'C:/');
      expect(parentSftpPath('C:/'), 'C:/');
      expect(parentSftpPath('/C:/Users/demo'), '/C:/Users');
      expect(parentSftpPath('/C:/Users'), '/C:/');
      expect(parentSftpPath('/C:/'), '/C:/');
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

    test('strips shell metacharacters from upload file names', () {
      // Only letters, digits, '.', '_' and '-' survive, so the uploaded path
      // can be pasted unquoted without risking shell interpretation. The
      // extension is preserved so image previews still resolve.
      expect(sanitizeRemoteUploadFileName(r'a$(rm -rf ~).png'), 'a-rm-rf-.png');
      expect(sanitizeRemoteUploadFileName('photo;`id`.jpg'), 'photo-id-.jpg');
      expect(sanitizeRemoteUploadFileName('***.png'), '.png');
    });

    test('rejects dot-only (path traversal) upload file names', () {
      expect(sanitizeRemoteUploadFileName('.'), 'file');
      expect(sanitizeRemoteUploadFileName('..'), 'file');
      expect(sanitizeRemoteUploadFileName('/a/b/..'), 'file');
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
    });

    test(
      'builds a separate bracketed paste per file so agents show one chip each',
      () {
        const start = '\x1b[200~';
        const end = '\x1b[201~';
        expect(
          buildTerminalAttachmentPasteSegments([
            '/home/u/.cache/monkeyssh/uploads/a.png',
            '/home/u/b.png',
          ], bracketedPasteMode: true),
          [
            '$start/home/u/.cache/monkeyssh/uploads/a.png$end ',
            '$start/home/u/b.png$end ',
          ],
        );
      },
    );

    test('inserts one shell-escaped segment when bracketed paste is off', () {
      expect(
        buildTerminalAttachmentPasteSegments([
          '/tmp/a.png',
          '/tmp/b.png',
        ], bracketedPasteMode: false),
        ["'/tmp/a.png' '/tmp/b.png' "],
      );
    });

    test('falls back to shell-escaping when a path is not unquoted-safe', () {
      // A remote home directory with a space (or shell metacharacters) must not
      // be pasted raw: it would split/inject in a shell. Such a path would not
      // produce a preview chip anyway, so a safe shell-escaped segment is used.
      expect(
        buildTerminalAttachmentPasteSegments([
          '/home/john smith/.cache/monkeyssh/uploads/a.png',
        ], bracketedPasteMode: true),
        ["'/home/john smith/.cache/monkeyssh/uploads/a.png' "],
      );
      expect(
        buildTerminalAttachmentPasteSegments([
          r'/home/u/$(reboot)/a.png',
        ], bracketedPasteMode: true),
        [r"'/home/u/$(reboot)/a.png' "],
      );
    });

    test('returns no segments when there are no paths', () {
      expect(
        buildTerminalAttachmentPasteSegments(
          const [],
          bracketedPasteMode: true,
        ),
        isEmpty,
      );
      expect(
        buildTerminalAttachmentPasteSegments(const [
          '',
        ], bracketedPasteMode: true),
        isEmpty,
      );
    });
  });
}
