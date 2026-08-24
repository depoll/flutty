import 'package:xterm/xterm.dart';

/// Sends Enter via [Terminal.keyInput] with the active modifiers.
///
/// Outside Kitty mode, non-press events are ignored (legacy keytabs only emit
/// on press). Kitty mode forwards press/repeat/release so the remote gets the
/// full progressive-enhancement sequence, except Alt+Enter. That chord keeps
/// the broadly-supported meta-sends-escape form (`ESC CR`) because Pi and
/// other prompt TUIs bind it to queue/enqueue while treating CSI-u Alt+Enter
/// as a literal multiline insertion.
///
/// Two legacy keytab gaps are corrected only for this Enter keystroke:
/// - DEC LNM makes unmodified Return emit CRLF; collapse that to CR so prompt
///   TUIs do not also see LF as newline. Paste and other producers are untouched.
/// - There is no Enter+Alt keytab record, so Alt is dropped; apply
///   meta-sends-escape (ESC CR) when Alt is the only modifier.
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

  final altOnly = altActive && !shiftActive && !ctrlActive && !metaActive;
  if (altOnly) {
    if (type == TerminalKeyEventType.press) {
      terminal.onOutput?.call('\x1b\r');
    }
    // Do not send a CSI-u repeat/release after the legacy press sequence.
    return true;
  }

  final previousOutput = terminal.onOutput;
  final chunks = <String>[];
  terminal.onOutput = chunks.add;
  final bool handled;
  try {
    handled = terminal.keyInput(
      TerminalKey.enter,
      shift: shiftActive,
      alt: altActive,
      ctrl: ctrlActive,
      meta: metaActive,
      type: type,
    );
  } finally {
    terminal.onOutput = previousOutput;
  }

  if (!handled) {
    return false;
  }

  var payload = chunks.join();
  final hasModifiers = shiftActive || altActive || ctrlActive || metaActive;
  if (!hasModifiers && payload == '\r\n') {
    // LNM Return keytab emits CRLF as one keystroke.
    payload = '\r';
  }

  previousOutput?.call(payload);
  return true;
}
