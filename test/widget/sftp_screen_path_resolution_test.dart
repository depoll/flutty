import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

void main() {
  group('resolveRequestedSftpPath', () {
    test('keeps absolute paths absolute while normalizing dot segments', () {
      expect(
        resolveRequestedSftpPath('/var/log/../tmp/app.log'),
        '/var/tmp/app.log',
      );
    });

    test('resolves tilde-prefixed paths against the remote home directory', () {
      expect(
        resolveRequestedSftpPath(
          '~/.config/ghostty/config',
          homeDirectory: '/home/depoll',
        ),
        '/home/depoll/.config/ghostty/config',
      );
    });

    test('returns null for relative paths', () {
      expect(
        resolveRequestedSftpPath(
          '../logs/app.log',
          workingDirectory: '/home/depoll/project/lib',
        ),
        isNull,
      );
      expect(resolveRequestedSftpPath('lib/main.dart'), isNull);
    });
  });
}
