import 'package:xterm/core.dart';

/// Sends terminal scroll mouse input with corrected SGR wheel button IDs.
///
/// Honors DEC private mode 1007 ("alternate-screen alternate-scroll"): when an
/// app in the alternate buffer has enabled 1007 but not mouse tracking
/// (1000/1002/1003), the terminal emulator must translate wheel events into
/// cursor up/down keys rather than mouse reports. Codex CLI relies on this
/// protocol; sending SGR wheel reports leaks raw bytes into its composer.
bool sendTerminalScrollMouseInput({
  required Terminal terminal,
  required TerminalMouseButton button,
  required CellOffset position,
  bool forceSgr = false,
}) {
  final isWheel =
      button == TerminalMouseButton.wheelUp ||
      button == TerminalMouseButton.wheelDown ||
      button == TerminalMouseButton.wheelLeft ||
      button == TerminalMouseButton.wheelRight;

  if (isWheel &&
      !terminal.mouseMode.reportScroll &&
      terminal.isUsingAltBuffer &&
      terminal.altBufferMouseScrollMode) {
    final key = switch (button) {
      TerminalMouseButton.wheelUp => TerminalKey.arrowUp,
      TerminalMouseButton.wheelDown => TerminalKey.arrowDown,
      TerminalMouseButton.wheelLeft => TerminalKey.arrowLeft,
      TerminalMouseButton.wheelRight => TerminalKey.arrowRight,
      _ => null,
    };
    if (key != null) {
      terminal.keyInput(key);
      return true;
    }
  }

  if (forceSgr ||
      (terminal.mouseMode.reportScroll &&
          terminal.mouseReportMode == MouseReportMode.sgr)) {
    final sgrButtonId = switch (button) {
      TerminalMouseButton.wheelUp => 64,
      TerminalMouseButton.wheelDown => 65,
      TerminalMouseButton.wheelLeft => 66,
      TerminalMouseButton.wheelRight => 67,
      _ => button.id,
    };
    terminal.onOutput?.call(
      '\x1b[<$sgrButtonId;${position.x + 1};${position.y + 1}M',
    );
    return true;
  }

  return terminal.mouseInput(button, TerminalMouseButtonState.down, position);
}
