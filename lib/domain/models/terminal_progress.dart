import 'package:flutter/foundation.dart';

/// Visual state reported by the OSC 9;4 terminal progress protocol.
enum TerminalProgressState {
  /// A normal determinate progress update.
  normal,

  /// A determinate progress update in an error state.
  error,

  /// Progress is active but cannot be quantified.
  indeterminate,

  /// A determinate progress update in a paused/warning state.
  ///
  /// ConEmu calls OSC 9;4 state 4 paused; Windows Terminal calls it warning.
  pausedOrWarning,
}

/// The latest progress state reported by a program running in the terminal.
@immutable
class TerminalProgress {
  /// Creates terminal progress metadata.
  const TerminalProgress({required this.state, this.percentage});

  /// The visual state requested by the remote program.
  final TerminalProgressState state;

  /// The reported whole-number percentage, or `null` when indeterminate.
  final int? percentage;

  /// Progress normalized for Flutter progress indicators.
  double? get fraction => percentage == null ? null : percentage! / 100;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalProgress &&
          state == other.state &&
          percentage == other.percentage;

  @override
  int get hashCode => Object.hash(state, percentage);
}

/// Applies a Windows Terminal/ConEmu OSC 9;4 progress update.
///
/// [args] are the semicolon-separated values after OSC code 9, beginning with
/// the `4` progress subcommand. Malformed or unsupported updates preserve
/// [previousProgress]. State `0` clears progress, state `3` is indeterminate,
/// and states `1`, `2`, and `4` are normal, error, and paused/warning
/// respectively.
TerminalProgress? applyTerminalProgressOsc(
  List<String> args, {
  required TerminalProgress? previousProgress,
}) {
  if (args.length < 2 || args.first.trim() != '4') {
    return previousProgress;
  }

  final state = int.tryParse(args[1].trim());
  switch (state) {
    case 0:
      return null;
    case 1:
      final percentage = _parseTerminalProgressPercentage(args, 2);
      return percentage == null
          ? previousProgress
          : TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: percentage,
            );
    case 2:
      final percentage = _parseOptionalTerminalProgressPercentage(
        args,
        previousProgress,
      );
      if (!_hasValidOptionalPercentage(args, percentage)) {
        return previousProgress;
      }
      return TerminalProgress(
        state: TerminalProgressState.error,
        percentage: percentage,
      );
    case 3:
      return const TerminalProgress(state: TerminalProgressState.indeterminate);
    case 4:
      final percentage = _parseOptionalTerminalProgressPercentage(
        args,
        previousProgress,
      );
      if (!_hasValidOptionalPercentage(args, percentage)) {
        return previousProgress;
      }
      return TerminalProgress(
        state: TerminalProgressState.pausedOrWarning,
        percentage: percentage,
      );
    default:
      return previousProgress;
  }
}

bool _hasValidOptionalPercentage(List<String> args, int? percentage) =>
    args.length <= 2 || args[2].trim().isEmpty || percentage != null;

int? _parseOptionalTerminalProgressPercentage(
  List<String> args,
  TerminalProgress? previousProgress,
) {
  if (args.length <= 2 || args[2].trim().isEmpty) {
    return previousProgress?.percentage;
  }
  return _parseTerminalProgressPercentage(args, 2);
}

int? _parseTerminalProgressPercentage(List<String> args, int index) {
  if (args.length <= index) {
    return null;
  }
  final percentage = int.tryParse(args[index].trim());
  if (percentage == null || percentage < 0 || percentage > 100) {
    return null;
  }
  return percentage;
}
