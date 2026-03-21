import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

void main() {
  group('remote file helpers', () {
    test('joins remote paths correctly', () {
      expect(joinRemotePath('/', 'example.txt'), '/example.txt');
      expect(
        joinRemotePath('/tmp/monkeyssh', 'example.txt'),
        '/tmp/monkeyssh/example.txt',
      );
    });

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
        buildClipboardUploadFileName('my image.png', timestamp),
        'clipboard-1774116738297-my-image.png',
      );
      expect(
        buildClipboardImageFileName(timestamp),
        'clipboard-1774116738297-image.png',
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
