import 'package:xterm/xterm.dart';

/// Sends Enter with the active terminal modifiers applied.
void sendTerminalEnterInput(
  Terminal terminal, {
  required bool shiftActive,
  required bool altActive,
  required bool ctrlActive,
}) {
  terminal.keyInput(
    TerminalKey.enter,
    shift: shiftActive,
    alt: altActive,
    ctrl: ctrlActive,
  );
}
