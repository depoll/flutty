import 'package:xterm/core.dart';

/// Sends terminal scroll mouse input with corrected SGR wheel button IDs.
bool sendTerminalScrollMouseInput({
  required Terminal terminal,
  required TerminalMouseButton button,
  required CellOffset position,
}) {
  if (terminal.mouseMode.reportScroll &&
      terminal.mouseReportMode == MouseReportMode.sgr) {
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
