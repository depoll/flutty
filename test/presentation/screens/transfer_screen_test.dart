import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/transfer_screen.dart';

void main() {
  group('sanitizeTransferFileBaseName', () {
    test('replaces reserved filename characters and whitespace', () {
      expect(
        sanitizeTransferFileBaseName('host: prod/app? key*'),
        'host-prod-app-key',
      );
    });

    test('falls back when the suggestion is empty after sanitizing', () {
      expect(
        sanitizeTransferFileBaseName(r'  <>:"/\|?*  '),
        'monkeyssh-transfer',
      );
    });

    test('strips leading and trailing dots and separators', () {
      expect(sanitizeTransferFileBaseName('.. key export ..'), 'key-export');
    });
  });
}
