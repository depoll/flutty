import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

class _MockSshClient extends Mock implements SSHClient {}

SshSession _session() => SshSession(
  connectionId: 1,
  hostId: 1,
  client: _MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'demo',
  ),
);

void main() {
  test('routes OSC 9 to a terminal notification request', () async {
    final session = _session();
    final next = session.terminalNotifications.first;
    session.debugHandlePrivateOsc('9', ['Build finished']);
    final request = await next;
    expect(request, const TerminalNotificationRequest(body: 'Build finished'));
  });

  test('routes OSC 777 with a title and body', () async {
    final session = _session();
    final next = session.terminalNotifications.first;
    session.debugHandlePrivateOsc('777', ['notify', 'Deploy', 'Succeeded']);
    final request = await next;
    expect(request.title, 'Deploy');
    expect(request.body, 'Succeeded');
  });

  test('routes OSC 9;4 to terminal progress metadata', () async {
    final session = _session();
    var metadataChanges = 0;
    session
      ..addMetadataListener(() => metadataChanges += 1)
      ..debugHandlePrivateOsc('9', ['4', '1', '50']);

    expect(
      session.terminalProgress,
      const TerminalProgress(
        state: TerminalProgressState.normal,
        percentage: 50,
      ),
    );
    expect(metadataChanges, 1);

    session.debugHandlePrivateOsc('9', ['4', '0']);

    expect(session.terminalProgress, isNull);
    expect(metadataChanges, 2);
  });

  test('synchronizes and clears progress without duplicate notifications', () {
    final session = _session();
    var metadataChanges = 0;
    const progress = TerminalProgress(
      state: TerminalProgressState.normal,
      percentage: 50,
    );
    session.addMetadataListener(() => metadataChanges += 1);

    expect(session.synchronizeTerminalProgress(progress), isTrue);
    expect(session.terminalProgress, progress);
    expect(metadataChanges, 1);

    expect(session.synchronizeTerminalProgress(progress), isFalse);
    expect(metadataChanges, 1);

    expect(session.clearTerminalProgress(), isTrue);
    expect(session.terminalProgress, isNull);
    expect(metadataChanges, 2);

    expect(session.clearTerminalProgress(), isFalse);
    expect(metadataChanges, 2);
  });

  test('OSC 9;4 progress does not emit a notification', () async {
    final session = _session();
    var emitted = false;
    final sub = session.terminalNotifications.listen((_) => emitted = true);

    session.debugHandlePrivateOsc('9', ['4', '3']);
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isFalse);
    expect(
      session.terminalProgress,
      const TerminalProgress(state: TerminalProgressState.indeterminate),
    );
    await sub.cancel();
  });

  test('assembles a chunked OSC 99 notification', () async {
    final session = _session();
    final next = session.terminalNotifications.first;
    session
      ..debugHandlePrivateOsc('99', ['i=1:d=0', 'Tests'])
      ..debugHandlePrivateOsc('99', ['i=1:p=body', 'All green']);
    final request = await next;
    expect(request.title, 'Tests');
    expect(request.body, 'All green');
  });

  test('does not emit for non-notification OSC codes', () async {
    final session = _session();
    var emitted = false;
    final sub = session.terminalNotifications.listen((_) => emitted = true);
    // OSC 8 (hyperlink) and OSC 7 (working dir) must not notify.
    session
      ..debugHandlePrivateOsc('8', ['', 'https://example.com'])
      ..debugHandlePrivateOsc('7', ['file://host/home/demo']);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isFalse);
    await sub.cancel();
  });
}
