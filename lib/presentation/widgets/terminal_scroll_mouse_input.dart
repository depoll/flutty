import 'package:xterm/core.dart';

/// Sends terminal scroll mouse input with corrected SGR wheel button IDs.
bool sendTerminalScrollMouseInput({
  required Terminal terminal,
  required TerminalMouseButton button,
  required CellOffset position,
  bool forceSgr = false,
  int repeatCount = 1,
}) {
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
    final report = '\x1b[<$sgrButtonId;${position.x + 1};${position.y + 1}M';
    terminal.onOutput?.call(report * repeatCount.clamp(1, 32));
    return true;
  }

  return terminal.mouseInput(button, TerminalMouseButtonState.down, position);
}
