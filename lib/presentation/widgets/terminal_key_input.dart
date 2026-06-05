import 'package:kterm/kterm.dart';

const _terminalAlternateEnterInput = '\x1b\r';

/// Sends Enter with the active terminal modifiers applied.
bool sendTerminalEnterInput(
  Terminal terminal, {
  required bool shiftActive,
  required bool altActive,
  required bool ctrlActive,
}) {
  if (shiftActive || altActive) {
    // Prompt UIs such as Copilot CLI use ESC+CR as their terminal-agnostic
    // multiline Enter sequence; kterm's legacy Shift+Return emits ESCOM.
    terminal.textInput(_terminalAlternateEnterInput);
    return true;
  }

  return terminal.keyInput(
    TerminalKey.enter,
    shift: shiftActive,
    alt: altActive,
    ctrl: ctrlActive,
  );
}
