import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/zmodem.dart' as xterm;
import 'package:zmodem/zmodem.dart';

void main() {
  test('an offer retained from an ended session cannot mutate a new session',
      () async {
    final muxInput = StreamController<Uint8List>();
    final muxOutput = StreamController<List<int>>();
    final outputQueue = <List<int>>[];
    final offers = <xterm.ZModemOffer>[];
    final outputSubscription = muxOutput.stream.listen(outputQueue.add);
    xterm.ZModemMux(
      stdin: muxOutput.sink,
      stdout: muxInput.stream,
    ).onFileOffer = offers.add;

    addTearDown(() async {
      await muxInput.close();
      await outputSubscription.cancel();
      await muxOutput.close();
    });

    // zmodem 0.0.6's parser expects the escaped LF byte (0x8a) after a
    // hex header while its own encoder emits LF (0x0a). Real lrzsz traffic uses
    // the escaped form; normalize test-core output at hex-header boundaries.
    Uint8List parserCompatible(Iterable<int> bytes) {
      final result = Uint8List.fromList(bytes.toList());
      for (var index = 1; index < result.length; index++) {
        if (result[index - 1] == 0x0d && result[index] == 0x0a) {
          result[index] = 0x8a;
        }
      }
      return result;
    }

    Future<T> takeNext<T>(List<T> queue, String phase) async {
      for (var attempt = 0; attempt < 1000; attempt++) {
        if (queue.isNotEmpty) {
          return queue.removeAt(0);
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      throw TimeoutException('Timed out waiting for $phase');
    }

    Future<void> beginSession(ZModemCore remote) async {
      remote.initiateSend();
      muxInput.add(parserCompatible(remote.dataToSend()));
      final events = remote
          .receive(
            parserCompatible(
              await takeNext(outputQueue, 'session handshake'),
            ),
          )
          .toList();
      expect(events, [isA<ZReadyToSendEvent>()]);
    }

    final firstRemote = ZModemCore();
    await beginSession(firstRemote);
    firstRemote.offerFile(ZModemFileInfo(pathname: 'first', length: 1));
    muxInput.add(parserCompatible(firstRemote.dataToSend()));
    final staleOffer = await takeNext(offers, 'first file offer');

    staleOffer.skip();
    expect(
      firstRemote
          .receive(
            parserCompatible(
              await takeNext(outputQueue, 'file skip response'),
            ),
          )
          .toList(),
      [isA<ZFileSkippedEvent>()],
    );

    firstRemote.finishSession();
    muxInput.add(parserCompatible(firstRemote.dataToSend()));
    expect(
      firstRemote
          .receive(
            parserCompatible(
              await takeNext(outputQueue, 'session finish response'),
            ),
          )
          .toList(),
      [isA<ZSessionFinishedEvent>()],
    );

    final secondRemote = ZModemCore();
    await beginSession(secondRemote);

    expect(await staleOffer.accept(0).toList(), isEmpty);
    expect(staleOffer.skip, returnsNormally);

    secondRemote.offerFile(ZModemFileInfo(pathname: 'second', length: 1));
    muxInput.add(parserCompatible(secondRemote.dataToSend()));
    final currentOffer = await takeNext(offers, 'second file offer');
    expect(currentOffer.info.pathname, 'second');
  });
}
