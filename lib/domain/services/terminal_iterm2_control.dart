import 'terminal_notification.dart';

/// Builds an iTerm2 OSC 1337 ReportCellSize response using logical pixels.
String? buildIterm2ReportCellSizeResponse(
  List<String> args, {
  required double? cellWidth,
  required double? cellHeight,
}) {
  if (args.firstOrNull != 'ReportCellSize' ||
      cellWidth == null ||
      cellHeight == null ||
      !cellWidth.isFinite ||
      !cellHeight.isFinite ||
      cellWidth <= 0 ||
      cellHeight <= 0) {
    return null;
  }
  return '\x1b]1337;ReportCellSize=${cellHeight.toStringAsFixed(2)};'
      '${cellWidth.toStringAsFixed(2)}\x1b\\';
}

/// Converts iTerm2 RequestAttention into the existing notification lifecycle.
TerminalNotificationRequest? parseIterm2AttentionRequest(List<String> args) {
  if (args.isEmpty || !args.first.startsWith('RequestAttention=')) {
    return null;
  }
  final value = args.first.substring('RequestAttention='.length).trim();
  switch (value) {
    case 'yes':
    case 'once':
      return const TerminalNotificationRequest(
        body: 'The remote terminal requested your attention.',
        identifier: 'iterm2-attention',
        sound: TerminalNotificationSound.system,
      );
    case 'fireworks':
      return const TerminalNotificationRequest(
        body: 'The remote terminal requested your attention.',
        identifier: 'iterm2-attention',
        sound: TerminalNotificationSound.system,
      );
    case 'no':
      return const TerminalNotificationRequest.close(
        identifier: 'iterm2-attention',
      );
    default:
      return null;
  }
}
