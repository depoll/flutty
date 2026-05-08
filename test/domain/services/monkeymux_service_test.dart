// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';

void main() {
  group('RemoteMuxBackendPresentation', () {
    test('parses stable storage values', () {
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('auto'),
        RemoteMuxBackend.auto,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('monkey_mux'),
        RemoteMuxBackend.monkeyMux,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('tmux'),
        RemoteMuxBackend.tmux,
      );
      expect(RemoteMuxBackendPresentation.fromStorageValue(''), isNull);
    });
  });

  group('buildMonkeyMuxAttachCommand', () {
    test('puts flags before the session and shell-quotes values', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkey mux',
        sessionName: "work'space",
        workingDirectory: "~/src/it's app",
        windowName: 'Codex agent',
        launchCommand: "codex --model 'gpt-5.4'",
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkey mux' attach --cwd "
        "'~/src/it'\"'\"'s app' --name 'Codex agent' --command "
        "'codex --model '\"'\"'gpt-5.4'\"'\"'' 'work'\"'\"'space'",
      );
    });
  });
}
