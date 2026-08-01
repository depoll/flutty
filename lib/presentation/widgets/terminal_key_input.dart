import 'package:xterm/xterm.dart';

/// Sends Enter the same way a physical keyboard does: via [Terminal.keyInput]
/// with the active modifiers.
///
/// Outside Kitty mode, non-press events are ignored (legacy keytabs only emit
/// on press). Kitty mode forwards press/repeat/release so the remote gets the
/// full progressive-enhancement sequence.
bool sendTerminalEnterInput(
  Terminal terminal, {
  required bool shiftActive,
  required bool altActive,
  required bool ctrlActive,
  bool metaActive = false,
  TerminalKeyEventType type = TerminalKeyEventType.press,
}) {
  if (type != TerminalKeyEventType.press && !terminal.kittyKeyboardMode) {
    return false;
  }

  return terminal.keyInput(
    TerminalKey.enter,
    shift: shiftActive,
    alt: altActive,
    ctrl: ctrlActive,
    meta: metaActive,
    type: type,
  );
}
