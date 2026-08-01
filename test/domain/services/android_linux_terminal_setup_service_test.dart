import 'package:flutter_test/flutter_test.dart';
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
      expect(shellSingleQuote('a\'b'), equals('\'a\'"\'"\'b\''));
    });
  });
}
