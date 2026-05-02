import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';

void main() {
  tearDown(resetQueuedSshExecsForTesting);

  test('limits normal exec jobs per connection', () async {
    final startedJobs = <int>[];
    final completers = List.generate(3, (_) => Completer<int>());
    final futures = [
      for (var index = 0; index < completers.length; index++)
        runQueuedSshExec(1, () {
          startedJobs.add(index);
          return completers[index].future;
        }),
    ];

    await pumpEventQueue();

    expect(startedJobs, [0, 1]);
    expect(activeQueuedSshExecCountForTesting(1), 2);
    expect(pendingQueuedSshExecCountForTesting(1), 1);

    completers[0].complete(0);
    await pumpEventQueue();

    expect(startedJobs, [0, 1, 2]);
    expect(activeQueuedSshExecCountForTesting(1), 2);
    expect(pendingQueuedSshExecCountForTesting(1), 0);

    completers[1].complete(1);
    completers[2].complete(2);

    expect(await Future.wait(futures), [0, 1, 2]);
  });

  test('keeps low-priority discovery from occupying every exec slot', () async {
    final startedJobs = <String>[];
    final firstLow = Completer<String>();
    final secondLow = Completer<String>();
    final normal = Completer<String>();

    final firstLowFuture = runQueuedSshExec(2, () {
      startedJobs.add('low-1');
      return firstLow.future;
    }, priority: SshExecPriority.low);
    final secondLowFuture = runQueuedSshExec(2, () {
      startedJobs.add('low-2');
      return secondLow.future;
    }, priority: SshExecPriority.low);

    await pumpEventQueue();

    expect(startedJobs, ['low-1']);
    expect(activeQueuedSshExecCountForTesting(2), 1);
    expect(pendingQueuedSshExecCountForTesting(2), 1);

    final normalFuture = runQueuedSshExec(2, () {
      startedJobs.add('normal');
      return normal.future;
    });

    await pumpEventQueue();

    expect(startedJobs, ['low-1', 'normal']);
    expect(activeQueuedSshExecCountForTesting(2), 2);
    expect(pendingQueuedSshExecCountForTesting(2), 1);

    normal.complete('normal');
    await pumpEventQueue();

    expect(startedJobs, ['low-1', 'normal']);

    firstLow.complete('low-1');
    await pumpEventQueue();

    expect(startedJobs, ['low-1', 'normal', 'low-2']);

    secondLow.complete('low-2');

    expect(await Future.wait([firstLowFuture, secondLowFuture, normalFuture]), [
      'low-1',
      'low-2',
      'normal',
    ]);
  });

  test('keeps a spare slot while normal work is active', () async {
    final startedJobs = <String>[];
    final firstNormal = Completer<String>();
    final low = Completer<String>();
    final secondNormal = Completer<String>();

    final firstNormalFuture = runQueuedSshExec(3, () {
      startedJobs.add('normal-1');
      return firstNormal.future;
    });

    await pumpEventQueue();

    expect(startedJobs, ['normal-1']);
    expect(activeQueuedSshExecCountForTesting(3), 1);

    final lowFuture = runQueuedSshExec(3, () {
      startedJobs.add('low');
      return low.future;
    }, priority: SshExecPriority.low);

    await pumpEventQueue();

    expect(startedJobs, ['normal-1']);
    expect(activeQueuedSshExecCountForTesting(3), 1);
    expect(pendingQueuedSshExecCountForTesting(3), 1);

    final secondNormalFuture = runQueuedSshExec(3, () {
      startedJobs.add('normal-2');
      return secondNormal.future;
    });

    await pumpEventQueue();

    expect(startedJobs, ['normal-1', 'normal-2']);
    expect(activeQueuedSshExecCountForTesting(3), 2);
    expect(pendingQueuedSshExecCountForTesting(3), 1);

    secondNormal.complete('normal-2');
    await pumpEventQueue();

    expect(startedJobs, ['normal-1', 'normal-2']);
    expect(activeQueuedSshExecCountForTesting(3), 1);
    expect(pendingQueuedSshExecCountForTesting(3), 1);

    firstNormal.complete('normal-1');
    await pumpEventQueue();

    expect(startedJobs, ['normal-1', 'normal-2', 'low']);

    low.complete('low');

    expect(
      await Future.wait([firstNormalFuture, lowFuture, secondNormalFuture]),
      ['normal-1', 'low', 'normal-2'],
    );
  });
}
