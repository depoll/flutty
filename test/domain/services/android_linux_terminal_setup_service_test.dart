import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/android_linux_terminal_setup_service.dart';

void main() {
  group('buildAndroidLinuxTerminalSetupScript', () {
    test('embeds the public key and readiness marker', () {
      const publicKey =
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKey monkeyssh';
      final script = buildAndroidLinuxTerminalSetupScript(
        publicKey: publicKey,
        username: androidLinuxTerminalSetupUsername,
        port: androidLinuxTerminalSetupPort,
      );

      expect(script, contains('openssh-server'));
      expect(script, contains('Port $androidLinuxTerminalSetupPort'));
      expect(script, contains(publicKey));
      expect(
        script,
        contains(
          'MONKEYSSH_AVF_READY user=$androidLinuxTerminalSetupUsername port=$androidLinuxTerminalSetupPort',
        ),
      );
      expect(script, contains(shellSingleQuote(publicKey)));
    });
  });

  group('shellSingleQuote', () {
    test('escapes embedded single quotes', () {
      expect(shellSingleQuote("a'b"), equals("'a'\"'\"'b'"));
    });
  });

  group('isAndroidLinuxTerminalHost', () {
    Host host({required String label, String? notes}) => Host(
      id: 1,
      label: label,
      hostKind: 'ssh',
      hostname: '127.0.0.1',
      port: 8022,
      username: 'droid',
      isFavorite: false,
      autoConnectRequiresConfirmation: false,
      autoForwardPorts: false,
      sortOrder: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      notes: notes,
    );

    test('matches setup label and notes marker', () {
      expect(
        isAndroidLinuxTerminalHost(host(label: androidLinuxTerminalHostLabel)),
        isTrue,
      );
      expect(
        isAndroidLinuxTerminalHost(
          host(
            label: 'Other',
            notes: '$androidLinuxTerminalHostNotesMarker details',
          ),
        ),
        isTrue,
      );
      expect(isAndroidLinuxTerminalHost(host(label: 'Prod box')), isFalse);
    });
  });
}
