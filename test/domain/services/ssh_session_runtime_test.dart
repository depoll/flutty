import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _Client extends Mock implements SSHClient {}

class _Shell extends Mock implements SSHSession {}

void main() {
  test(
    'shell arriving after close is discarded without replacing a new shell',
    () async {
      final client = _Client();
      final lateShell = _Shell();
      final replacement = _Shell();
      final opening = Completer<SSHSession>();
      final session = SshSession(
        connectionId: 123,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => opening.future);
      for (final shell in [lateShell, replacement]) {
        when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
        when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => shell.done).thenAnswer((_) => Completer<void>().future);
      }
      addTearDown(() => session.closeShell(waitForStreams: false));

      final pending = session.getShell(requestPty: false, command: 'first');
      final rejected = expectLater(pending, throwsA(isA<StateError>()));
      await session.closeShell(waitForStreams: false);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => replacement);
      expect(
        await session.getShell(requestPty: false, command: 'second'),
        same(replacement),
      );
      opening.complete(lateShell);
      await rejected;
      expect(await session.getShell(), same(replacement));
      verify(lateShell.close).called(1);
      verifyNever(() => lateShell.stdout);
    },
  );
}
