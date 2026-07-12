import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ACP harness shell scripts are syntactically valid', () async {
    for (final script in [
      'scripts/lib/local_ssh_test_env.sh',
      'scripts/setup_acp_test_env.sh',
      'scripts/setup_tmux_test_env.sh',
    ]) {
      final result = await Process.run('bash', ['-n', script]);
      expect(result.exitCode, 0, reason: '$script: ${result.stderr}');
    }
  });

  test('ACP setup help does not require SSH prerequisites', () async {
    final result = await Process.run('bash', const [
      'scripts/setup_acp_test_env.sh',
      '--help',
    ]);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('setup_acp_test_env.sh teardown'));
  });
}
