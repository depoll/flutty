import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_iterm2_control.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

void main() {
  test('reports formatted iTerm2 cell dimensions', () {
    expect(
      buildIterm2ReportCellSizeResponse(
        const ['ReportCellSize'],
        cellWidth: 8,
        cellHeight: 17.5,
      ),
      '\x1b]1337;ReportCellSize=17.50;8.00\x1b\\',
    );
    expect(
      buildIterm2ReportCellSizeResponse(
        const ['ReportCellSize'],
        cellWidth: null,
        cellHeight: null,
      ),
      isNull,
    );
  });

  test('maps iTerm2 attention request and cancellation', () {
    expect(
      parseIterm2AttentionRequest(const ['RequestAttention=once']),
      const TerminalNotificationRequest(
        body: 'The remote terminal requested your attention.',
        identifier: 'iterm2-attention',
      ),
    );
    expect(
      parseIterm2AttentionRequest(const ['RequestAttention=no']),
      const TerminalNotificationRequest.close(identifier: 'iterm2-attention'),
    );
    expect(parseIterm2AttentionRequest(const ['StealFocus']), isNull);
  });
}
