import 'package:xterm/xterm.dart';

const _terminalAlternateEnterInput = '\x1b\r';

/// Sends Enter with the active terminal modifiers applied.
bool sendTerminalEnterInput(
  Terminal terminal, {
  required bool shiftActive,
  required bool altActive,
  required bool ctrlActive,
  bool metaActive = false,
  TerminalKeyEventType type = TerminalKeyEventType.press,
}) {
  if (terminal.kittyKeyboardMode) {
    return terminal.keyInput(
      TerminalKey.enter,
      shift: shiftActive,
      alt: altActive,
      ctrl: ctrlActive,
      meta: metaActive,
      type: type,
    );
  }

  if (type != TerminalKeyEventType.press) {
    return false;
  }

  if (shiftActive || altActive) {
    // Prompt UIs such as Copilot CLI use ESC+CR as their terminal-agnostic
    // multiline Enter sequence; xterm.dart's legacy Shift+Return emits ESCOM.
    terminal.textInput(_terminalAlternateEnterInput);
    return true;
  }

  return terminal.keyInput(
    TerminalKey.enter,
    shift: shiftActive,
    alt: altActive,
    ctrl: ctrlActive,
    meta: metaActive,
  );
}
