import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/services/ssh_error_policy.dart';

void main() {
  test('recognizes late dartssh2 channel writes during teardown', () {
    final stackTrace = StackTrace.fromString(
      '#0 SSHTransport.sendPacket\n'
      '#1 SSHChannelController._uploadLoop.<anonymous closure>\n',
    );

    expect(
      isExpectedSshChannelTeardownError(
        SSHStateError('Transport is closed'),
        stackTrace,
      ),
      isTrue,
    );
  });

  test('does not hide SSH state errors from other operations', () {
    expect(
      isExpectedSshChannelTeardownError(
        SSHStateError('Transport is closed'),
        StackTrace.fromString('#0 SshSession.execute\n'),
      ),
      isFalse,
    );
  });

  test('recognizes SSH operation errors that do not extend Exception', () {
    expect(
      isExpectedSshOperationError(SSHChannelOpenError(1, 'denied')),
      isTrue,
    );
    expect(isExpectedSshOperationError(SSHSocketError('closed')), isTrue);
  });

  test('recognizes SFTP status errors that do not extend Exception', () {
    expect(
      isExpectedSshOperationError(
        SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
      ),
      isTrue,
    );
    expect(isExpectedSshOperationError(StateError('bug')), isFalse);
  });

  test('recognizes channel EOF writes after the transport closes', () {
    final stackTrace = StackTrace.fromString(
      '#0 SSHTransport.sendPacket\n'
      '#1 SSHChannelController._sendEOFIfNeeded\n'
      '#2 SSHChannelController.close\n',
    );

    expect(
      isExpectedSshChannelTeardownError(
        SSHStateError('Transport is closed'),
        stackTrace,
      ),
      isTrue,
    );
  });
}
