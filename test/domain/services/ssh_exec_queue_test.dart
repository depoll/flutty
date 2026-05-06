import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';

void main() {
  tearDown(resetQueuedSshExecsForTesting);

  test('limits normal exec jobs per connection', () async {
    final startedJobs = <int>[];
    final completers = List.generate(5, (_) => Completer<int>());
    final futures = [
      for (var index = 0; index < completers.length; index++)
        runQueuedSshExec(1, () {
          startedJobs.add(index);
          return completers[index].future;
        }),
    ];

    await pumpEventQueue();

    expect(startedJobs, [0, 1, 2, 3]);
    expect(activeQueuedSshExecCountForTesting(1), 4);
    expect(pendingQueuedSshExecCountForTesting(1), 1);

    completers[0].complete(0);
    await pumpEventQueue();

    expect(startedJobs, [0, 1, 2, 3, 4]);
    expect(activeQueuedSshExecCountForTesting(1), 4);
    expect(pendingQueuedSshExecCountForTesting(1), 0);

    for (var index = 1; index < completers.length; index++) {
      completers[index].complete(index);
    }

    expect(await Future.wait(futures), [0, 1, 2, 3, 4]);
  });

  test('keeps low-priority discovery from occupying every exec slot', () async {
    final startedJobs = <String>[];
    final lows = List.generate(4, (_) => Completer<String>());
    final normal = Completer<String>();

    final lowFutures = [
      for (var index = 0; index < lows.length; index++)
        runQueuedSshExec(2, () {
          startedJobs.add('low-$index');
          return lows[index].future;
        }, priority: SshExecPriority.low),
    ];

    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2']);
    expect(activeQueuedSshExecCountForTesting(2), 3);
    expect(pendingQueuedSshExecCountForTesting(2), 1);

    final normalFuture = runQueuedSshExec(2, () {
      startedJobs.add('normal');
      return normal.future;
    });

    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2', 'normal']);
    expect(activeQueuedSshExecCountForTesting(2), 4);
    expect(pendingQueuedSshExecCountForTesting(2), 1);

    normal.complete('normal');
    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2', 'normal']);

    lows[0].complete('low-0');
    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2', 'normal', 'low-3']);

    for (var index = 1; index < lows.length; index++) {
      lows[index].complete('low-$index');
    }

    expect(await Future.wait([...lowFutures, normalFuture]), [
      'low-0',
      'low-1',
      'low-2',
      'low-3',
      'normal',
    ]);
  });

  test('prioritizes normal work ahead of queued low-priority work', () async {
    final startedJobs = <String>[];
    final lows = List.generate(4, (_) => Completer<String>());
    final normal = Completer<String>();

    final lowFutures = [
      for (var index = 0; index < lows.length; index++)
        runQueuedSshExec(3, () {
          startedJobs.add('low-$index');
          return lows[index].future;
        }, priority: SshExecPriority.low),
    ];

    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2']);
    expect(activeQueuedSshExecCountForTesting(3), 3);
    expect(pendingQueuedSshExecCountForTesting(3), 1);

    final normalFuture = runQueuedSshExec(3, () {
      startedJobs.add('normal');
      return normal.future;
    });

    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2', 'normal']);
    expect(activeQueuedSshExecCountForTesting(3), 4);
    expect(pendingQueuedSshExecCountForTesting(3), 1);

    normal.complete('normal');
    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2', 'normal']);

    lows[0].complete('low-0');
    await pumpEventQueue();

    expect(startedJobs, ['low-0', 'low-1', 'low-2', 'normal', 'low-3']);

    for (var index = 1; index < lows.length; index++) {
      lows[index].complete('low-$index');
    }

    expect(await Future.wait([...lowFutures, normalFuture]), [
      'low-0',
      'low-1',
      'low-2',
      'low-3',
      'normal',
    ]);
  });
}
