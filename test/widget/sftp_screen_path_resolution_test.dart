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

    test('resolves relative paths against the terminal working directory', () {
      expect(
        resolveRequestedSftpPath(
          '../logs/app.log',
          workingDirectory: '/home/depoll/project/lib',
        ),
        '/home/depoll/project/logs/app.log',
      );
    });

    test(
      'returns null for relative paths without working-directory context',
      () {
        expect(resolveRequestedSftpPath('lib/main.dart'), isNull);
      },
    );
  });
}
