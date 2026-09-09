import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/command_output_marker_reader.dart';

void main() {
  test('preserves newlines and ignores marker text inside output', () async {
    const output = 'prefix done:9\n\nlast\n';
    for (var split = 0; split <= 8; split++) {
      const marker = 'done:12\n';
      final result = await readCommandOutputUntilMarker(
        Stream.fromIterable([
          '$output\n${marker.substring(0, split)}',
          marker.substring(split),
        ]),
        'done',
      );
      expect(result, (output: output, status: 12));
    }
  });

  test('requires a newline to complete a marker', () async {
    final result = await readCommandOutputUntilMarker(
      Stream.value('output\ndone:0'),
      'done',
    );
    expect(result, (output: 'output\ndone:0', status: null));
  });

  test('retains timeout output only when requested', () async {
    Stream<String> chunks() async* {
      yield 'first\nunfinished';
      throw TimeoutException('No more output');
    }

    expect(
      await readCommandOutputUntilMarker(
        chunks(),
        'done',
        allowPartialOnTimeout: true,
      ),
      (output: 'first\nunfinished', status: null),
    );
    await expectLater(
      readCommandOutputUntilMarker(chunks(), 'done'),
      throwsA(isA<TimeoutException>()),
    );
  });
}
